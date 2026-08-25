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
        pendingFrame = nil
        // ITER-064A.7 — the mark says "this window is already in history". After
        // a purge that is no longer true for any window, and a capture dropped
        // by the epoch fence never advanced it either. Leaving it set meant a
        // window the user was still sitting on could never be captured again.
        captureMark = CaptureHighWaterMark()
    }

    private var monitorTask: Task<Void, Never>?
    /// ITER-064A.3 — advanced only by an accepted frame, so a failed capture
    /// stays eligible for the next poll.
    private var captureMark = CaptureHighWaterMark()
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

    /// ITER-069 — the one frame vision may look at. Populated only under the
    /// separate visual consent; capacity one; memory only.
    let frameCache = ScreenAgentFrameCache()

    /// The image behind the snapshot currently being persisted. Held only
    /// between capture and persist so the cache can be keyed to the stored
    /// row's ID, then released — snapshots themselves must not retain pixels,
    /// twenty of them sit in `recentContexts`.
    private var pendingFrame: CGImage?

    /// Fires after each newly-persisted ScreenContext (one per captured window change).
    /// Used by `RealtimeScreenReactor` (ITER-006) to do per-window LLM task checks with its
    /// own debounce/rate-limit. Hook layered on top of the polling loop — no extra timers.
    ///
    /// Implements spec://iterations/ITER-006-realtime-screen-reaction#scope.2
    var onContextPersisted: ((ScreenContext) -> Void)?

    /// Set the model container for SwiftData persistence.
    func configure(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    /// In-memory snapshot (not persisted — used for advice generation).
    struct ScreenContextSnapshot {
        let timestamp: Date
        let appName: String
        let windowTitle: String
        let ocrText: String
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
        return await captureActiveWindow(
            blacklist: policy.blacklist,
            whitelist: policy.whitelist
        )
    }

    // MARK: - Private

    private func captureIfChanged() async {
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

        // Only capture if app or window changed
        guard captureMark.hasChanged(appName: appName, windowTitle: windowTitle) else { return }

        // ITER-053.1 purge fence — snapshot before the capture/OCR awaits.
        let epoch = captureEpoch
        if let snapshot = await captureActiveWindow(blacklist: blacklist, whitelist: whitelist) {
            // The user hit «Delete screen history» while this capture was in
            // flight — discard it rather than re-adding pre-delete OCR.
            guard epoch == captureEpoch else { return }
            lastContext = snapshot
            recentContexts.append(snapshot)
            if recentContexts.count > maxRecentContexts {
                recentContexts.removeFirst()
            }
            // Persist first — it is what decides this cycle's outcome.
            persistContext(snapshot)

            // ITER-064A.3 — consume the change from the window the frame
            // actually came from: the user may have switched during the await.
            // ITER-065.6 — and only when this cycle actually landed. A frame
            // that could not be stored leaves the window eligible for the next
            // poll instead of being marked as already in history.
            if lastCaptureOutcome.consumesWindowTurn {
                captureMark.accept(appName: snapshot.appName, windowTitle: snapshot.windowTitle)
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
    ) async -> ScreenContextSnapshot? {
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
        guard let image = await captureScreenshot(frontPID: frontApp.processIdentifier) else {
            lastCaptureOutcome = .captureFailed
            return nil
        }

        pendingFrame = AppSettings.shared.screenAgentVisualConsent ? image : nil

        // Run OCR on the screenshot (on-device via Vision framework)
        // ITER-065.5 — Vision runs off the main thread now; the flat text
        // it produces is byte-identical to what this line used to return.
        let ocrText = await ScreenOCR.recognize(image).text

        let snapshot = ScreenContextSnapshot(
            timestamp: Date(),
            appName: appName,
            windowTitle: windowTitle,
            ocrText: ocrText
        )

        NSLog("[ScreenContext] Captured: %@ — %@ (%d chars OCR)",
              appName, String(windowTitle.prefix(40)), ocrText.count)

        return snapshot
    }

    /// Capture a screenshot of the screen using ScreenCaptureKit.
    private func captureScreenshot(frontPID: pid_t) async -> CGImage? {
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

            return try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
            )
        } catch {
            NSLog("[ScreenContext] Screenshot failed: %@", error.localizedDescription)
            lastCaptureOutcome = .captureFailed
            return nil
        }
    }

    /// Perform OCR using Apple Vision framework (fully on-device).

    private func persistContext(_ snapshot: ScreenContextSnapshot) {
        guard let container = modelContainer else { return }
        let ctx = ModelContext(container)
        let record = ScreenContext(
            appName: snapshot.appName,
            windowTitle: snapshot.windowTitle,
            ocrText: snapshot.ocrText
        )
        ctx.insert(record)
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
        // ITER-067 — the screen the user is on right now, as far as capture
        // knows. Read at the last moment before interrupting, so a comment
        // about a window they have already left can be recognised as such.
        lastAcceptedContextID = record.id

        // ITER-069 — under visual consent, keep one downscaled frame for the
        // vision boundary, keyed to the row it describes. The full-size image
        // is released either way.
        if let frame = pendingFrame,
           AppSettings.shared.screenAgentVisualConsent,
           let jpeg = ScreenFrameEncoder.downscaledJPEG(from: frame) {
            frameCache.store(contextID: record.id, jpeg: jpeg)
        }
        pendingFrame = nil

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
