import AppKit
import Foundation
import ScreenCaptureKit
import SwiftData

/// Captures the active window and extracts text via Apple Vision OCR.
/// All processing is on-device — no data leaves the Mac.
@MainActor
final class ScreenContextService: ObservableObject {
    @Published var isActive = false
    @Published var lastContext: ScreenContextSnapshot?

    /// Recent contexts kept in memory for the advice system.
    private(set) var recentContexts: [ScreenContextSnapshot] = []
    private let maxRecentContexts = 20

    /// ITER-053.1 — purge fence for the capture path itself: a capture
    /// suspended in ScreenCaptureKit/OCR when the user hits «Delete screen
    /// history» must not resume and persist pre-delete OCR (Codex review).
    private var captureEpoch = 0

    /// ITER-053.1 — «Delete screen history» must also wipe the in-session
    /// buffers, or AdviceService keeps feeding "deleted" OCR text into LLM
    /// prompts until it ages out of the rolling window (Codex review).
    /// Bumping the epoch also discards any capture currently in flight.
    func clearInMemory() {
        captureEpoch += 1
        recentContexts.removeAll()
        lastContext = nil
        // ITER-069 — a purge kills the cached frame with everything else.
        frameCache.invalidateAll()
        // ITER-064A.7 lesson, carried over: after a purge no window is "already
        // in history" — the coordinator forgets, so the screen the user is
        // sitting on stays capturable.
        visitCoordinator.invalidateAll()
        lastCommittedToken = 0
        // Codex P0 — a context queued across the purge boundary could still
        // pass the "is this the accepted screen" check and send deleted OCR
        // to analysis. After a purge there IS no accepted screen.
        lastAcceptedContextID = nil
        recentVisitByContext.removeAll()
        recentVisitOrder.removeAll()
    }

    private var monitorTask: Task<Void, Never>?

    /// ITER-065 — the visit coordinator decides what counts as a change.
    /// ITER-064A.3's rule carries over: state advances only on an accepted
    /// frame (commit is gated by consumesWindowTurn), so a failed capture
    /// stays eligible for the next poll. Sightings carry windowID/displayID
    /// = nil ALWAYS: the nil/non-nil asymmetry in window matching would
    /// otherwise open a visit every tick.
    private var visitCoordinator = ContextVisitCoordinator()
    private let visitClock = ContinuousClock()
    /// Interim in-process change token (FNV-1a of the accepted OCR) until the
    /// content-fingerprint iteration. Never comparable across launches.
    private var lastCommittedToken = 0
    /// Throttle for durable keep-alive touches on quiet ticks — retention
    /// must not delete a visit the user is still sitting in (Codex).
    private var lastQuietDurableTouch: Date?

    /// Deterministic across the process, unlike `hashValue` (per-process
    /// seeded): FNV-1a over UTF-8.
    static func stableToken(_ text: String) -> Int {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return Int(bitPattern: UInt(truncatingIfNeeded: hash))
    }
    private var modelContainer: ModelContainer?

    /// Instant-detection observer for `NSWorkspace.didActivateApplicationNotification`.
    /// Fires within ~100 ms of any app activation (Zoom open, Meet tab focus,
    /// FaceTime answer) — bypasses the 30 s polling loop so call recording
    /// can start before the user has time to switch focus elsewhere.
    /// Notion's "Hey, want to record this call?" works because they use this
    /// same hook; without it MetaWhisp can miss the call entirely if the
    /// user moves to Slack 5 s after joining.
    private var instantAppActivationObserver: NSObjectProtocol?

    /// Fires on video-call state change detected during window polling.
    /// Argument: call display name ("Google Meet", "Zoom", …) when a call starts,
    /// or `nil` when the previously-detected call ends (window switched / closed).
    /// Fires only on transitions, so the handler doesn't need its own debounce.
    ///
    /// Implements spec://iterations/ITER-002-call-detection
    var onCallContext: ((String?) -> Void)?
    private var lastCallContext: String?

    /// Apps already reported as "not captured because the allowlist is empty",
    /// so the log gets one line per app rather than one per poll.
    private var loggedSuppressedApps: Set<String> = []

    /// ITER-065.6 — why the last attempt to read the screen produced what it
    /// did. Carries no screen content, so it is safe for health reporting.
    private(set) var lastCaptureOutcome: ScreenCaptureOutcome = .captured(ocrCharacters: 0)

    /// ID of the most recently accepted screen row.
    private(set) var lastAcceptedContextID: UUID?

    /// Visit-wiring step 5 — which visit each recent screen row belongs to,
    /// so an item born from a context can carry its visit without every
    /// consumer's signature changing. Bounded; consumers read immediately
    /// after persist.
    private var recentVisitByContext: [UUID: (id: UUID, generation: Int)] = [:]
    private var recentVisitOrder: [UUID] = []

    func visitIdentity(for contextID: UUID) -> (id: UUID, generation: Int)? {
        recentVisitByContext[contextID]
    }

    /// FIFO eviction — a burst clear was erasing identities that in-flight
    /// model runs still needed (Codex).
    private func rememberVisit(_ identity: (id: UUID, generation: Int),
                               for contextID: UUID) {
        if recentVisitByContext[contextID] == nil {
            recentVisitOrder.append(contextID)
            if recentVisitOrder.count > 64 {
                recentVisitByContext.removeValue(forKey: recentVisitOrder.removeFirst())
            }
        }
        recentVisitByContext[contextID] = identity
    }

    /// ITER-069 — the one frame vision may look at. Populated only under the
    /// separate visual consent; capacity one; memory only.
    let frameCache = ScreenAgentFrameCache()

    /// Fires after each newly-persisted ScreenContext (one per captured window change).
    /// Used by `RealtimeScreenReactor` (ITER-006) to do per-window LLM task checks with its
    /// own debounce/rate-limit. Hook layered on top of the polling loop — no extra timers.
    ///
    /// Implements spec://iterations/ITER-006-realtime-screen-reaction#scope.2
    var onContextPersisted: ((ScreenContext) -> Void)?

    /// Set the model container for SwiftData persistence.
    func configure(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
        // Visit-wiring step 4 — a crash or kill leaves the last visit open
        // forever; nothing will come back to close it, so startup does.
        let ctx = ModelContext(modelContainer)
        Self.reconcileOpenVisits(in: ctx)
    }

    /// A quiet hour still counts as being there: bump the open visit's
    /// durable lastObservedAt at most once an hour, or a dashboard the user
    /// stares at for eight days gets retention-deleted as eight days old.
    private func touchDurableVisitIfStale() {
        let now = Date()
        if let last = lastQuietDurableTouch, now.timeIntervalSince(last) < 3600 { return }
        guard let container = modelContainer,
              let visitID = visitCoordinator.current?.id else { return }
        let ctx = ModelContext(container)
        var descriptor = FetchDescriptor<ContextVisitRecord>(
            predicate: #Predicate { $0.id == visitID })
        descriptor.fetchLimit = 1
        guard let row = (try? ctx.fetch(descriptor))?.first else { return }
        row.lastObservedAt = now
        // The throttle advances only on a write that landed — advancing first
        // meant one failed save silenced the next hour of retries (Codex).
        do {
            try ctx.save()
            lastQuietDurableTouch = now
        } catch {
            NSLog("[ScreenContext] visit keep-alive failed: %@", error.localizedDescription)
        }
    }

    /// Close visit rows a dead process left open. Reason code only.
    static func reconcileOpenVisits(in ctx: ModelContext, now: Date = Date()) {
        let openPred = #Predicate<ContextVisitRecord> { $0.endedAt == nil }
        guard let open = try? ctx.fetch(FetchDescriptor<ContextVisitRecord>(predicate: openPred)),
              !open.isEmpty else { return }
        for row in open {
            // Close at the last REAL observation — closing at relaunch time
            // fabricated hours of activity across the downtime (Codex).
            row.endedAt = row.lastObservedAt
            row.invalidationReason = "startup_reconcile"
        }
        try? ctx.save()
    }

    /// Apply one committed-to-be proposal to the durable visit table, inside
    /// the same context (and save) that persists the screen row it describes.
    /// `.opened` closes whatever was open — same window again means the gap
    /// expired, a different one means the user switched.
    static func upsertVisitRecord(
        proposal: ContextVisitCoordinator.Proposal,
        currentVisit: ContextVisit? = nil,
        acceptedContextID: UUID,
        captureState: String,
        token: Int,
        in ctx: ModelContext,
        now: Date = Date()
    ) {
        switch proposal {
        case .unchanged:
            // The mark can accept what the coordinator calls unchanged (a
            // spinner glyph in the title, identical content). The row still
            // belongs to the ONGOING visit — it must not go unstamped (Codex).
            guard let currentVisit else { return }
            let visitID = currentVisit.id
            var descriptor = FetchDescriptor<ContextVisitRecord>(
                predicate: #Predicate { $0.id == visitID })
            descriptor.fetchLimit = 1
            guard let row = (try? ctx.fetch(descriptor))?.first else { return }
            row.lastObservedAt = now
            row.captureState = captureState
            row.latestScreenContextID = acceptedContextID
            row.appendFrameID(acceptedContextID)
            return
        case .opened(let visit):
            let openPred = #Predicate<ContextVisitRecord> { $0.endedAt == nil }
            if let open = try? ctx.fetch(FetchDescriptor<ContextVisitRecord>(predicate: openPred)) {
                for row in open {
                    let sameWindow = row.bundleID == visit.bundleID
                        && row.normalizedTitle == visit.normalizedTitle
                    // A visit ends when it was last SEEN, never at the moment
                    // the next one opens: stop at noon, come back at two, and
                    // closing at "now" hands the earlier app two hours it was
                    // never observed for (Codex). The day report reads this
                    // field, so the lie would reach the user.
                    row.endedAt = sameWindow ? row.lastObservedAt : now
                    row.invalidationReason = sameWindow ? "gap_expired" : "context_switch"
                }
            }
            let record = ContextVisitRecord(
                id: visit.id, generation: visit.generation,
                bundleID: visit.bundleID, appName: visit.appName,
                rawTitle: visit.rawTitle, normalizedTitle: visit.normalizedTitle,
                startedAt: visit.startedAt, captureState: captureState)
            record.lastObservedAt = now
            record.latestScreenContextID = acceptedContextID
            record.latestContentHash = token
            record.appendFrameID(acceptedContextID)
            ctx.insert(record)
        case .changed(let visit):
            let visitID = visit.id
            var descriptor = FetchDescriptor<ContextVisitRecord>(
                predicate: #Predicate { $0.id == visitID })
            descriptor.fetchLimit = 1
            guard let row = (try? ctx.fetch(descriptor))?.first else {
                // The row was pruned or purged mid-visit — recreate rather
                // than lose the remainder of the visit.
                let record = ContextVisitRecord(
                    id: visit.id, generation: visit.generation,
                    bundleID: visit.bundleID, appName: visit.appName,
                    rawTitle: visit.rawTitle, normalizedTitle: visit.normalizedTitle,
                    startedAt: visit.startedAt, captureState: captureState)
                record.lastObservedAt = now
                record.latestScreenContextID = acceptedContextID
                record.latestContentHash = token
                record.appendFrameID(acceptedContextID)
                ctx.insert(record)
                return
            }
            row.generation = visit.generation
            row.rawTitle = visit.rawTitle
            row.normalizedTitle = visit.normalizedTitle
            row.lastObservedAt = now
            row.captureState = captureState
            row.latestScreenContextID = acceptedContextID
            row.latestContentHash = token
            row.appendFrameID(acceptedContextID)
        }
    }

    /// In-memory snapshot (not persisted — used for advice generation).
    struct ScreenContextSnapshot {
        let timestamp: Date
        let appName: String
        let windowTitle: String
        let ocrText: String
        /// ITER-065 wiring, step 1 — the identity the visit coordinator needs.
        /// Computed at capture time and carried WITH the snapshot: the user
        /// can switch windows during the OCR awaits, and identity read after
        /// the await describes a different window than the one captured.
        let bundleID: String
        /// The exact SCWindow that was read, when one was chosen. Provenance
        /// only — never fed back into coordinator sightings (nil/non-nil
        /// asymmetry in window matching would open a new visit every tick).
        let windowID: Int?
    }

    /// Apps that should never be captured (privacy-sensitive).
    private let defaultBlacklist: Set<String> = [
        "com.apple.Passwords",
        "com.apple.keychainaccess",
        "1Password",
        "com.agilebits.onepassword7",
        "com.bitwarden.desktop",
    ]

    /// Start monitoring screen context (captures on window change).
    /// ITER-064A.5 — no policy parameters. The loop resolves the user's current
    /// blacklist/allowlist on every tick via `currentPolicy()`, so a Settings
    /// change takes effect on the next poll instead of at the next relaunch.
    func startMonitoring(interval: TimeInterval = 30) {
        guard !isActive else { return }
        // ITER-049 A2 — a degraded (temporary in-memory) session is read-only; don't
        // capture OCR into the empty store or stage candidates from it. Covers every
        // start path (launch, Settings toggle, applicationDidBecomeActive re-arm).
        guard StoreHealthSignal.shared.isHealthy else { return }

        // ITER-064A.6 — claim the slot here, synchronously on the main actor,
        // not inside the task. `isActive` used to be set only after the TCC
        // preflight await, so two starts arriving during that window each got
        // past the guard and left two polling loops running against one service.
        // Both would then capture and persist the same window.
        isActive = true

        monitorTask = Task { [weak self] in
            guard let self else { return }

            // Pre-flight: ensure Screen Recording permission is granted.
            // Trigger the TCC dialog — but DO NOT force-open System Settings,
            // that steals focus (user can re-enable the toggle to get here again).
            if !CGPreflightScreenCaptureAccess() {
                NSLog("[ScreenContext] No Screen Recording permission — requesting...")
                _ = await PermissionsService.shared.requestScreenRecording()

                if !CGPreflightScreenCaptureAccess() {
                    NSLog("[ScreenContext] ❌ Permission denied — monitor not started")
                    await MainActor.run { self.isActive = false }
                    return
                }
            }

            NSLog("[ScreenContext] ✅ Monitoring started (interval: %.0fs)", interval)

            // Subscribe to instant app-activation notifications for fast call
            // detection. The 30 s poll below still runs for OCR + memory
            // capture, but call detection now fires within ~100 ms of focus
            // change so we don't miss short calls or fast-switching users.
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.instantAppActivationObserver = NSWorkspace.shared
                    .notificationCenter.addObserver(
                        forName: NSWorkspace.didActivateApplicationNotification,
                        object: nil,
                        queue: .main
                    ) { [weak self] _ in
                        Task { [weak self] in
                            await self?.checkCallContextInstant()
                            // ITER-065 settle, finally wired — Omi-style
                            // event-driven capture. The user landed on a
                            // window; give it 750 ms to stop being a blur of
                            // switching, then capture NOW instead of waiting
                            // for the 30-second poll. If they have already
                            // moved on, the front window at settle time is the
                            // one that gets captured — which is the point.
                            // The change mark dedupes against the poll.
                            try? await Task.sleep(
                                for: .seconds(ScreenAgentTimingPolicy.settleSeconds))
                            await self?.captureIfChanged()
                        }
                    }
            }

            while !Task.isCancelled {
                await self.captureIfChanged()
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    /// Lightweight call-detection-only pass. Triggered by NSWorkspace
    /// instant-activation notifications (within ~100 ms of focus change),
    /// independent of the 30 s OCR loop. Mirrors the call-detection branch
    /// of `captureIfChanged` but skips OCR + persistence (no expensive work
    /// on every app switch). Same dedup via `lastCallContext` so we never
    /// double-fire.
    private func checkCallContextInstant() async {
        guard let frontApp = await MainActor.run(body: { NSWorkspace.shared.frontmostApplication }) else { return }
        let appName = frontApp.localizedName ?? "Unknown"
        let bundleID = frontApp.bundleIdentifier ?? ""

        // ITER-064A.8 — this path only ever got the blacklist, so an allowlist
        // could not stop it reading titles or starting a recording. Same rule as
        // the polling path now: don't even peek at a window we may not look at.
        let policy = currentPolicy()
        guard ScreenContextPolicy.isCaptureAllowed(
            appName: appName, bundleID: bundleID,
            blacklist: policy.blacklist, whitelist: policy.whitelist
        ) else {
            lastCaptureOutcome = .excluded
            return
        }

        let windowTitle = getActiveWindowTitle(pid: frontApp.processIdentifier) ?? ""
        let currentCall = SystemAudioCaptureService.detectCallContext(
            bundleID: bundleID,
            appName: appName,
            windowTitle: windowTitle
        )
        if currentCall != lastCallContext {
            lastCallContext = currentCall
            NSLog("[ScreenContext] ⚡️ instant call-context change: %@ (app=%@)",
                  currentCall ?? "nil", appName)
            await MainActor.run { self.onCallContext?(currentCall) }
        }
    }

    func stopMonitoring() {
        monitorTask?.cancel()
        monitorTask = nil
        if let observer = instantAppActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            instantAppActivationObserver = nil
        }
        isActive = false
        // Codex P0 — strand whatever is mid-await and drop the frame vision
        // could still read: stopping capture stops its products too.
        captureEpoch += 1
        frameCache.invalidateAll()
        // The accepted-screen identity goes with it: turning the feature off
        // and on again inside five minutes used to leave a model call from
        // before the pause able to pass the final freshness check (Codex).
        lastAcceptedContextID = nil
        visitCoordinator.invalidateAll()
        lastCommittedToken = 0
        NSLog("[ScreenContext] Monitoring stopped")
    }

    /// ITER-064A.5 — the user's current capture policy. Read per use, never
    /// stored: a stored copy is what let a Settings change be ignored until
    /// relaunch.
    private func currentPolicy() -> (blacklist: Set<String>, whitelist: Set<String>?) {
        ScreenContextPolicy.effective(
            alwaysExcluded: defaultBlacklist,
            mode: AppSettings.shared.screenContextMode,
            appList: AppSettings.shared.screenContextAppList
        )
    }

    /// Force capture current screen context.
    func captureNow() async -> ScreenContextSnapshot? {
        // AUD-023 — respect the master toggle. If the user turned Screen Context
        // off, do NOT capture the screen even for an on-demand voice question.
        guard AppSettings.shared.screenContextEnabled else {
            lastCaptureOutcome = .excluded
            return nil
        }
        // AUD-021 — apply the user's blacklist/whitelist here too (not only the
        // default password-app list), so an excluded app isn't captured on demand.
        let policy = currentPolicy()
        // The voice path reads the screen, it does not feed vision — the
        // frame is dropped here, not parked in shared state for some other
        // flow's persist to misattribute.
        return await captureActiveWindow(
            blacklist: policy.blacklist,
            whitelist: policy.whitelist
        )?.snapshot
    }

    // MARK: - Private

    /// Codex P1 — poll tick and settle tasks may otherwise interleave their
    /// awaits and bind screen B's pixels to screen A's row.
    private var captureInFlight = false

    private func captureIfChanged() async {
        // Codex P0 — settle tasks from the activation observer are fired and
        // forgotten, so they arrive here AFTER stopMonitoring or master-off.
        // Off means off for work in flight too, not just for the next tick.
        guard isActive, AppSettings.shared.screenContextEnabled else { return }
        guard !captureInFlight else { return }
        captureInFlight = true
        defer { captureInFlight = false }
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return }
        let appName = frontApp.localizedName ?? "Unknown"
        let bundleID = frontApp.bundleIdentifier ?? ""

        let policy = currentPolicy()
        let blacklist = policy.blacklist
        let whitelist = policy.whitelist

        // ITER-064A.8 — the permission check now covers call detection too. It
        // used to sit below, so an app the user had not allowed still had its
        // window title read and could auto-start a meeting recording: no OCR
        // row, but the recorder ran anyway.
        guard ScreenContextPolicy.isCaptureAllowed(
            appName: appName, bundleID: bundleID,
            blacklist: blacklist, whitelist: whitelist
        ) else {
            lastCaptureOutcome = .excluded
            logSuppressedCaptureIfNeeded(appName: appName, whitelist: whitelist)
            return
        }

        // Get window title via Accessibility API (needed for both OCR and call detection)
        let windowTitle = getActiveWindowTitle(pid: frontApp.processIdentifier) ?? ""

        // Call detection — ITER-026 v2: FRONTMOST-only. A call always starts
        // when the user is actually LOOKING at the meeting window. A leftover
        // Meet tab parked in some background browser does NOT count — that
        // produced a false-positive auto-start (user report 2026-05-02:
        // "почему сейчас созвон включился?", auto-start fired against a
        // background Meet tab she'd opened earlier).
        //
        // The user CAN freely tab away mid-call without losing the recording
        // — that's owned separately by `handleCallContext(nil)`'s no-auto-stop
        // policy: once `meetingRecorder.isRecording` is true, window-loss
        // does NOT stop recording. Only the audio-silence guard (10 min) or
        // max-duration cap or manual STOP can stop. So detection can stay
        // strict (frontmost-only) without sacrificing tab-switch tolerance.
        let currentCall = SystemAudioCaptureService.detectCallContext(
            bundleID: bundleID,
            appName: appName,
            windowTitle: windowTitle
        )
        if currentCall != lastCallContext {
            lastCallContext = currentCall
            NSLog("[ScreenContext] Call context changed: %@", currentCall ?? "nil")
            onCallContext?(currentCall)
        }

        // Visit-wiring step 6 — the coordinator IS the decision now. An
        // unchanged window keeps its visit alive and consumes no capture; a
        // gap past 300s ends the visit and the same window is news again.
        // The shadow ran clean on real usage before this cutover: zero
        // divergences, one open visit, healthy closures.
        let tickProposal = visitCoordinator.propose(
            .init(bundleID: bundleID, appName: appName, rawTitle: windowTitle,
                  windowID: nil, displayID: nil, contentHash: lastCommittedToken),
            at: visitClock.now, wallClock: Date())
        if case .unchanged = tickProposal {
            visitCoordinator.commit(tickProposal, contentHash: lastCommittedToken,
                                    at: visitClock.now)
            touchDurableVisitIfStale()
            return
        }

        // ITER-053.1 purge fence — snapshot before the capture/OCR awaits.
        let epoch = captureEpoch
        if let capture = await captureActiveWindow(blacklist: blacklist, whitelist: whitelist) {
            let snapshot = capture.snapshot
            // The user hit «Delete screen history» while this capture was in
            // flight — discard it rather than re-adding pre-delete OCR.
            // Codex P0 — and re-check the switches: they can flip during the
            // screenshot/OCR awaits, and a frame captured under permission is
            // not a frame that may be persisted after it was withdrawn.
            guard epoch == captureEpoch, isActive,
                  AppSettings.shared.screenContextEnabled else { return }
            // The in-memory buffers advance only for a frame that actually
            // landed — advice reads `recentContexts`, so a failed save used to
            // still send OCR to a model with no durable source row (Codex).
            // Filled in right after persist, below.
            // The proposal is derived from the SNAPSHOT — the identity of the
            // window that was actually read, not the one this tick started on
            // (the user can switch mid-await). Proposed before persist so the
            // durable visit row lands in the same save as the screen row;
            // committed only after that save succeeds — the exact reason
            // propose and commit are separate calls.
            let token = Self.stableToken(snapshot.ocrText)
            let proposal = visitCoordinator.propose(
                .init(bundleID: snapshot.bundleID, appName: snapshot.appName,
                      rawTitle: snapshot.windowTitle,
                      windowID: nil, displayID: nil, contentHash: token),
                at: visitClock.now, wallClock: Date())

            // Persist first — it is what decides this cycle's outcome.
            persistContext(snapshot, frame: capture.frame,
                           visitProposal: proposal, visitToken: token)

            // ITER-064A.3 — consume the change from the window the frame
            // actually came from: the user may have switched during the await.
            // ITER-065.6 — and only when this cycle actually landed. A frame
            // that could not be stored leaves the window eligible for the next
            // poll instead of being marked as already in history.
            if lastCaptureOutcome.consumesWindowTurn {
                lastContext = snapshot
                recentContexts.append(snapshot)
                if recentContexts.count > maxRecentContexts {
                    recentContexts.removeFirst()
                }
                visitCoordinator.commit(proposal, contentHash: token, at: visitClock.now)
                lastCommittedToken = token
            }
        }
    }

    /// ITER-064A.2 — an empty allowlist is now fail-closed, which is correct
    /// but invisible: nothing is captured and nothing says why. Log the reason
    /// once per app so «Screen Context is on but the history is empty» is
    /// diagnosable from the log instead of looking like a broken capture.
    private func logSuppressedCaptureIfNeeded(appName: String, whitelist: Set<String>?) {
        guard let whitelist, whitelist.isEmpty else { return }
        guard !loggedSuppressedApps.contains(appName) else { return }
        // Codex review — bounded. One line per app is the point; an unbounded
        // set of every app name ever focused is not worth keeping around.
        if loggedSuppressedApps.count >= 64 { loggedSuppressedApps.removeAll() }
        loggedSuppressedApps.insert(appName)
        NSLog("[ScreenContext] Not capturing %@ — allowlist mode is on with no apps listed. Add apps in Settings, or switch to blacklist mode.", appName)
    }

    private func captureActiveWindow(
        blacklist: Set<String>,
        whitelist: Set<String>?
    ) async -> (snapshot: ScreenContextSnapshot, frame: CGImage?)? {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return nil }
        let appName = frontApp.localizedName ?? "Unknown"
        let bundleID = frontApp.bundleIdentifier ?? ""

        // Safety checks — same shared rule as the change detector above.
        guard ScreenContextPolicy.isCaptureAllowed(
            appName: appName, bundleID: bundleID,
            blacklist: blacklist, whitelist: whitelist
        ) else { return nil }

        let windowTitle = getActiveWindowTitle(pid: frontApp.processIdentifier) ?? ""

        // ITER-065.6 — a failed grab used to return a snapshot carrying the app
        // name, the window title and an empty OCR string, which is exactly what
        // a genuinely blank window looks like. That row was persisted, the
        // capture mark advanced so the window was never retried, and the agent
        // was woken for a frame nobody had managed to read. A failure is now a
        // failure.
        guard let shot = await captureScreenshot(frontPID: frontApp.processIdentifier) else {
            lastCaptureOutcome = .captureFailed
            return nil
        }
        let image = shot.image
        // Prefer the identity read from the window that was actually captured.
        let boundTitle = shot.windowTitle.flatMap { $0.isEmpty ? nil : $0 } ?? windowTitle

        // The frame rides WITH its snapshot, never through shared state: a
        // field here let a voice capture overwrite a poll capture mid-OCR and
        // bind screen B's pixels to screen A's row — and let a full-res image
        // outlive the flow that captured it (Codex P1 ×2).
        let frame = AppSettings.shared.screenAgentVisualConsent ? image : nil

        // Run OCR on the screenshot (on-device via Vision framework)
        // ITER-065.5 — Vision runs off the main thread now; the flat text
        // it produces is byte-identical to what this line used to return.
        let ocrText = await ScreenOCR.recognize(image).text

        let snapshot = ScreenContextSnapshot(
            timestamp: Date(),
            appName: appName,
            windowTitle: boundTitle,
            ocrText: ocrText,
            bundleID: bundleID,
            windowID: shot.windowID
        )

        NSLog("[ScreenContext] Captured: %@ — %@ (%d chars OCR)",
              appName, String(windowTitle.prefix(40)), ocrText.count)

        return (snapshot, frame)
    }

    /// Capture a screenshot of the screen using ScreenCaptureKit.
    private func captureScreenshot(frontPID: pid_t) async -> (image: CGImage, windowID: Int, windowTitle: String?)? {
        guard #available(macOS 14.0, *) else { return nil }

        guard CGPreflightScreenCaptureAccess() else {
            lastCaptureOutcome = .permissionDenied
            return nil
        }

        do {
            let content = try await SCShareableContent.current

            // ITER-065.8 — AUD-022 excluded other apps but kept every window of
            // the front app and captured a whole display, so two windows of one
            // app were merged into one blob and a second monitor was ignored
            // entirely. Bounds, on-screen state and window level come along now;
            // the old mapping supplied only id and pid, leaving every rectangle
            // zero.
            let refs = content.windows.map {
                ActiveAppCaptureFilter.WindowRef(
                    id: Int($0.windowID),
                    ownerPID: Int($0.owningApplication?.processID ?? -1),
                    bounds: $0.frame,
                    isOnScreen: $0.isOnScreen,
                    layer: $0.windowLayer
                )
            }

            let selection = ActiveAppCaptureFilter.selectFocusedWindow(
                refs,
                frontPID: Int(frontPID),
                focusedBounds: focusedWindowBounds(pid: frontPID)
            )
            guard case .window(let chosenID) = selection else {
                // Reading every candidate and labelling the result with one of
                // them would be confidently wrong, so nothing is read.
                lastCaptureOutcome = selection == .ambiguous ? .ambiguousWindow : .captureFailed
                return nil
            }
            guard let window = content.windows.first(where: { Int($0.windowID) == chosenID }) else {
                lastCaptureOutcome = .captureFailed
                return nil
            }

            // Include-only. Filtering a display down by exclusions would still
            // carry every sibling window of the same app.
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let config = SCStreamConfiguration()
            config.width = Int(window.frame.width)
            config.height = Int(window.frame.height)
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.showsCursor = false

            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
            )
            // The chosen window's OWN title: the AX title was sampled before
            // the SCShareableContent await, and focus can move between two
            // windows of one app in that gap — pixels from B labelled A.
            return (image, chosenID, window.title)
        } catch {
            NSLog("[ScreenContext] Screenshot failed: %@", error.localizedDescription)
            lastCaptureOutcome = .captureFailed
            return nil
        }
    }

    /// Perform OCR using Apple Vision framework (fully on-device).

    private func persistContext(_ snapshot: ScreenContextSnapshot, frame: CGImage?,
                                visitProposal: ContextVisitCoordinator.Proposal? = nil,
                                visitToken: Int = 0) {
        guard let container = modelContainer else { return }
        let ctx = ModelContext(container)
        let record = ScreenContext(
            appName: snapshot.appName,
            windowTitle: snapshot.windowTitle,
            ocrText: snapshot.ocrText
        )
        ctx.insert(record)
        // Visit-wiring step 4 — the durable visit row rides the SAME save as
        // the screen row it describes: both land or neither does.
        var visitIdentity: (id: UUID, generation: Int)?
        if let visitProposal {
            Self.upsertVisitRecord(
                proposal: visitProposal,
                currentVisit: visitCoordinator.current,
                acceptedContextID: record.id,
                captureState: "captured", token: visitToken, in: ctx)
            switch visitProposal {
            case .opened(let visit), .changed(let visit):
                visitIdentity = (visit.id, visit.generation)
            case .unchanged:
                visitIdentity = visitCoordinator.current.map { ($0.id, $0.generation) }
            }
        }
        do {
            try ctx.save()
        } catch {
            // ITER-065.6 — this was `try? save()` followed by an unconditional
            // callback, so the agent could be reasoning about a row that was
            // never written. Nothing downstream may treat an unsaved frame as
            // history.
            lastCaptureOutcome = .persistenceFailed
            NSLog("[ScreenContext] Persist failed (%@) — not waking the agent", error.localizedDescription)
            return
        }

        lastCaptureOutcome = .captured(ocrCharacters: snapshot.ocrText.count)
        // Step 5, after the save only — a failed save must not mutate the map
        // (a ghost mapping for a row that never landed, Codex).
        if let visitIdentity {
            rememberVisit(visitIdentity, for: record.id)
        }
        // ITER-067 — the screen the user is on right now, as far as capture
        // knows. Read at the last moment before interrupting, so a comment
        // about a window they have already left can be recognised as such.
        lastAcceptedContextID = record.id

        // ITER-069 — under visual consent, keep one downscaled frame for the
        // vision boundary, keyed to the row it describes. Consent is re-read
        // here because it can flip during the OCR await; the full-size image
        // dies with this flow's locals either way.
        if let frame,
           AppSettings.shared.screenAgentVisualConsent,
           let jpeg = ScreenFrameEncoder.downscaledJPEG(from: frame) {
            frameCache.store(contextID: record.id, jpeg: jpeg, generation: captureEpoch)
        }

        // Fire realtime hook for ITER-006 reactor (per-window LLM task check).
        // Callback handles its own guards/debounce — we just pass every persisted row.
        onContextPersisted?(record)
    }

    /// Get the title of the active window using Accessibility API.
    /// Screen rectangle of the app's focused window, from Accessibility.
    ///
    /// ITER-065.8 — this is what tells two windows of one app apart. Without it
    /// the capture had no way to know which of them the user was reading, so it
    /// took all of them and merged the text.
    private func focusedWindowBounds(pid: pid_t) -> CGRect? {
        let appElement = AXUIElementCreateApplication(pid)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focused) == .success,
              let window = focused else { return nil }
        let element = window as! AXUIElement

        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success
        else { return nil }

        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        else { return nil }
        return CGRect(origin: origin, size: size)
    }

    private func getActiveWindowTitle(pid: pid_t) -> String? {
        let appElement = AXUIElementCreateApplication(pid)
        var focusedWindow: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedWindow)
        guard result == .success, let window = focusedWindow else { return nil }

        var titleValue: CFTypeRef?
        let titleResult = AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &titleValue)
        guard titleResult == .success, let title = titleValue as? String else { return nil }

        return title
    }
}
