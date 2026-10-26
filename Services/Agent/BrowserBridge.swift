import Foundation

/// A tab the agent opened (ITER-074 §5). The ids are the browser's own; the
/// agent only ever acts in tabs it holds one of these for (§7.2).
struct BrowserTab: Hashable, Sendable {
    let windowID: String
    let tabID: String
    /// One frame of the tab's page, by the browser's id for it: a script
    /// given this tab runs in that frame's document (ITER-076 I-09). Nil: the
    /// page itself.
    var frame: String? = nil

    /// The same tab, in one of its frames — or, given nil, its page.
    func inFrame(_ frame: String?) -> BrowserTab {
        BrowserTab(windowID: windowID, tabID: tabID, frame: frame)
    }
}

/// A page's own dialog (ITER-076 I-09).
enum PageDialog: String, Codable, CaseIterable, Sendable {
    case alert, confirm, prompt
    /// "Leave the page?" as it is left.
    case beforeunload
}

/// What a tab did on its own, which the agent's run keeps (ITER-076 I-09):
/// by kinds alone, never a dialog's words or an address.
enum BrowserEvent: Equatable, Sendable {
    /// A page's dialog, answered: OK — or Leave — or not.
    case dialog(PageDialog, accepted: Bool)
    /// A download the tab began, refused before anything was saved.
    case downloadRefused
    /// A document the tab asked for at an address the agent never opens,
    /// refused before the request went out.
    case addressRefused
    /// A confirm, a prompt or a "Leave the page?" whose own words name a
    /// payment or a grant — what it is, by kind — answered Cancel whatever
    /// the Yes (review of I-09, F4). Its words are read where it opens and
    /// kept nowhere.
    case dialogNamed(ErrandHandover.Kind)
    /// A document the tab asked for while its sends were held
    /// (`BrowserBridge.holdSends`) — a form a page's own script sent — refused
    /// before its request went out (ITER-076 stage 7, review round 1, C2).
    /// What a page's script sends by fetch, XHR or a beacon then is refused
    /// with no word: the page's own send fails, and nothing else changes
    /// (review round 2, R2-1).
    case sendHeld
}

/// The act a step has the user's Yes for, as a page's own dialog is bound to
/// it (Codex review 1 of I-09, P1-3): the words of the control the user
/// approved — its name, its text, and its form's submit label only when the
/// act sends that form (Claude review c8 of I-09, #12) — and the document it
/// runs in, whose dialogs alone answer to it (#16). It reaches the bridge
/// with the Yes and leaves with it, in memory only.
struct ApprovedAct: Equatable, Sendable {
    let words: [String]
    /// The document the act runs in, by the browser's id for its frame; nil
    /// for the page itself.
    let frame: String?

    init(words: [String], frame: String? = nil) {
        self.words = words
        self.frame = frame
    }

    /// The act `action` is: the words of the control acted on — none for an
    /// act on no control, a planned search — its name and text, and the
    /// form's submit label only for a click that sends the form, never typed
    /// text; in the document it runs in — an open runs in the page.
    init(_ action: AgentAction) {
        let target = action.target
        let sendsForm = action.operation == .click && target?.submits != false
        words = [target?.name, target?.text, sendsForm ? target?.formSubmitLabel : nil].compactMap { $0 }
        frame = action.operation == .open ? nil : target?.frame
    }
}

/// One frame of a tab's page (ITER-076 I-09): the tab in that frame, and who
/// the frame is across looks — the same after a reload that gives it a new
/// id in the browser (review of I-09, F5), and whichever frames answered
/// (Codex review 1 of I-09, P2-1): the frame that holds it and its origin,
/// never its place among its siblings. Frames of one origin side by side
/// are one to it: controls that differ by nothing but which of them holds
/// them are twins (Claude review c7 of I-09, #4).
struct BrowserFrame: Hashable, Sendable {
    let tab: BrowserTab
    let identity: String
}

/// A tab's own history (ITER-076 I-10): its entries, oldest first, and the
/// one it shows.
struct BrowserHistory: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        /// The browser's id for it: what going back to it names.
        let id: Int
        /// Where it is now — a page may have rewritten it on its own origin.
        let url: String
        /// It was made by sending a form: going back to it may ask for the
        /// form's answer again.
        let sentForm: Bool
    }

    let entries: [Entry]
    /// Where `entries` holds the entry the tab shows.
    let current: Int

    /// A tab with no history of its own.
    static let none = BrowserHistory(entries: [], current: 0)
}

/// The frames of a tab's page as one listing found them (ITER-076 I-09):
/// each one it could list, and how many it could not — a frame in a process
/// of its own whose tree did not answer in time, and every frame inside such
/// a one — never left out silently (Codex review 1 of I-09, P2-2).
struct FrameListing: Equatable, Sendable {
    var frames: [BrowserFrame] = []
    /// The frames left out, counted as frames, not as the processes that
    /// hold them (Codex review 2 of I-09, P2-5): each frame in a process of
    /// its own left out, with every frame its process held when it last
    /// said what it holds — or one, when it never did.
    var unread = 0
    /// How many of the frames left out never said what their process holds:
    /// what each holds beside itself is not known.
    var unknown = 0
}

/// What can go wrong between the agent and a browser.
enum BrowserBridgeError: Error, Equatable {
    /// Only http(s) URLs with a host are ever opened (§6.2).
    case notOpenable(URL)
    /// The tab is gone — closed by the user, or never ours.
    case tabNotFound
    /// The page's script threw, or the browser refused to run it.
    case scriptFailed(code: Int)
    /// A wait ran out of time.
    case timedOut
    /// The connection to the browser is gone: nothing more reaches it
    /// (ITER-076 I-05).
    case connectionLost
    /// The caller stopped once the call had gone out (ITER-076 I-05): the
    /// page may have acted on it. A call stopped before it went out throws
    /// `CancellationError` instead: nothing reached the page.
    case interrupted
}

/// The agent's hands in a browser (ITER-074 §5). In the app this is Dia over
/// Apple Events; in tests it is a `WKWebView` per tab (§12.1). Scripts the
/// agent runs return text, so every bridge speaks the same language. Every
/// call ends by its own deadline — an Apple Event within 5 s (§8) — so the
/// loop never waits on a bridge without one.
@MainActor
protocol BrowserBridge {
    /// Opens `url` in a new tab the agent owns. Refuses anything
    /// `DiaScript.isOpenable` refuses.
    func openTab(_ url: URL) async throws -> BrowserTab
    /// Whether the tab is still loading.
    func isLoading(_ tab: BrowserTab) async throws -> Bool
    /// Runs `javascript` in the tab and returns its result as text.
    func run(_ javascript: String, in tab: BrowserTab) async throws -> String
    /// Runs `javascript`, an expression whose value is a promise, and returns
    /// what it resolves to, as text: a wait the page keeps itself — the
    /// settle's (ITER-076 I-07).
    func runAwaiting(_ javascript: String, in tab: BrowserTab) async throws -> String
    /// Closes a tab the agent opened.
    func closeTab(_ tab: BrowserTab) async throws
    /// The frames of the tab's page, each as the tab in that frame, with who
    /// the frame is across looks (ITER-076 I-09; review of I-09, F5), and how
    /// many it has that could not be listed (Codex review 1 of I-09, P2-2).
    func frames(of tab: BrowserTab) async throws -> FrameListing
    /// What the tab did on its own since the last call, oldest first — and
    /// no longer kept (ITER-076 I-09).
    func events(in tab: BrowserTab) -> [BrowserEvent]
    /// The act the step now acting in the tab has the user's Yes for, or nil
    /// (ITER-076 I-09; Codex review 1 of I-09, P1-3, P1-4): a confirm it
    /// brings is answered OK once only when bound to that act, a "Leave the
    /// page?" Leave once; anything else is Cancel, or Stay. Nil takes the Yes
    /// back at once: an answer not yet sent goes out as Cancel.
    func approve(_ act: ApprovedAct?, in tab: BrowserTab)
    /// The tab's own history (ITER-076 I-10).
    func history(of tab: BrowserTab) async throws -> BrowserHistory
    /// Goes to the entry of the tab's own history whose id is `entry`, as a
    /// person's Back does: a page the browser kept comes back as it was
    /// (ITER-076 I-10).
    func goBack(to entry: Int, in tab: BrowserTab) async throws
    /// The addresses of the windows the tab's pages asked to open on a
    /// person's input since the last call, oldest first — and no longer kept
    /// (ITER-076 I-10). None of them was opened.
    func windowsOpened(in tab: BrowserTab) -> [String]
    /// The tab is the user's while the errand waits for their part (ITER-076
    /// stage 3): no window it opens is closed meanwhile, and its page's
    /// dialogs and file pickers are theirs.
    func lend(_ tab: BrowserTab) async
    /// The tab is the agent's again: the windows it has open now are the
    /// user's, and are never closed.
    func reclaim(_ tab: BrowserTab) async
    /// Brings the tab, and the browser, in front of the user (ITER-076 stage
    /// 3, Show tab).
    func show(_ tab: BrowserTab) async
    /// While `held`, nothing the tab sends goes out (ITER-076 stage 7, review
    /// rounds 1 and 2, C2, R2-1): every document its page asks for — a form
    /// its own script sends, a navigation it starts — and every one a frame
    /// of it is sent with a body is refused before its request goes out, and
    /// noted as `sendHeld`; every other request of the tab but a GET — a
    /// fetch, an XHR, a beacon — is refused too. What is read by GET still
    /// comes: a frame's page, an image. The hold is in place once this
    /// returns; given false, the tab asks as ever. True when this bridge
    /// holds them: one that cannot fills no form.
    func holdSends(_ held: Bool, in tab: BrowserTab) async -> Bool
    /// While the tab's sends are held, the agent's own act goes to
    /// `address` — an open, Back, a link, a window's address: its page goes
    /// there by GET, and on along the redirects it is answered with; the
    /// rest stays held, what the page it leaves sends as it goes too (review
    /// round 2, R2-2).
    func letNavigate(to address: String, in tab: BrowserTab)
}

/// A bridge that has no frames to read, whose tabs do nothing on their own,
/// keep no history, open no window, are never shown — and cannot hold what
/// they send, so no form is filled in them.
extension BrowserBridge {
    func frames(of tab: BrowserTab) async throws -> FrameListing { FrameListing() }
    func events(in tab: BrowserTab) -> [BrowserEvent] { [] }
    func approve(_ act: ApprovedAct?, in tab: BrowserTab) {}
    func history(of tab: BrowserTab) async throws -> BrowserHistory { .none }
    func goBack(to entry: Int, in tab: BrowserTab) async throws { throw BrowserBridgeError.scriptFailed(code: -1) }
    func windowsOpened(in tab: BrowserTab) -> [String] { [] }
    func lend(_ tab: BrowserTab) async {}
    func reclaim(_ tab: BrowserTab) async {}
    func show(_ tab: BrowserTab) async {}
    func holdSends(_ held: Bool, in tab: BrowserTab) async -> Bool { false }
    func letNavigate(to address: String, in tab: BrowserTab) {}
}

/// A bridge whose input is a person's: trusted mouse events that a page cannot
/// tell from the user's own (ITER-076 3.1). Some sites ignore the clicks a
/// script makes; these are not scripts. Text goes in through the page's own
/// editing, which is trusted input too, in one task with its field's check
/// (`ActionScript.typeText`; Codex review of I-07, round 2, P2-1).
@MainActor
protocol TrustedInputBridge: BrowserBridge {
    /// Presses and releases the left button at a point in the viewport's CSS
    /// pixels — one an `ActionScript.aim` hit-tested.
    func click(x: Double, y: Double, in tab: BrowserTab) async throws
    /// Where a point of the viewport of `tab`'s frame lies in the tab's own
    /// viewport, once every document on the way has drawn — nil when a click
    /// there would not reach that frame: a frame outside it covers it
    /// (ITER-076 I-09), or it is drawn squeezed (review of I-09, F7). The
    /// page's own point is itself.
    func point(x: Double, y: Double, in tab: BrowserTab) async throws -> (x: Double, y: Double)?
}
