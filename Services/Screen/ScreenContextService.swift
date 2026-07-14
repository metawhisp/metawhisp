import AppKit
import Foundation
import ScreenCaptureKit
import SwiftData
import Vision

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
    }

    private var monitorTask: Task<Void, Never>?
    private var lastAppName: String?
    private var lastWindowTitle: String?
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
    func startMonitoring(
        interval: TimeInterval = 30,
        blacklist: Set<String> = [],
        whitelist: Set<String>? = nil
    ) {
        guard !isActive else { return }
        // ITER-049 A2 — a degraded (temporary in-memory) session is read-only; don't
        // capture OCR into the empty store or stage candidates from it. Covers every
        // start path (launch, Settings toggle, applicationDidBecomeActive re-arm).
        guard StoreHealthSignal.shared.isHealthy else { return }

        let mergedBlacklist = defaultBlacklist.union(blacklist)

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

            await MainActor.run { self.isActive = true }
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
                            await self?.checkCallContextInstant(
                                blacklist: mergedBlacklist
                            )
                        }
                    }
            }

            while !Task.isCancelled {
                await self.captureIfChanged(blacklist: mergedBlacklist, whitelist: whitelist)
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
    private func checkCallContextInstant(blacklist: Set<String>) async {
        guard let frontApp = await MainActor.run(body: { NSWorkspace.shared.frontmostApplication }) else { return }
        let appName = frontApp.localizedName ?? "Unknown"
        let bundleID = frontApp.bundleIdentifier ?? ""

        // Bail on privacy-blacklisted apps (1Password etc) — don't even
        // peek at their window titles.
        if blacklist.contains(bundleID) || blacklist.contains(appName) { return }

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

    /// Force capture current screen context.
    func captureNow() async -> ScreenContextSnapshot? {
        // AUD-023 — respect the master toggle. If the user turned Screen Context
        // off, do NOT capture the screen even for an on-demand voice question.
        guard AppSettings.shared.screenContextEnabled else { return nil }
        // AUD-021 — apply the user's blacklist/whitelist here too (not only the
        // default password-app list), so an excluded app isn't captured on demand.
        let policy = ScreenContextPolicy.resolve(
            mode: AppSettings.shared.screenContextMode,
            appList: AppSettings.shared.screenContextAppList
        )
        return await captureActiveWindow(
            blacklist: defaultBlacklist.union(policy.blacklist),
            whitelist: policy.whitelist
        )
    }

    // MARK: - Private

    private func captureIfChanged(blacklist: Set<String>, whitelist: Set<String>?) async {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return }
        let appName = frontApp.localizedName ?? "Unknown"
        let bundleID = frontApp.bundleIdentifier ?? ""

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

        // Check blacklist
        if blacklist.contains(bundleID) || blacklist.contains(appName) {
            return
        }

        // Check whitelist (if set, only capture listed apps)
        if let whitelist, !whitelist.isEmpty {
            if !whitelist.contains(bundleID) && !whitelist.contains(appName) {
                return
            }
        }

        // Only capture if app or window changed
        guard appName != lastAppName || windowTitle != lastWindowTitle else { return }
        lastAppName = appName
        lastWindowTitle = windowTitle

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
            // Persist to SwiftData
            persistContext(snapshot)
        }
    }

    private func captureActiveWindow(
        blacklist: Set<String>,
        whitelist: Set<String>?
    ) async -> ScreenContextSnapshot? {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return nil }
        let appName = frontApp.localizedName ?? "Unknown"
        let bundleID = frontApp.bundleIdentifier ?? ""

        // Safety checks
        if blacklist.contains(bundleID) || blacklist.contains(appName) { return nil }
        if let whitelist, !whitelist.isEmpty,
           !whitelist.contains(bundleID) && !whitelist.contains(appName) {
            return nil
        }

        let windowTitle = getActiveWindowTitle(pid: frontApp.processIdentifier) ?? ""

        // Capture screenshot of the active window
        guard let image = await captureScreenshot(frontPID: frontApp.processIdentifier) else {
            // Fallback: create context with just app/window info (no OCR)
            return ScreenContextSnapshot(
                timestamp: Date(),
                appName: appName,
                windowTitle: windowTitle,
                ocrText: ""
            )
        }

        // Run OCR on the screenshot (on-device via Vision framework)
        let ocrText = await performOCR(on: image)

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

        do {
            let content = try await SCShareableContent.current
            guard let display = content.displays.first else { return nil }

            // AUD-022 — capture only the front app's content. Exclude every window
            // not owned by the front app so a password manager / private chat
            // visible beside the focused app is never OCR'd into history or AI.
            let refs = content.windows.map {
                ActiveAppCaptureFilter.WindowRef(
                    id: Int($0.windowID),
                    ownerPID: Int($0.owningApplication?.processID ?? -1)
                )
            }
            let excludeIDs = Set(ActiveAppCaptureFilter.windowsToExclude(refs, frontPID: Int(frontPID)))
            let excludeWindows = content.windows.filter { excludeIDs.contains(Int($0.windowID)) }

            let filter = SCContentFilter(display: display, excludingWindows: excludeWindows)
            let config = SCStreamConfiguration()
            config.width = Int(display.width)
            config.height = Int(display.height)
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.showsCursor = false

            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
            )
            return image
        } catch {
            NSLog("[ScreenContext] Screenshot failed: %@", error.localizedDescription)
            return nil
        }
    }

    /// Perform OCR using Apple Vision framework (fully on-device).
    private func performOCR(on image: CGImage) async -> String {
        await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                guard let observations = request.results as? [VNRecognizedTextObservation] else {
                    continuation.resume(returning: "")
                    return
                }

                let text = observations
                    .compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: "\n")

                continuation.resume(returning: text)
            }

            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            // Support multiple languages
            request.recognitionLanguages = ["en-US", "ru-RU", "de-DE", "fr-FR", "es-ES"]
            request.automaticallyDetectsLanguage = true

            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do {
                try handler.perform([request])
            } catch {
                NSLog("[ScreenContext] OCR failed: %@", error.localizedDescription)
                continuation.resume(returning: "")
            }
        }
    }

    private func persistContext(_ snapshot: ScreenContextSnapshot) {
        guard let container = modelContainer else { return }
        let ctx = ModelContext(container)
        let record = ScreenContext(
            appName: snapshot.appName,
            windowTitle: snapshot.windowTitle,
            ocrText: snapshot.ocrText
        )
        ctx.insert(record)
        try? ctx.save()

        // Fire realtime hook for ITER-006 reactor (per-window LLM task check).
        // Callback handles its own guards/debounce — we just pass every persisted row.
        onContextPersisted?(record)
    }

    /// Get the title of the active window using Accessibility API.
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
