import Foundation

/// The agent's hands in the user's own Chrome, over the DevTools protocol
/// (ITER-076 3.1). Ported from browser-harness and jev-ultrafast's
/// `browser.py` (both MIT © Browser Use):
/// - the agent's tab is a background target it creates itself, with focus
///   emulation, so it keeps rendering without ever being brought forward, at
///   jev-ultrafast's fixed viewport;
/// - its scripts run in an isolated world, where the page's own JavaScript
///   cannot rewrite what they call, so a hostile page cannot forge the report
///   (K1 of the ITER-074 whole review) — a world addressed by its system-wide
///   id, never by a number a later page can hold (`world(for:)`).
///
/// `BrowserTab.windowID` holds the tab's target id and `tabID` the session the
/// bridge is attached to it with.
@MainActor
final class ChromeBridge: TrustedInputBridge {
    /// Runs after a tab is attached and before it loads anything. Tests use it
    /// to serve their pages from inside Chrome; the app passes nothing.
    typealias TabHook = @Sendable (_ sessionID: String) async throws -> Void
    /// Runs once a page's dialog is decided and before its answer goes out.
    /// Tests use it to hold the answer there; the app passes nothing.
    typealias AnswerHook = @MainActor @Sendable () async -> Void
    /// What the Mac's own resolver answers for a host (ITER-076 stage 9e):
    /// its addresses, each as its numeric string — none when it says no such
    /// name exists; nil when it gives no answer. The app asks the system
    /// (`addresses(of:)`); tests decide what a name resolves to.
    typealias Resolver = @Sendable (_ host: String) async -> [String]?

    /// jev-ultrafast `browser.py` line 25.
    static let viewport = (width: 1120, height: 780)
    static let worldName = "metawhisp-agent"
    /// What the agent's tab shows before its page's title in the tab strip,
    /// so the user tells it from their own at a glance (ITER-076 I-09). A
    /// sign, no words; the agent never reads it back (`ObservedPage`).
    nonisolated static let tabMark = "\u{1F916} "

    private let connection: CDPConnection
    private let prepareTab: TabHook?
    private let beforeAnswer: AnswerHook?
    /// Brings the browser's app in front of the user's (ITER-076 stage 3,
    /// Show tab); none in tests.
    private let bringForward: (@MainActor () -> Void)?
    /// The isolated world of each tab's current document, by session — and of
    /// each frame's, by the frame's id: its system-wide id, and the session it
    /// is reached by.
    private var worlds: [String: (id: String, session: String)] = [:]
    /// Each open tab's sweep for windows its page opens (by target id).
    private var sweeps: [String: Task<Void, Never>] = [:]
    /// What the bridge keeps of each open tab, by target id (ITER-076 I-09).
    private var watches: [String: TabWatch] = [:]
    /// The agent's tabs not known closed, on disk (ITER-076 stage 9d, № 21,
    /// № 23); none in tests that do not ask for it.
    private let tabs: AgentTabLedger?
    /// Asked for the addresses of each document's host before it goes on
    /// (ITER-076 stage 9e).
    private let resolve: Resolver

    init(connection: CDPConnection, prepareTab: TabHook? = nil, beforeAnswer: AnswerHook? = nil,
         bringForward: (@MainActor () -> Void)? = nil, tabs: AgentTabLedger? = nil,
         resolve: @escaping Resolver = { await ChromeBridge.addresses(of: $0) }) {
        self.connection = connection
        self.prepareTab = prepareTab
        self.beforeAnswer = beforeAnswer
        self.bringForward = bringForward
        self.tabs = tabs
        self.resolve = resolve
    }

    func openTab(_ url: URL) async throws -> BrowserTab {
        guard DiaScript.isOpenable(url) else { throw BrowserBridgeError.notOpenable(url) }
        try Task.checkCancellation()
        // Made whatever happens to the caller, so the tab is always known and
        // can be closed: a Stop that lands here leaves no tab behind.
        let created = try await Task {
            try await self.send("Target.createTarget", ["url": "about:blank", "background": true])
        }.value
        guard let targetID = created["targetId"]?.string else { throw BrowserBridgeError.scriptFailed(code: -1) }
        // On disk before anything else: a crash from here on leaves it the
        // agent's to close (ITER-076 stage 9d, № 21).
        tabs?.opened(targetID)
        do {
            let attached = try await send("Target.attachToTarget", ["targetId": .string(targetID), "flatten": true])
            guard let sessionID = attached["sessionId"]?.string else { throw BrowserBridgeError.tabNotFound }
            // Watched from before anything loads: its dialogs, its downloads,
            // its frames and its requests (ITER-076 I-09).
            let watch = TabWatch(page: sessionID, target: targetID)
            watches[targetID] = watch
            watch.listener = listen(to: await connection.events(), tab: targetID)
            _ = try await send("Emulation.setDeviceMetricsOverride",
                               ["width": .number(Double(Self.viewport.width)),
                                "height": .number(Double(Self.viewport.height)),
                                "deviceScaleFactor": 1, "mobile": false], session: sessionID)
            _ = try await send("Emulation.setFocusEmulationEnabled", ["enabled": true], session: sessionID)
            // A person's click lets a page open the system's file picker — a
            // dialog in the user's Chrome. The tab takes the request instead,
            // and no picker is shown (review of 3.1, round 2).
            _ = try await send("Page.enable", [:], session: sessionID)
            _ = try await send("Page.setInterceptFileChooserDialog", ["enabled": true], session: sessionID)
            _ = try await send("Page.addScriptToEvaluateOnNewDocument",
                               ["source": .string(Self.markScript), "worldName": .string(Self.markWorldName)],
                               session: sessionID)
            _ = try await send("Target.setAutoAttach", Self.frameAttach, session: sessionID)
            try await prepareTab?(sessionID)
            try await guardRequests(of: targetID, in: watch)
            _ = try await send("Page.navigate", ["url": .string(url.absoluteString)], session: sessionID)
            let tab = BrowserTab(windowID: targetID, tabID: sessionID)
            sweep(tab)
            return tab
        } catch {
            // A tab that could not be set up — or whose caller stopped — is
            // closed, so none is left behind.
            try? await closeTab(BrowserTab(windowID: targetID, tabID: ""))
            throw error
        }
    }

    func events(in tab: BrowserTab) -> [BrowserEvent] {
        watches[tab.windowID]?.log.take() ?? []
    }

    /// The step's Yes, with the act it was given for, as a permit of its own:
    /// a new one — or none — takes back the one before, and an answer decided
    /// under that one that has not reached the socket yet goes out as Cancel
    /// (Codex review 1 of I-09, P1-4; Codex review 2, P1-5).
    func approve(_ act: ApprovedAct?, in tab: BrowserTab) {
        guard let watch = watches[tab.windowID] else { return }
        watch.permit?.takeBack()
        watch.permit = act.map { Permit($0, document: watch.documents[$0.frame ?? watch.target]) }
    }

    /// While held, every request of the tab is paused as it is asked for —
    /// its page's and each frame's, a document or not (`heldRequests`) —
    /// and `pass` refuses what sends (ITER-076 stage 7, review rounds 1 and
    /// 2, C2, R2-1); let go, the guard pauses its documents alone again. The
    /// patterns are in place on every session of the tab's guard when this
    /// returns true. A hold that cannot be put in place on every one of them
    /// is none: what was put in place is taken down, and the tab cannot hold
    /// (review round 3, R3-2). A tab not watched holds none.
    func holdSends(_ held: Bool, in tab: BrowserTab) async -> Bool {
        guard let watch = watches[tab.windowID] else { return false }
        guard held else {
            endHold(watch)
            return true
        }
        watch.holdsSends = true
        watch.heldDocument = watch.documents[watch.target]
        watch.heldPages = Set([watch.pageAddress].compactMap { $0.map(Self.navigation) })
        var placed = !watch.guards.isEmpty
        for session in watch.guards {
            do {
                _ = try await send("Fetch.enable", Self.heldRequests, session: session)
            } catch {
                placed = false
            }
        }
        guard placed else {
            endHold(watch)
            return false
        }
        return true
    }

    /// The tab's sends go out as ever: nothing held, no navigation of the
    /// agent's waited for, the guard back to its documents alone on every
    /// session of the tab — each one it can reach.
    private func endHold(_ watch: TabWatch) {
        watch.holdsSends = false
        watch.navigationsLetGo = []
        watch.requestsLetGo = []
        watch.arrived = []
        watch.heldPages = []
        watch.heldDocument = nil
        for session in watch.guards {
            Task { _ = try? await self.send("Fetch.enable", Self.documentRequests, session: session) }
        }
    }

    /// The agent's own navigation while the tab's sends are held (review round
    /// 2, R2-2): the page's GET to `address` goes, and its redirects.
    func letNavigate(to address: String, in tab: BrowserTab) {
        guard let watch = watches[tab.windowID], watch.holdsSends else { return }
        watch.navigationsLetGo.insert(Self.navigation(address))
    }

    /// An address as a navigation is told by: without its fragment, which no
    /// request carries, its scheme and host in lower case.
    nonisolated static func navigation(_ address: String) -> String {
        guard var parts = URLComponents(string: address) else { return address }
        parts.fragment = nil
        parts.scheme = parts.scheme?.lowercased()
        parts.host = parts.host?.lowercased()
        return parts.string ?? address
    }

    // MARK: - The tab's history and the windows its pages ask for (ITER-076 I-10)

    /// The tab's own history, as Chrome keeps it: each entry's id, where it
    /// is now, and whether a form's sending made it.
    func history(of tab: BrowserTab) async throws -> BrowserHistory {
        let reply = try await send("Page.getNavigationHistory", [:], session: tab.tabID)
        let listed = reply["entries"]?.array ?? []
        let entries = listed.compactMap { entry -> BrowserHistory.Entry? in
            guard let id = entry["id"]?.int, let url = entry["url"]?.string else { return nil }
            return BrowserHistory.Entry(id: id, url: url, sentForm: entry["transitionType"]?.string == "form_submit")
        }
        guard entries.count == listed.count, let current = reply["currentIndex"]?.int,
              entries.indices.contains(current) else { throw BrowserBridgeError.scriptFailed(code: -1) }
        return BrowserHistory(entries: entries, current: current)
    }

    /// A person's Back, to the entry whose id is `entry` (a reference browser
    /// agent's `_back`, `page.py` 993-1009, MIT): Chrome brings the page back
    /// as it kept it — from its back-forward cache whole, or loaded again
    /// with what its fields held.
    func goBack(to entry: Int, in tab: BrowserTab) async throws {
        _ = try await send("Page.navigateToHistoryEntry", ["entryId": .number(Double(entry))], session: tab.tabID)
    }

    func windowsOpened(in tab: BrowserTab) -> [String] {
        guard let watch = watches[tab.windowID] else { return [] }
        defer { watch.opened = [] }
        return watch.opened
    }

    // MARK: - The user's part (ITER-076 stage 3)

    /// The tab is the user's while the errand waits for their part: no
    /// window it opens is closed — a "Sign in with Google" one — and its
    /// page's dialogs and file pickers are theirs, as a tab let go is
    /// (`letGo`). Its requests are still let on or refused as ever.
    func lend(_ tab: BrowserTab) async {
        guard let watch = watches[tab.windowID], !watch.lent else { return }
        watch.lent = true
        await letGo(watch)
    }

    /// The tab is the agent's again: every window it has open now is the
    /// user's — never closed, then or when the tab is — and its dialogs and
    /// file pickers are the agent's again.
    func reclaim(_ tab: BrowserTab) async {
        guard let watch = watches[tab.windowID], watch.lent else { return }
        if let targets = try? await send("Target.getTargets", [:]) {
            watch.usersWindows.formUnion(Self.windows(in: targets, openedBy: tab.windowID))
        }
        watch.lent = false
        watch.drives = true
        for session in [watch.page] + watch.frames.map(\.session) {
            _ = try? await send("Page.setInterceptFileChooserDialog", ["enabled": true], session: session)
        }
    }

    /// Show tab: the agent's own tab fronted, by its target (a reference
    /// browser agent's `switch_tab`, `session.py` 370-374, MIT), and the
    /// browser's app in front of the user's.
    func show(_ tab: BrowserTab) async {
        _ = try? await send("Target.activateTarget", ["targetId": .string(tab.windowID)])
        bringForward?()
    }

    // MARK: - The tab's guard (ITER-076 I-09)

    /// The user's Yes for the step acting in a tab, and the act it was given
    /// for (Codex review 1 of I-09, P1-3, P1-4): one dialog of that act's own
    /// document is answered under it, and no more (Claude review c8 of I-09,
    /// #16). Taken back on the main actor and read where an answer is handed
    /// to the socket, on the socket's queue — under its lock (Codex review 2
    /// of I-09, P1-5). The document is the one the act's frame held when the
    /// Yes was armed, by the loader id the browser gave it: a document that
    /// frame commits later — the page the act's click loaded included — is
    /// another, and the Yes is not its (ITER-076 I-09, round 5; Claude review
    /// c10, #13). Nil when the frame's document was not known then: no
    /// dialog answers to it.
    private final class Permit: @unchecked Sendable {
        let act: ApprovedAct
        let document: String?
        private let lock = NSLock()
        private var spent = false
        private var takenBack = false

        init(_ act: ApprovedAct, document: String?) {
            self.act = act
            self.document = document
        }

        /// The act, for the first dialog that asks under the Yes while it
        /// stands; nil for any later one.
        func spend() -> ApprovedAct? {
            lock.lock()
            defer { lock.unlock() }
            guard !spent, !takenBack else { return nil }
            spent = true
            return act
        }

        func takeBack() {
            lock.lock()
            takenBack = true
            lock.unlock()
        }

        /// Whether the Yes still stands: not taken back.
        var stands: Bool {
            lock.lock()
            defer { lock.unlock() }
            return !takenBack
        }
    }

    /// What a tab did, kept as it is noted — on the main actor, or on the
    /// socket's queue as an answer goes out (Codex review 2 of I-09, P1-5) —
    /// under its lock: the newest `maxEvents` of it and, until it is read,
    /// the first dialog that named the user's part, the first one answered
    /// Cancel, or Stay, and a send held back, which no flood of other events
    /// pushes out (Claude review of I-09, kept 2; Claude review c8, #15;
    /// ITER-076 stage 7, review round 1, C2).
    private final class TabLog: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [BrowserEvent] = []

        func note(_ event: BrowserEvent) {
            lock.lock()
            defer { lock.unlock() }
            if case .dialogNamed = event {
                guard !events.contains(where: { if case .dialogNamed = $0 { true } else { false } }) else { return }
            }
            if event == .sendHeld, events.contains(.sendHeld) { return }
            events.append(event)
            while events.count > ChromeBridge.maxEvents {
                let declined = events.firstIndex(where: Self.isDeclined)
                guard let oldest = events.indices.first(where: { !Self.isNamed(events[$0]) && $0 != declined }) else {
                    break
                }
                events.remove(at: oldest)
            }
        }

        /// What was noted since the last read, oldest first — and no longer
        /// kept.
        func take() -> [BrowserEvent] {
            lock.lock()
            defer { lock.unlock() }
            let taken = events
            events = []
            return taken
        }

        /// A dialog that named the user's part, or a send held back: kept
        /// until read.
        private static func isNamed(_ event: BrowserEvent) -> Bool {
            switch event {
            case .dialogNamed, .sendHeld: true
            default: false
            }
        }

        private static func isDeclined(_ event: BrowserEvent) -> Bool {
            if case .dialog(let kind, accepted: false) = event { kind != .alert } else { false }
        }
    }

    /// True the first time only, from any thread.
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var used = false

        func first() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !used else { return false }
            used = true
            return true
        }
    }

    /// What the bridge keeps of one open tab: the session its page is
    /// attached with, its frames that run in a process of their own, the
    /// sessions its document requests are paused on, what it did, and the
    /// Yes the step acting in it has.
    @MainActor
    private final class TabWatch {
        let page: String
        /// The tab's target id, which is its page's main frame's id.
        let target: String
        /// Each frame in a process of its own, in the order they came.
        var frames: [FrameSession] = []
        /// Each frame of the page, by its id: the session its document is
        /// reached by, as the frames were last listed.
        var hosts: [String: String] = [:]
        var guards: Set<String> = []
        let log = TabLog()
        var permit: Permit?
        /// Each frame's document, by the frame's id: the loader id of the
        /// last one the browser said it committed there — none for a frame
        /// whose process changed since (ITER-076 I-09, round 5; Claude review
        /// c10, #13).
        var documents: [String: String] = [:]
        /// Whether the agent still drives the tab: false once its close
        /// failed — each time it was tried, or with an error — when its
        /// dialogs and file pickers are the user's (Claude review c7 of I-09,
        /// #10; Codex review 2 of I-09, P2-4).
        var drives = true
        /// The addresses of the windows its pages asked to open on a
        /// person's input, the newest `maxEvents` (ITER-076 I-10).
        var opened: [String] = []
        /// The downloads refused, by their ids.
        var refused: Set<String> = []
        /// The user has the tab while the errand waits for their part
        /// (ITER-076 stage 3): no window it opens is closed.
        var lent = false
        /// The windows it had open when the user gave it back, by target id:
        /// theirs, never closed (ITER-076 stage 3).
        var usersWindows: Set<String> = []
        /// Its sends are held (`holdSends`; ITER-076 stage 7, review rounds 1
        /// and 2, C2, R2-1).
        var holdsSends = false
        /// While held, the agent's own navigations (`letNavigate`): the
        /// addresses its acts go to, and the requests that went there and
        /// on along their redirects, by their ids (review round 2, R2-2) —
        /// and every address those requests went to: where the document the
        /// agent's own navigation brings comes from (review round 3, R3-3).
        var navigationsLetGo: Set<String> = []
        var requestsLetGo: Set<String> = []
        var arrived: Set<String> = []
        /// The address its page shows — as it was drawn, or as its own script
        /// rewrote it — and, while held, every address the held page showed:
        /// an address it showed is never where the agent's navigation went
        /// (review round 3, R3-3).
        var pageAddress: String?
        var heldPages: Set<String> = []
        var heldDocument: String?
        var listener: Task<Void, Never>?

        init(page: String, target: String) {
            self.page = page
            self.target = target
        }

        /// Whether `session` is the page's or one of its frames'.
        func holds(_ session: String) -> Bool {
            session == page || frames.contains { $0.session == session }
        }

        /// Keeps what the tab did (`TabLog`).
        func note(_ event: BrowserEvent) {
            log.note(event)
        }
    }

    /// A frame of the tab in a process of its own: its target — whose id is
    /// the frame's — the session it was attached with, the session it was
    /// attached from, whether it runs: watched, and let go on — and how many
    /// frames its process held when it last said what it holds: itself and
    /// the frames in its process; nil until it has (Codex review 2 of I-09,
    /// P2-5).
    private struct FrameSession {
        let target: String
        let session: String
        let parent: String
        var running = false
        var held: Int?
    }

    /// The most a tab keeps of what it did between two reads of it.
    nonisolated static let maxEvents = 200

    /// Frames of the page in a process of their own are attached as they
    /// come — frames only, no workers — each paused until it is watched as
    /// the page is (a reference browser agent's `session.py` auto-attach, MIT).
    private static let frameAttach: CDPValue = ["autoAttach": true, "waitForDebuggerOnStart": true, "flatten": true,
                                                "filter": [["type": "iframe"], ["exclude": true]]]

    /// Every document the tab asks for — its page's and each frame's — is
    /// paused twice: as it is asked for, where an address the agent never
    /// opens is refused, and as its answer comes, where one that is a download
    /// is refused before anything is saved. Ported from a reference browser agent's
    /// `DOWNLOAD_PATTERNS` (`session.py` 63-69, MIT), with the request stage
    /// added for the addresses.
    private static let documentRequests: CDPValue = ["patterns": [
        ["urlPattern": "*", "resourceType": "Document", "requestStage": "Request"],
        ["urlPattern": "*", "resourceType": "Document", "requestStage": "Response"],
    ]]

    /// While the tab's sends are held (`holdSends`): its documents as ever,
    /// and every other request of it too, as it is asked for — a fetch, an
    /// XHR, a beacon (ITER-076 stage 7, review round 2, R2-1).
    private static let heldRequests: CDPValue = ["patterns": [
        ["urlPattern": "*", "resourceType": "Document", "requestStage": "Request"],
        ["urlPattern": "*", "resourceType": "Document", "requestStage": "Response"],
        ["urlPattern": "*", "requestStage": "Request"],
    ]]

    /// A session of the guard's own on `target`, attached after every other:
    /// it is the first to see each request and the last to see each answer,
    /// and no other client's patterns replace its own — a session takes one
    /// set of patterns (`Fetch.enable` again replaces them; checked on Chrome
    /// 154, 2026-10-02).
    private func guardRequests(of target: String, in watch: TabWatch) async throws {
        let attached = try await send("Target.attachToTarget", ["targetId": .string(target), "flatten": true])
        guard let session = attached["sessionId"]?.string else { throw BrowserBridgeError.tabNotFound }
        watch.guards.insert(session)
        _ = try await send("Fetch.enable", watch.holdsSends ? Self.heldRequests : Self.documentRequests, session: session)
    }

    /// Hears every event of the connection for the tab for as long as Chrome
    /// keeps the tab's guard — its requests paused, its frames held until
    /// watched — that is, as long as the tab (ITER-076 I-09 review, NET-4).
    /// It holds the bridge as long: a close that failed leaves a tab still
    /// guarded, never one whose requests wait for an answer forever. It ends
    /// when the tab is closed (`close`), when the tab is gone — its page's
    /// session detached — or when the connection ends.
    private func listen(to events: AsyncStream<CDPEvent>, tab target: String) -> Task<Void, Never> {
        Task {
            for await event in events {
                guard let watch = self.watches[target] else { return }
                if event.method == "Target.detachedFromTarget", event.params["sessionId"]?.string == watch.page { return }
                self.take(event, in: watch)
            }
        }
    }

    private func take(_ event: CDPEvent, in watch: TabWatch) {
        // A session of the guard's own that Chrome detached — its frame taken
        // away, its target gone — is the guard's no more: there is nothing
        // there for a hold to be put in place on (review round 3, R3-2).
        if event.method == "Target.detachedFromTarget", let gone = event.params["sessionId"]?.string {
            watch.guards.remove(gone)
        }
        guard let session = event.sessionID else { return }
        switch event.method {
        case "Fetch.requestPaused" where watch.guards.contains(session):
            pass(event, on: session, in: watch)
        case "Page.javascriptDialogOpening" where watch.holds(session) && watch.drives:
            answer(event, on: session, in: watch)
        case "Page.downloadWillBegin" where watch.holds(session):
            refuseDownload(event, in: watch)
        case "Page.windowOpen" where watch.holds(session):
            // None is opened (`sandbox`): the run reads where it was to go.
            guard event.params["userGesture"]?.bool == true, let address = event.params["url"]?.string else { return }
            watch.opened.append(address)
            if watch.opened.count > Self.maxEvents { watch.opened.removeFirst(watch.opened.count - Self.maxEvents) }
        case "Page.frameNavigated" where watch.holds(session):
            if let frame = event.params["frame"]?["id"]?.string {
                watch.documents[frame] = event.params["frame"]?["loaderId"]?.string
                if frame == watch.target { watch.pageAddress = event.params["frame"]?["url"]?.string }
            }
        case "Page.navigatedWithinDocument" where watch.holds(session):
            // The page's own script rewrote its address: while its sends are
            // held, that address is the held page's too (review round 3, R3-3).
            if event.params["frameId"]?.string == watch.target, let address = event.params["url"]?.string {
                watch.pageAddress = address
                if watch.holdsSends, watch.documents[watch.target] == watch.heldDocument {
                    watch.heldPages.insert(Self.navigation(address))
                }
            }
        case "Target.attachedToTarget" where watch.holds(session):
            // A frame in a process of its own holds a document it has not
            // said it committed yet: not the one its old process held.
            if let frame = event.params["targetInfo"]?["targetId"]?.string { watch.documents[frame] = nil }
            Task { await self.watchFrame(event, from: session, in: watch) }
        case "Target.detachedFromTarget" where watch.holds(session):
            let gone = event.params["sessionId"]?.string
            watch.frames.removeAll { $0.session == gone }
        default:
            break
        }
    }

    /// A frame in a process of its own, paused as it starts, is watched as
    /// the page is — its dialogs, its downloads, its own frames, its file
    /// picker, its requests — and only then let run. One whose requests
    /// cannot be guarded is never let run.
    private func watchFrame(_ event: CDPEvent, from parent: String, in watch: TabWatch) async {
        guard event.params["targetInfo"]?["type"]?.string == "iframe",
              let child = event.params["sessionId"]?.string,
              let target = event.params["targetInfo"]?["targetId"]?.string else { return }
        watch.frames.append(FrameSession(target: target, session: child, parent: parent))
        _ = try? await send("Page.enable", [:], session: child)
        if watch.drives { _ = try? await send("Page.setInterceptFileChooserDialog", ["enabled": true], session: child) }
        _ = try? await send("Target.setAutoAttach", Self.frameAttach, session: child)
        do {
            try await prepareTab?(child)
            try await guardRequests(of: target, in: watch)
        } catch {
            return
        }
        _ = try? await send("Runtime.runIfWaitingForDebugger", [:], session: child)
        if let index = watch.frames.firstIndex(where: { $0.session == child }) { watch.frames[index].running = true }
    }

    // MARK: - Frames (ITER-076 I-09)

    /// Every frame of the tab's page, its own process's first, then each
    /// frame in a process of its own that runs, with the frames in its
    /// process (a reference browser agent's `frame_sessions`, `session.py` 237-247,
    /// MIT). Each is reached by the session its document lives in.
    ///
    /// Each is known by who it is across looks (`identity`). A frame in a
    /// process of its own is held, so, by its session's: the page's, or that
    /// of the frame it was attached from. One whose holder is no frame of the
    /// tab any more is not either: it went with it, and the browser does not
    /// say so of it — it is never asked. The others are asked all at once,
    /// each within `frameTreeLimit`, as a reference browser agent reads its
    /// frames (`page.py` `_read_frames`, MIT): on the session of one that goes
    /// as it is asked the browser answers nothing. One that does not answer
    /// in time — and every frame inside it — holds no look up, and is counted
    /// as not listed, never left out silently (Codex review 1 of I-09, P2-2):
    /// it and each frame in its process, as many as it said it held when it
    /// last did — what one that never did holds is not known (Codex review 2
    /// of I-09, P2-5). One whose setup failed never runs: the document that
    /// stood in it before stays in its holder's process, and is listed there.
    func frames(of tab: BrowserTab) async throws -> FrameListing {
        guard let watch = watches[tab.windowID] else { throw BrowserBridgeError.tabNotFound }
        var hosts: [String: String] = [:]
        var listing = FrameListing()
        func list(_ id: String, _ identity: String, on session: String) {
            hosts[id] = session
            listing.frames.append(BrowserFrame(tab: tab.inFrame(id), identity: identity))
        }
        func collect(_ node: CDPValue?, on session: String, under holder: String) {
            for child in node?["childFrames"]?.array ?? [] {
                guard let id = child["frame"]?["id"]?.string else { continue }
                let own = Self.identity(of: child["frame"], under: holder)
                list(id, own, on: session)
                collect(child, on: session, under: own)
            }
        }
        collect(try await send("Page.getFrameTree", [:], session: tab.tabID)["frameTree"], on: tab.tabID, under: "")
        // A frame is attached from its holder once its holder runs: a holder
        // comes before the frames it holds.
        var tabs: Set<String> = [tab.tabID]
        let running = watch.frames.filter { frame in
            guard frame.running, tabs.contains(frame.parent) else { return false }
            tabs.insert(frame.session)
            return true
        }
        let trees = await withTaskGroup(of: (String, CDPValue?).self) { group in
            for frame in running {
                group.addTask { @MainActor in
                    (frame.session, try? await self.send("Page.getFrameTree", [:], session: frame.session,
                                                         timeout: Self.frameTreeLimit)["frameTree"])
                }
            }
            var trees: [String: CDPValue] = [:]
            for await (session, tree) in group { trees[session] = tree }
            return trees
        }
        var holders = [tab.tabID: ""]
        for frame in running {
            let tree = trees[frame.session]
            let held = tree.map(Self.framesHeld) ?? frame.held
            if tree != nil, let index = watch.frames.firstIndex(where: { $0.session == frame.session }) {
                watch.frames[index].held = held
            }
            guard let holder = holders[frame.parent], let tree, let id = tree["frame"]?["id"]?.string else {
                listing.unread += held ?? 1
                if held == nil { listing.unknown += 1 }
                continue
            }
            let own = Self.identity(of: tree["frame"], under: holder)
            holders[frame.session] = own
            list(id, own, on: frame.session)
            collect(tree, on: frame.session, under: own)
        }
        watch.hosts = hosts
        return listing
    }

    /// How many frames a frame's tree holds in its process: itself, and each
    /// frame inside it there.
    private static func framesHeld(_ tree: CDPValue) -> Int {
        1 + (tree["childFrames"]?.array ?? []).reduce(0) { $0 + framesHeld($1) }
    }

    /// Who a frame is across looks (review of I-09, F5): the frame that holds
    /// it — "" for the page — and its origin. Never the browser's id for it,
    /// which a reload changes, and never its place among its siblings: that
    /// hangs on which of them answered (Codex review 1 of I-09, P2-1) and on
    /// which are still loading (Claude review c7 of I-09, #20), and it would
    /// tell apart controls that differ by nothing else — twins, whose Yes or
    /// No could reach any of them (#4).
    private static func identity(of frame: CDPValue?, under holder: String) -> String {
        holder + "/" + (frame?["securityOrigin"]?.string ?? "")
    }

    /// Where a point of a frame's viewport lies in the tab's — when a click
    /// there reaches that frame. Frame by frame up to the page: the frame is
    /// brought on screen in the document that holds it, as the aim brings a
    /// control; its box there gives the point (a frame drawn scaled, as
    /// drawn); and there Chrome's own hit test must find that frame — not a
    /// layer of the page, nor another frame, over it. Ported from a reference
    /// browser agent's hit test through frames (`page.py` 69-106, MIT), done
    /// by the browser where a frame is in a process of its own. Then every
    /// document on the way draws what it holds: Chrome sends a click to a
    /// frame by the last frame drawn, not by the page as it is now (that
    /// agent's `_PRESENTED_JS` and `_move`, `page.py` 113-118, 1046-1056). A
    /// frame that is gone meanwhile is reached nowhere.
    func point(x: Double, y: Double, in tab: BrowserTab) async throws -> (x: Double, y: Double)? {
        guard var frame = tab.frame else { return (x, y) }
        guard let watch = watches[tab.windowID] else { throw BrowserBridgeError.tabNotFound }
        var (x, y) = (x, y)
        var documents: [BrowserTab] = []
        do {
            while true {
                let own = watch.frames.first { $0.target == frame }
                guard let holder = own?.parent ?? watch.hosts[frame] else { return nil }
                documents.append(tab.inFrame(frame))
                let size = try await run("innerWidth + ' ' + innerHeight", in: tab.inFrame(frame))
                    .split(separator: " ").compactMap { Double($0) }
                guard size.count == 2 else { return nil }
                let owner = try await send("DOM.getFrameOwner", ["frameId": .string(frame)], session: holder)
                guard let node = owner["backendNodeId"] else { return nil }
                _ = try await send("DOM.scrollIntoViewIfNeeded", ["backendNodeId": node], session: holder)
                let model = try await send("DOM.getBoxModel", ["backendNodeId": node], session: holder)
                guard let box = model["model"]?["content"]?.array?.compactMap(\.double), box.count == 8,
                      box[1] == box[3], box[0] == box[6] else { return nil }
                guard let placed = Self.framePoint(x, y, box: box, width: size[0], height: size[1]) else { return nil }
                (x, y) = placed
                // A box is where the holder's viewport shows it; the hit test
                // takes a place on the holder's whole page, its scroll added
                // as the browser has it — a script's `scrollY` can lag a scroll
                // just made (all three checked on Chrome 154, 2026-10-02).
                let page = try await send("Page.getLayoutMetrics", [:], session: holder)["cssLayoutViewport"]
                guard let left = page?["pageX"]?.double, let top = page?["pageY"]?.double,
                      let hit = try? await send("DOM.getNodeForLocation",
                                                ["x": .number((x + left).rounded(.down)),
                                                 "y": .number((y + top).rounded(.down))], session: holder)
                else { return nil }
                // Seen from the document that holds it, a frame in a process
                // of its own is its owner element; one in the same process is
                // itself.
                guard own == nil ? hit["frameId"]?.string == frame : hit["backendNodeId"] == node else { return nil }
                if holder == tab.tabID { break }
                guard let up = watch.frames.first(where: { $0.session == holder })?.target else { return nil }
                frame = up
            }
        } catch BrowserBridgeError.tabNotFound {
            return nil
        } catch BrowserBridgeError.scriptFailed {
            return nil
        }
        for document in documents + [tab] { _ = try? await run(Self.drawn + ".then(() => 'drawn')", in: document) }
        return (x, y)
    }

    /// Where a point of a frame's viewport — `width` by `height` — is drawn
    /// in the document that holds it: `box`, the frame's content quad there,
    /// axis-aligned. Each axis by its own ratio of drawn to own size, as a
    /// reference browser agent's hit test does (`page.py` 69-106, MIT). A
    /// frame drawn squeezed on one axis beyond `squeezeTolerance`, or of no
    /// size, has no point: the browser's hit test finds only the frame, not
    /// the control, and a press there may land on another one (review of
    /// I-09, F7).
    nonisolated static func framePoint(_ x: Double, _ y: Double, box: [Double], width: Double,
                                       height: Double) -> (x: Double, y: Double)? {
        guard box.count == 8, width > 0, height > 0 else { return nil }
        let across = (box[2] - box[0]) / width, down = (box[5] - box[1]) / height
        guard across > 0, down > 0, abs(across - down) <= squeezeTolerance * max(across, down) else { return nil }
        return (box[0] + x * across, box[1] + y * down)
    }

    /// How far the two ratios of a frame drawn scaled may differ — a
    /// rounding of its drawn size, no more.
    nonisolated static let squeezeTolerance = 0.01

    /// Resolves once the document has drawn a frame, or after 100 ms where a
    /// hidden one never draws (a reference browser agent's `_PRESENTED_JS`,
    /// `page.py` 113-118, MIT).
    private static let drawn = "new Promise(done => { const t = setTimeout(done, 100); "
        + "requestAnimationFrame(() => requestAnimationFrame(() => "
        + "setTimeout(() => { clearTimeout(t); done(); }, 0))); })"

    /// A document request let go on, or refused: as it is asked for, one at
    /// an address the agent never opens — by its host's name, or by where
    /// the Mac's own resolver takes that name (`leadsHome`, ITER-076 stage
    /// 9e); as its answer comes, one that is a download. Never kept paused
    /// longer than its host's lookup (a reference browser agent's
    /// `_handle_paused`, `session.py` 617-629, MIT); a refusal fails it as
    /// aborted, which leaves the page where it was, as a download does. A
    /// document the tab draws comes with `sandbox`: it opens no window
    /// (ITER-076 I-10). One whose answer cannot be given so is refused.
    private func pass(_ event: CDPEvent, on session: String, in watch: TabWatch) {
        guard let request = event.params["requestId"]?.string else { return }
        if let kind = event.params["resourceType"]?.string, kind != "Document" {
            return passHeld(request, event, on: session, in: watch)
        }
        let refusal: BrowserEvent?
        var drawn: CDPValue?
        // A web document's host, as it is asked for: where its name leads is
        // read before it goes on.
        var host: String?
        if event.params["responseStatusCode"] != nil || event.params["responseErrorReason"] != nil {
            var headers: [String: String] = [:]
            for header in event.params["responseHeaders"]?.array ?? [] {
                if let name = header["name"]?.string?.lowercased() { headers[name] = header["value"]?.string ?? "" }
            }
            // An answer that never came — the request failed on its way — and
            // a redirect are neither drawn nor saved: Chrome follows a
            // redirect, and pauses the request it makes at its own request
            // stage (the protocol's `Fetch.requestPaused`).
            let status = event.params["responseStatusCode"]?.int
            let redirect = status.map(Self.redirects.contains) == true && headers["location"] != nil
            let download = status != nil && !redirect
                && Self.isDownload(type: headers["content-type"] ?? "", disposition: headers["content-disposition"] ?? "")
            refusal = download ? .downloadRefused : nil
            if let status, !redirect, !download {
                var answer: [String: CDPValue] = [
                    "requestId": .string(request), "responseCode": .number(Double(status)),
                    "responseHeaders": .array((event.params["responseHeaders"]?.array ?? []) + [
                        ["name": "Content-Security-Policy", "value": .string(Self.sandbox)],
                    ]),
                ]
                if let phrase = event.params["responseStatusText"]?.string, !phrase.isEmpty {
                    answer["responsePhrase"] = .string(phrase)
                }
                drawn = .object(answer)
            }
        } else {
            let address = event.params["request"]?["url"]?.string ?? ""
            // While a form's sends are held, the tab's page leaves for nothing
            // — but by the agent's own act, by GET, and on along its
            // redirects (review round 2, R2-2) — and no frame of it is sent a
            // form — a request with a body: a form its page's own script
            // sends is held back; a frame may still load its page (ITER-076
            // stage 7, review round 1, C2).
            let method = event.params["request"]?["method"]?.string?.uppercased() ?? "GET"
            var held = false
            if watch.holdsSends {
                let fromArrival = Self.comesFromArrival(event, in: watch)
                if event.params["frameId"]?.string == watch.target {
                    let ours = fromArrival || method == "GET" && (watch.navigationsLetGo.contains(Self.navigation(address))
                        || event.params["redirectedRequestId"]?.string.map(watch.requestsLetGo.contains) == true)
                    if ours {
                        watch.requestsLetGo.insert(request)
                        let arrival = Self.navigation(address)
                        if !watch.heldPages.contains(arrival) { watch.arrived.insert(arrival) }
                    } else {
                        held = true
                    }
                } else {
                    held = method != "GET" && !fromArrival
                }
            }
            refusal = held ? .sendHeld : Self.refuses(address) ? .addressRefused : nil
            if refusal == nil { host = Self.webHost(of: address) }
        }
        if let refusal { watch.note(refusal) }
        Task {
            var refused = refusal != nil
            if let host, await self.leadsHome(host) {
                watch.note(.addressRefused)
                refused = true
            }
            if !refused, let drawn {
                if (try? await self.send("Fetch.continueResponse", drawn, session: session)) == nil {
                    _ = try? await self.send("Fetch.failRequest",
                                             ["requestId": .string(request), "errorReason": "Aborted"], session: session)
                }
            } else if !refused {
                _ = try? await self.send("Fetch.continueRequest", ["requestId": .string(request)], session: session)
            } else {
                _ = try? await self.send("Fetch.failRequest", ["requestId": .string(request), "errorReason": "Aborted"],
                                         session: session)
            }
        }
    }

    /// A request of the tab's that is no document, paused only while its sends
    /// are held (ITER-076 stage 7, review round 2, R2-1): one that sends —
    /// any method but GET: a fetch, an XHR, a beacon — is refused before it
    /// goes out, and the page's send fails; nothing else changes, and a GET
    /// goes on as it would have.
    private func passHeld(_ request: String, _ event: CDPEvent, on session: String, in watch: TabWatch) {
        let method = event.params["request"]?["method"]?.string?.uppercased() ?? "GET"
        let refused = watch.holdsSends && method != "GET" && !Self.comesFromArrival(event, in: watch)
        Task {
            if refused {
                _ = try? await self.send("Fetch.failRequest", ["requestId": .string(request), "errorReason": "Aborted"],
                                         session: session)
            } else {
                _ = try? await self.send("Fetch.continueRequest", ["requestId": .string(request)], session: session)
            }
        }
    }

    /// Whether a paused request comes from the document the agent's own
    /// navigation brought — the page at an address that navigation went to,
    /// as the request's `Referer` names it: that document's requests are its
    /// own, from its first script on, whatever the hold on the page it left
    /// (review round 3, R3-3). What the page left sends as it goes — a beacon
    /// as it is left — names that page's own address, and is held. A
    /// `Referer` that names only a site — all a page whose policy keeps its
    /// address to itself says, on each page of the site — or none names no
    /// document: that request is held, as every send is while the hold lasts.
    private static func comesFromArrival(_ event: CDPEvent, in watch: TabWatch) -> Bool {
        guard !watch.arrived.isEmpty, let headers = event.params["request"]?["headers"]?.object,
              let referer = headers.first(where: { $0.key.lowercased() == "referer" })?.value.string,
              let parts = URLComponents(string: referer), parts.path.count > 1 || parts.query != nil else { return false }
        return watch.arrived.contains(navigation(referer))
    }

    /// What every document the agent's tab draws may do (ITER-076 I-10) —
    /// what a page in its own tab may do, but four things, each refused by
    /// the flag it is not given (all checked on Chrome 154, 2026-10-03):
    /// - open a window (`allow-popups`): a window a page opens on a person's
    ///   click goes to Chrome as a tab of its own, beyond the guard, and its
    ///   first request leaves before anything can stop it — Chrome attaches a
    ///   debugger to no window a tab opens, paused or not. None is opened, and
    ///   Chrome still says where it was to go (`Page.windowOpen`);
    /// - start a download itself (`allow-downloads`): a `download` link, a data
    ///   or blob address, never begins — the race the cancel of
    ///   `refuseDownload` loses on a small file is gone; an answer that is a
    ///   file is still refused as it comes;
    /// - in a frame, hand itself to another app through a custom scheme: a
    ///   frame may do that while any of `allow-top-navigation`,
    ///   `allow-top-navigation-by-user-activation` or
    ///   `allow-top-navigation-to-custom-protocols` is given, so none is —
    ///   and a frame cannot move the tab's page either. Known limit: the
    ///   tab's page itself is never held back by its own policy, whatever
    ///   flags it lacks: Chrome still tries to open the app it names;
    /// - escape the policy in a window (`allow-popups-to-escape-sandbox`).
    nonisolated static let sandbox = "sandbox allow-forms allow-modals allow-orientation-lock allow-pointer-lock "
        + "allow-presentation allow-same-origin allow-scripts allow-storage-access-by-user-activation"

    /// A document at an address the agent never opens (owner decision D7):
    /// a web address whose host is private, or one that cannot be read.
    nonisolated static func refuses(_ address: String) -> Bool {
        let scheme = address.prefix { $0 != ":" }.lowercased()
        guard scheme == "http" || scheme == "https" else { return false }
        guard let host = URL(string: address)?.host, !host.isEmpty else { return true }
        return DiaScript.isPrivate(host: host)
    }

    /// Whether the Mac's own resolver takes `host` to the user's own machine
    /// or network (owner decision D7; ITER-076 stage 9e): any one of its
    /// addresses is private, as `DiaScript.isPrivate(host:)` reads an
    /// address — or no answer came within `resolveLimit`, and no page goes on
    /// unseen. A name the resolver says does not exist leads nowhere: it goes
    /// on, and Chrome shows it cannot be reached.
    private func leadsHome(_ host: String) async -> Bool {
        let resolve = self.resolve
        guard let addresses = await Deadline.run(within: Self.resolveLimit, { await resolve(host) }) ?? nil else {
            return true
        }
        return addresses.contains { DiaScript.isPrivate(host: $0) }
    }

    /// How long the Mac's resolver may take to answer for a document's host.
    static let resolveLimit: Duration = .seconds(3)

    /// The host of a web address; none for any other, whose address is never
    /// looked up.
    private nonisolated static func webHost(of address: String) -> String? {
        let scheme = address.prefix { $0 != ":" }.lowercased()
        guard scheme == "http" || scheme == "https" else { return nil }
        return URL(string: address)?.host
    }

    /// The addresses the Mac's own resolver gives `host`, each as its numeric
    /// string (ITER-076 stage 9e): of both families, every one — asked off
    /// the main thread, as the system's lookup waits on the network. None
    /// when it says no such name exists, or that the name has no address;
    /// nil when it gives no answer: any other failure, or an address it
    /// cannot write out.
    nonisolated static func addresses(of host: String) async -> [String]? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: lookUp(host))
            }
        }
    }

    /// `addresses(of:)`, on the calling thread.
    private nonisolated static func lookUp(_ host: String) -> [String]? {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var list: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, nil, &hints, &list)
        defer { if let list { freeaddrinfo(list) } }
        if status == EAI_NONAME || status == EAI_NODATA { return [] }
        guard status == 0 else { return nil }
        var addresses: [String] = []
        var entry = list
        while let current = entry?.pointee {
            var text = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard let address = current.ai_addr,
                  getnameinfo(address, current.ai_addrlen, &text, socklen_t(text.count), nil, 0, NI_NUMERICHOST) == 0
            else { return nil }
            addresses.append(String(cString: text))
            entry = current.ai_next
        }
        return addresses
    }

    /// The answers to a request that are a redirect: Chrome follows them
    /// (the protocol's `Fetch.requestPaused`: 301, 302, 303, 307 and 308 with
    /// a `location`).
    nonisolated static let redirects: Set<Int> = [301, 302, 303, 307, 308]

    /// The types of answer the agent's tab takes: ones Chrome draws as a page
    /// (ITER-076 I-09 review, NET-2). Any other is a file Chrome may save,
    /// refused before a byte of it is written. Not a PDF: the user's Chrome
    /// may be set to save PDFs (Claude review c7 of I-09, #8).
    nonisolated static let drawnTypes: Set<String> = [
        "text/html", "application/xhtml+xml", "text/plain", "text/xml", "application/xml", "application/json",
    ]
    /// The pictures, sounds and films taken as ones Chrome draws as a page:
    /// of their families, only these, each a type Chrome draws everywhere.
    /// One it does not draw, it saves (Claude review c7 of I-09, #8); a type
    /// left out here that Chrome would have drawn costs a step, never a
    /// file.
    nonisolated static let drawnMedia: Set<String> = [
        "image/png", "image/apng", "image/x-png", "image/jpeg", "image/jpg", "image/pjpeg", "image/gif", "image/webp",
        "image/avif", "image/bmp", "image/x-icon", "image/vnd.microsoft.icon", "image/svg+xml",
        "audio/mpeg", "audio/mp3", "audio/mp4", "audio/ogg", "audio/wav", "audio/x-wav", "audio/webm", "audio/flac",
        "video/mp4", "video/webm", "video/ogg",
    ]

    /// Whether an answer is a file Chrome saves rather than a page it draws:
    /// one whose disposition is of any type but `inline` — an attachment, a
    /// misspelt type, a form's part, a bare file name: Chrome takes them all
    /// for an attachment (RFC 6266 4.2; Claude review c7 of I-09, #8) — or
    /// one of any type but those the tab takes — no type, an unknown one,
    /// more than one included. An `inline` disposition that names a file is
    /// drawn as its type says, as Chrome draws it: a hosting service sends
    /// every page of a site so (2026-10-19: a contact page refused as a
    /// download on every brain, the brain blind to why). Any other download
    /// the tab begins — a `download` link, a data or blob address — is
    /// refused as it begins (`refuseDownload`). Known limits, read at no
    /// answer here: a `text/plain` answer without `nosniff` whose bytes
    /// Chrome sniffs as a file, and a page the site's service worker answers
    /// itself — its answer never reaches the tab's requests; each is
    /// cancelled as it begins.
    nonisolated static func isDownload(type: String, disposition: String) -> Bool {
        let lowered = disposition.lowercased()
        let kind = (lowered.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? "")
            .trimmingCharacters(in: .whitespaces)
        if !kind.isEmpty && kind != "inline" { return true }
        // A type that holds a comma is more than one: Chrome splits it at its
        // commas and takes the last type it can read, whatever stands before
        // — a drawn one's parameters included (Claude review c8 of I-09,
        // #27). Any comma is a file, one inside quotes too: that costs a
        // step, never a file.
        if type.contains(",") { return true }
        // Only a type written exactly as one the tab takes is a page: no
        // type, a second one slipped in, a space or a wildcard, is a file.
        let media = (type.split(separator: ";", maxSplits: 1).first.map(String.init) ?? "")
            .trimmingCharacters(in: .whitespaces).lowercased()
        return !drawnTypes.contains(media) && !drawnMedia.contains(media)
    }

    /// A download the tab began after all is cancelled at once — and only
    /// that one: the user's own tabs download as they always do. Chrome may
    /// have written some of it, or all of a small one, by the time the cancel
    /// lands: this is the path of the downloads the response stage cannot
    /// see (a `download` link, a data or blob address).
    private func refuseDownload(_ event: CDPEvent, in watch: TabWatch) {
        guard let id = event.params["guid"]?.string, watch.refused.insert(id).inserted else { return }
        watch.note(.downloadRefused)
        Task { _ = try? await self.send("Browser.cancelDownload", ["guid": .string(id)]) }
    }

    /// A page's own dialog is answered at once, so it never holds the tab up
    /// (a reference browser agent's `_on_dialog` and `handle_dialog`, `session.py`
    /// 593-609, MIT), as the policy says (`SafetyGuard.answer`): an alert is
    /// closed; a confirm, a prompt or "Leave the page?" guards the step that
    /// brought it — OK, or Leave, once, only under that step's Yes, only when
    /// it comes from the document the act runs in, and only when bound to the
    /// act, otherwise Cancel, or Stay; one whose own words name a payment or a
    /// grant, Cancel, or Stay, and the tab says which it named. A dialog of
    /// another document — a widget of another site, a frame the act never
    /// touched — or of none it names is answered as with no Yes, and leaves
    /// the Yes unspent (Claude review c8 of I-09, #16, #26). Its words are
    /// read here — logged, kept and sent nowhere — and the act's with them.
    /// The step's one dialog uses its Yes up. An OK, or a Leave, goes out only
    /// while that Yes stands, checked in the very turn that hands the answer
    /// to the socket, with nothing between (Codex review 2 of I-09, P1-5): a
    /// Yes taken back before then — Stop, the step's end — makes it Cancel;
    /// one taken back after is an answer already sent, as a click is. The tab
    /// says what went out. An answer that does not go through is Cancel.
    /// What a dialog named is the tab's at once, in the turn that decides it
    /// (review round 4, decision 10; Claude review c9 of I-09, #13, #15): a
    /// dialog that names one is Cancel whatever goes out — and the tab says
    /// so with what it named, in that turn: a hand-over the run makes on
    /// what was named finds the Cancel beside it (ITER-076 I-09, round 5;
    /// Claude review c10, #12). Only whether OK went out waits for the wire.
    /// A dialog is the act's document's only while its frame holds the
    /// document the Yes was given in (`Permit.document`; #13).
    private func answer(_ event: CDPEvent, on session: String, in watch: TabWatch) {
        let kind = PageDialog(rawValue: event.params["type"]?.string ?? "")
        let permit = watch.permit
        let document = event.params["frameId"]?.string
        let loaded = document.flatMap { watch.documents[$0] }
        let ofTheAct = permit.map {
            document != nil && document == ($0.act.frame ?? watch.target) && $0.document != nil && $0.document == loaded
        } == true
        let act = ofTheAct && kind != .alert ? permit?.spend() : nil
        let verdict = kind.map { SafetyGuard.answer($0, saying: event.params["message"]?.string ?? "", under: act) }
        let decided = verdict?.accept == true
        let log = watch.log
        let noted = Once()
        let note = { @Sendable (accept: Bool) in
            guard noted.first() else { return }
            if let kind { log.note(.dialog(kind, accepted: accept)) }
        }
        if let named = verdict?.named {
            log.note(.dialogNamed(named))
            note(false)
        }
        let wire = { @Sendable (going: Bool) -> CDPValue in
            let accept = going && decided && (kind == .alert || permit?.stands == true)
            note(accept)
            return ["accept": .bool(accept)]
        }
        Task {
            await self.beforeAnswer?()
            do {
                _ = try await self.send("Page.handleJavaScriptDialog", session: session, atTheWire: { wire(true) })
            } catch {
                _ = try? await self.send("Page.handleJavaScriptDialog", session: session, atTheWire: { wire(false) })
            }
            note(false)
        }
    }

    // MARK: - The tab's mark (ITER-076 I-09)

    /// The world the mark is kept from: not the agent's.
    private static let markWorldName = "metawhisp-agent-mark"

    /// Keeps `tabMark` before the page's title in every document of the tab:
    /// once the page has a title — and once it has loaded without one — and
    /// again each time it sets one.
    private static let markScript = """
    (() => {
      if (window.top !== window) return;
      const mark = \(markLiteral);
      const titles = document.getElementsByTagName('title');
      const keep = () => {
        if (titles.length === 0 && document.readyState === 'loading') return;
        const title = String(document.title);
        if (!title.startsWith(mark)) document.title = mark + title;
      };
      new MutationObserver(keep).observe(document, { subtree: true, childList: true, characterData: true });
      document.addEventListener('DOMContentLoaded', keep);
      keep();
    })();
    """

    /// The mark as a JavaScript string literal.
    nonisolated static var markLiteral: String {
        String(decoding: (try? JSONEncoder().encode(tabMark)) ?? Data("\"\"".utf8), as: UTF8.self)
    }

    /// Asked in the agent's own world: the page's world answers whatever the
    /// page makes it answer — a message too big for the connection included
    /// (review of 3.1, P1-3). Between two documents there is no world to ask
    /// yet, and that is still loading; a lost connection is not. A document
    /// that is `interactive` is usable: a picture or a tracker still coming
    /// does not keep it loading (Codex review of I-07, P2-4).
    func isLoading(_ tab: BrowserTab) async throws -> Bool {
        do {
            return try await run("document.readyState", in: tab) == "loading"
        } catch BrowserBridgeError.scriptFailed {
            return true
        }
    }

    /// Runs `javascript` in the agent's isolated world of the tab's page —
    /// or of its frame's document, for a tab in a frame (ITER-076 I-09). A
    /// frame that is gone is a script that failed, never the tab lost.
    func run(_ javascript: String, in tab: BrowserTab) async throws -> String {
        do {
            do {
                return try await evaluate(javascript, world: try await world(for: tab))
            } catch BrowserBridgeError.scriptFailed(code: Self.staleWorld) {
                // The tab holds another document since: it has a new world.
                worlds[tab.frame ?? tab.tabID] = nil
                return try await evaluate(javascript, world: try await world(for: tab))
            }
        } catch BrowserBridgeError.tabNotFound where tab.frame != nil {
            throw BrowserBridgeError.scriptFailed(code: Self.frameGone)
        }
    }

    /// The evaluation awaits a promise already: as `run`.
    func runAwaiting(_ javascript: String, in tab: BrowserTab) async throws -> String {
        try await run(javascript, in: tab)
    }

    /// Runs `javascript` in the page's own world, where the page's scripts
    /// rule: tests use it to show what a page did there. The agent never
    /// reads the page through it.
    func runInPage(_ javascript: String, in tab: BrowserTab) async throws -> String {
        try await evaluate(javascript, world: (id: nil, session: tab.tabID))
    }

    /// Closes the tab and returns once it is gone: Chrome closes a target a
    /// moment after it says so, and a tab reported closed must be closed. A
    /// close is carried out whatever happens to the caller — after Stop too.
    /// A close that fails leaves the tab guarded until it is gone (`listen`).
    func closeTab(_ tab: BrowserTab) async throws {
        try await Task { try await self.close(tab) }.value
    }

    private func close(_ tab: BrowserTab) async throws {
        sweeps.removeValue(forKey: tab.windowID)?.cancel()
        worlds[tab.tabID] = nil
        for frame in watches[tab.windowID]?.hosts.keys ?? [:].keys { worlds[frame] = nil }
        // First the windows it opened: once it is gone, Chrome no longer says
        // whose they were.
        await closeWindows(openedBy: tab)
        do {
            // A close Chrome said it carried out and did not is asked for
            // again, `closeAttempts` times in all (Claude review c7 of I-09,
            // #10).
            for _ in 0..<Self.closeAttempts {
                do {
                    _ = try await send("Target.closeTarget", ["targetId": .string(tab.windowID)])
                } catch BrowserBridgeError.tabNotFound {
                    // Gone already: the list says so.
                }
                let deadline = ContinuousClock.now + Self.closeLimit
                while ContinuousClock.now < deadline {
                    let targets = try await send("Target.getTargets", [:])
                    let open = (targets["targetInfos"]?.array ?? []).contains { $0["targetId"]?.string == tab.windowID }
                    if !open {
                        // Gone: nothing of it is watched any more, nor listed
                        // to close (stage 9d). Until then it is.
                        watches.removeValue(forKey: tab.windowID)?.listener?.cancel()
                        tabs?.closed(tab.windowID)
                        return
                    }
                    try await Task.sleep(for: .milliseconds(50))
                }
            }
            throw BrowserBridgeError.timedOut
        } catch {
            // However the close failed — Chrome said it closed the tab and
            // did not, did not answer in time, or answered with an error, to
            // the close or to its list of tabs — a tab not known to be gone
            // is the user's from now on (Codex review 2 of I-09, P2-4).
            if let watch = watches[tab.windowID] { await letGo(watch) }
            throw error
        }
    }

    /// How many times a tab is asked to close, and how long it may take to
    /// leave Chrome's list after each.
    static let closeAttempts = 3
    static let closeLimit: Duration = .seconds(1)

    /// The agent's tabs left open — the app crashed, or a close never got
    /// through, the Mac asleep — are closed as the next errand connects
    /// (ITER-076 stage 9d, № 21, № 23). Only a tab the agent made that still
    /// shows its mark: one the user took over and moved on in is theirs, and
    /// stays. The tab alone, never a window it opened — after a crash that
    /// may be the user's. Each one closed, gone or theirs is let go; one whose
    /// close failed stays listed for the next connection.
    func closeStrayTabs() async {
        guard let tabs, !tabs.open.isEmpty, let targets = try? await send("Target.getTargets", [:]) else { return }
        let shown = targets["targetInfos"]?.array ?? []
        for id in tabs.open {
            let marked = shown.contains {
                $0["targetId"]?.string == id && $0["title"]?.string?.hasPrefix(Self.tabMark) == true
            }
            if marked {
                do {
                    _ = try await send("Target.closeTarget", ["targetId": .string(id)])
                } catch BrowserBridgeError.tabNotFound {
                    // Gone already.
                } catch {
                    continue
                }
            }
            tabs.closed(id)
        }
    }

    /// A tab that would not close — or whose close failed in any way — is the
    /// user's from now on (Claude review c7 of I-09, #10; Codex review 2 of
    /// I-09, P2-4): its dialogs and its file pickers — of its page and of
    /// each frame in it, then and after (`watchFrame`) — are theirs, none
    /// answered, none taken — while its requests are still let on or refused
    /// as ever, so none waits forever and none reaches the user's network
    /// (`listen`).
    private func letGo(_ watch: TabWatch) async {
        watch.drives = false
        for session in [watch.page] + watch.frames.map(\.session) {
            _ = try? await send("Page.setInterceptFileChooserDialog", ["enabled": false], session: session)
        }
    }

    /// A left click at a point: press and release, as jev-ultrafast's
    /// `browser.py` sends it (no move first). Stop never splits it: a click
    /// not begun is not begun, and a press is always followed by its release.
    func click(x: Double, y: Double, in tab: BrowserTab) async throws {
        try Task.checkCancellation()
        try await finished {
            for type in ["mousePressed", "mouseReleased"] {
                _ = try await self.send("Input.dispatchMouseEvent",
                                        ["type": .string(type), "x": .number(x), "y": .number(y), "button": "left",
                                         "clickCount": 1], session: tab.tabID)
            }
            await self.closeWindows(openedBy: tab)
        }
    }

    /// Runs an input to its end whatever happens to the caller: a press is
    /// always followed by its release, a key down by its key up. A caller
    /// that stops is not held up by a page slow to take the input — it gets
    /// back at once, and the input finishes alone (review of 3.1, round 2).
    /// Begun, the input goes out: a caller that stops gets `.interrupted`,
    /// never a `CancellationError`, which says nothing went out (ITER-076
    /// I-05).
    private func finished(_ input: @escaping @MainActor () async throws -> Void) async throws {
        let unit = Task { @MainActor () -> Result<Void, BrowserBridgeError> in
            do {
                try await input()
                return .success(())
            } catch let error as BrowserBridgeError {
                return .failure(error)
            } catch {
                return .failure(.connectionLost)
            }
        }
        guard let result = await Deadline.run(within: Self.inputLimit, { await unit.value }) else {
            throw Task.isCancelled ? BrowserBridgeError.interrupted : BrowserBridgeError.timedOut
        }
        try result.get()
    }

    /// Longer than any input takes: its calls, each at its own limit.
    private static let inputLimit: Duration = .seconds(90)

    /// Every quarter of a second while the tab is open, the windows its page
    /// opened are closed: a page may open one a while after the agent's click
    /// (review of 3.1, round 2). Since ITER-076 I-10 a document the guard
    /// answered opens none (`sandbox`); one it never saw answered — a service
    /// worker's — still could.
    private func sweep(_ tab: BrowserTab) {
        sweeps[tab.windowID] = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled, let self else { return }
                await self.closeWindows(openedBy: tab)
            }
        }
    }

    /// A person's click or keystroke lets a page open a window: a tab the
    /// agent never asked for, which the browser may put in front of the
    /// user's own, and which stays when the agent's tab closes (review of
    /// 3.1, P1-1). Every page the agent's tab opened is closed; the agent
    /// works in its own tab only. But for the user's (ITER-076 stage 3): none
    /// while they have the tab, nor one it had open when they gave it back.
    private func closeWindows(openedBy tab: BrowserTab) async {
        let watch = watches[tab.windowID]
        guard watch?.lent != true, let targets = try? await send("Target.getTargets", [:]) else { return }
        for id in Self.windows(in: targets, openedBy: tab.windowID) where watch?.usersWindows.contains(id) != true {
            _ = try? await send("Target.closeTarget", ["targetId": .string(id)])
        }
    }

    /// The pages a target list says `opener` opened, by target id.
    private static func windows(in targets: CDPValue, openedBy opener: String) -> [String] {
        (targets["targetInfos"]?.array ?? []).filter {
            $0["type"]?.string == "page" && $0["openerId"]?.string == opener
        }.compactMap { $0["targetId"]?.string }
    }

    // MARK: - Private

    /// The script threw in the page.
    private static let scriptThrew = -3
    /// The script's result was not text.
    private static let notText = -4
    /// The world's document is gone.
    private static let staleWorld = -5
    /// The frame is gone, or not known to the tab (ITER-076 I-09).
    private static let frameGone = -6
    /// How long the report of a world just made may take to arrive.
    private static let worldReportLimit: Duration = .seconds(2)
    /// How long a frame in a process of its own may take to say what it
    /// holds: a frame answers at once, one that went never does.
    private static let frameTreeLimit: Duration = .seconds(2)

    /// The agent's isolated world in the tab's current document, by its
    /// system-wide id. Chrome numbers contexts per renderer process: after a
    /// move to another site the tab has a new process, where the number an
    /// old world had can name a frame's own world, written by the page — and
    /// a script sent there runs without an error (review of 3.1, P0-1). A
    /// world addressed by its unique id is only ever that world; once its
    /// document is gone, Chrome says so. The unique id comes only with the
    /// Runtime domain's report of a new world, so Runtime is on just while
    /// the world is made.
    private func world(for tab: BrowserTab) async throws -> (id: String?, session: String) {
        let key = tab.frame ?? tab.tabID
        if let known = worlds[key] { return (known.id, known.session) }
        let frameID: String, session: String
        if let frame = tab.frame {
            // A frame is reached by the session its document lives in, as the
            // tab's frames were last listed.
            guard let host = watches[tab.windowID]?.hosts[frame] else {
                throw BrowserBridgeError.scriptFailed(code: Self.frameGone)
            }
            (frameID, session) = (frame, host)
        } else {
            let tree = try await send("Page.getFrameTree", [:], session: tab.tabID)
            guard let main = tree["frameTree"]?["frame"]?["id"]?.string else {
                throw BrowserBridgeError.scriptFailed(code: -1)
            }
            (frameID, session) = (main, tab.tabID)
        }
        let events = await connection.events()
        // Turned on, the Runtime domain first sends all the page's console it
        // kept — 4 MB from a chatty page in a measure. Nothing of it is wanted.
        _ = try await send("Runtime.discardConsoleEntries", [:], session: session)
        _ = try await send("Runtime.enable", [:], session: session)
        let unique: String?
        do {
            let created = try await send("Page.createIsolatedWorld",
                                         ["frameId": .string(frameID), "worldName": .string(Self.worldName)],
                                         session: session)
            let context = created["executionContextId"]?.int
            let name = Self.worldName
            unique = await Deadline.run(within: Self.worldReportLimit) { () -> String? in
                for await event in events
                where event.method == "Runtime.executionContextCreated" && event.sessionID == session {
                    let world = event.params["context"]
                    if world?["id"]?.int == context, world?["name"]?.string == name,
                       world?["auxData"]?["frameId"]?.string == frameID {
                        return world?["uniqueId"]?.string
                    }
                }
                return nil
            } ?? nil
        } catch {
            _ = try? await send("Runtime.disable", [:], session: session)
            throw error
        }
        _ = try? await send("Runtime.disable", [:], session: session)
        guard let unique else { throw BrowserBridgeError.scriptFailed(code: Self.staleWorld) }
        worlds[key] = (unique, session)
        return (unique, session)
    }

    /// Evaluates `javascript` in `world` — by its system-wide id, on the
    /// session it is reached by; with no id, in the page's own world.
    private func evaluate(_ javascript: String, world: (id: String?, session: String)) async throws -> String {
        var params: [String: CDPValue] = ["expression": .string(javascript), "returnByValue": true,
                                          "awaitPromise": true]
        if let id = world.id { params["uniqueContextId"] = .string(id) }
        let reply = try await send("Runtime.evaluate", .object(params), session: world.session,
                                   timeout: .seconds(DiaScript.defaultTimeoutSeconds))
        if reply["exceptionDetails"] != nil { throw BrowserBridgeError.scriptFailed(code: Self.scriptThrew) }
        guard let text = reply["result"]?["value"]?.string else { throw BrowserBridgeError.scriptFailed(code: Self.notText) }
        return text
    }

    /// One protocol call, its failures told in the bridge's own terms — its
    /// parameters given, or made `atTheWire` as it is handed to the socket.
    private func send(_ method: String, _ params: CDPValue = [:], session: String? = nil,
                      timeout: Duration = .seconds(30),
                      atTheWire: (@Sendable () -> CDPValue)? = nil) async throws -> CDPValue {
        do {
            return try await connection.send(method, params: params, sessionID: session, timeout: timeout,
                                             atTheWire: atTheWire)
        } catch let error as CDPError {
            switch error {
            case .timedOut:
                throw BrowserBridgeError.timedOut
            case .protocolError(let code, let message):
                // A closed tab: its target or its session is gone.
                if message.contains("No target with given id") || message.contains("Session with given id not found") {
                    throw BrowserBridgeError.tabNotFound
                }
                // A world whose document is gone (`world(for:)`): Chrome says
                // so of another renderer's id, and — after a move within the
                // same renderer, a page of the same site — of a context that is
                // no more (ITER-076 I-07).
                if message.contains("uniqueContextId not found")
                    || message.contains("Cannot find context with specified id") {
                    throw BrowserBridgeError.scriptFailed(code: Self.staleWorld)
                }
                throw BrowserBridgeError.scriptFailed(code: code)
            case .cancelled:
                // Nothing went out.
                throw CancellationError()
            case .abandoned:
                // It went out: the page may act on it.
                throw BrowserBridgeError.interrupted
            case .notOpen, .unreachable, .closed, .allowTimedOut:
                throw BrowserBridgeError.connectionLost
            }
        }
    }
}
