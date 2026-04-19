import AppKit
import Combine
import Foundation
import Sparkle
import SwiftUI
import UserNotifications
import os

/// Manages the status bar item and popover.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private static let logger = Logger(subsystem: "com.metawhisp.app", category: "AppDelegate")

    /// SwiftUI's `@NSApplicationDelegateAdaptor` sets this instance as `NSApp.delegate`,
    /// but runtime `as? AppDelegate` casts from views can fail (NSApp.delegate is typed as
    /// the Obj-C `NSApplicationDelegate` protocol). Views use `AppDelegate.shared` instead.
    static private(set) weak var shared: AppDelegate?

    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var eventMonitor: Any?

    // Services
    let recorder = AudioRecordingService()
    let systemAudioCapture = SystemAudioCaptureService()
    /// Captures mic + system audio in parallel for meeting recording.
    lazy var meetingRecorder = MeetingRecorder(mic: recorder, systemAudio: systemAudioCapture)
    var whisperEngine: WhisperKitEngine?
    let textInserter = TextInsertionService()
    let soundService = SoundService()
    let hotkeyService = HotkeyService()
    let modelManager = ModelManagerService()
    let historyService = HistoryService()
    let screenContext = ScreenContextService()
    let adviceService = AdviceService()
    let memoryExtractor = MemoryExtractor()
    let taskExtractor = TaskExtractor()
    let chatService = ChatService()
    let conversationGrouper = ConversationGrouper()
    let structuredGenerator = StructuredGenerator()
    let screenExtractor = ScreenExtractor()
    let fileIndexer = FileIndexerService()
    let fileMemoryExtractor = FileMemoryExtractor()
    let appleNotesReader = AppleNotesReaderService()
    let calendarReader = CalendarReaderService()
    var coordinator: TranscriptionCoordinator!
    let overlay = RecordingOverlayController()
    let mainWindow = MainWindowController()
    let onboardingWindow = OnboardingWindowController()
    var selectionTranslator: SelectionTranslator!
    var updaterController: SPUStandardUpdaterController!
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self
        FileLogger.setup()

        // Apply saved theme
        MW.applyTheme(AppSettings.shared.appTheme)

        // Single-instance guard: if another MetaWhisp is already running, activate it and quit
        let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "com.metawhisp.app")
        if runningApps.count > 1 {
            // Another instance is running — activate it and terminate ourselves
            for app in runningApps where app != NSRunningApplication.current {
                app.activate()
            }
            NSLog("[MetaWhisp] Another instance already running, quitting")
            NSApp.terminate(nil)
            return
        }

        // Sparkle auto-updater
        updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

        NSLog("[MetaWhisp] Launched")

        // Register URL scheme handler (metawhisp://auth?token=...)
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleURLEvent(_:withReply:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )

        coordinator = TranscriptionCoordinator(
            recorder: recorder,
            whisperEngine: nil,
            textInserter: textInserter,
            soundService: soundService,
            settings: AppSettings.shared
        )
        coordinator.historyService = historyService
        coordinator.textProcessor = TextProcessor()
        let corrections = CorrectionDictionary.shared
        coordinator.correctionDictionary = corrections
        coordinator.correctionMonitor = CorrectionMonitor(dictionary: corrections)
        // Memory + task triggers on transcription (Omi-aligned).
        // AdviceService reference kept for backward compat (existing AdviceItem records shown in UI),
        // but periodic advice generation is disabled — replaced by TaskExtractor (spec://BACKLOG#B1).
        coordinator.adviceService = adviceService
        coordinator.memoryExtractor = memoryExtractor
        coordinator.taskExtractor = taskExtractor
        coordinator.conversationGrouper = conversationGrouper
        selectionTranslator = SelectionTranslator(
            textProcessor: coordinator.textProcessor!,
            textInserter: textInserter,
            soundService: soundService,
            overlay: overlay
        )

        // Create popover — .applicationDefined so clicks inside don't close it
        let popover = NSPopover()
        popover.contentSize = NSSize(width: 300, height: 300)
        popover.behavior = .applicationDefined
        popover.delegate = self
        popover.contentViewController = NSHostingController(
            rootView: PopoverRootView(
                coordinator: coordinator,
                recorder: recorder,
                meetingRecorder: meetingRecorder,
                screenContext: screenContext,
                closePopover: { [weak self] in self?.closePopover() },
                openMainWindow: { [weak self] in self?.openMainWindow() },
                onMeetingToggle: { [weak self] in self?.toggleMeetingRecording() }
            )
        )
        self.popover = popover

        // Status bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = Self.createMWMenuBarIcon()
            button.action = #selector(togglePopover)
            button.target = self
        }

        // Bind floating overlay to coordinator stage + audio levels
        overlay.bind(to: coordinator, recorder: recorder)

        // Setup services async
        Task {
            await setupServices()
        }

        // Show onboarding on first launch, otherwise open main window
        if !AppSettings.shared.hasCompletedOnboarding {
            onboardingWindow.coordinator = coordinator
            onboardingWindow.show()
        } else {
            openMainWindow()
        }

        // Menu bar icon stays MW logo — no state changes needed
        // (the floating pill overlay shows state instead)

        // Watch for engine changes to load/unload WhisperKit model dynamically
        var lastEngine = AppSettings.shared.transcriptionEngine
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .sink { [weak self] _ in
                guard let self else { return }
                let newEngine = AppSettings.shared.transcriptionEngine
                guard newEngine != lastEngine else { return }
                lastEngine = newEngine
                Task { @MainActor in
                    if newEngine == "cloud" {
                        NSLog("[MetaWhisp] ☁️ Switched to Cloud — deallocating WhisperKit to free RAM")
                        await self.whisperEngine?.unloadModel()
                        self.whisperEngine = nil
                        self.coordinator.whisperEngine = nil
                    } else {
                        NSLog("[MetaWhisp] 💻 Switched to On-device — creating WhisperKit engine...")
                        let engine = WhisperKitEngine()
                        self.whisperEngine = engine
                        self.coordinator.whisperEngine = engine
                        let modelId = AppSettings.shared.selectedModel
                        if self.modelManager.isDownloaded(modelId),
                           let variant = self.modelManager.variantName(modelId) {
                            do {
                                try await engine.loadModel(variant, progressHandler: nil)
                                NSLog("[MetaWhisp] ✅ Model loaded successfully")
                            } catch {
                                NSLog("[MetaWhisp] ❌ Failed to load model: \(error)")
                                self.coordinator.lastError = "Failed to load model: \(error.localizedDescription)"
                            }
                        }
                    }
                }
            }
            .store(in: &cancellables)
    }

    @objc private func togglePopover() {
        if popover.isShown {
            closePopover()
        } else if let button = statusItem.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()

            // Close popover when clicking outside
            eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                self?.closePopover()
            }
        }
    }

    private func closePopover() {
        popover.performClose(nil)
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    func openMainWindow(tab: MainWindowView.SidebarTab? = nil) {
        closePopover()
        mainWindow.open(
            coordinator: coordinator,
            modelManager: modelManager,
            recorder: recorder,
            historyService: historyService,
            initialTab: tab
        )
    }

    private func setupServices() async {
        // 0. Pre-warm audio engine (eliminates ~150ms cold-start delay)
        recorder.warmUp()

        // 1. Microphone permission
        NSLog("[MetaWhisp] Requesting microphone permission...")
        let granted = await recorder.requestPermission()
        NSLog("[MetaWhisp] Microphone permission: %@", granted ? "GRANTED" : "DENIED")
        if !granted {
            coordinator.lastError = "🎤 Microphone denied — press Right ⌘ to retry (opens Settings)"
        }

        // 2. Request accessibility (needed for text insertion via Cmd+V)
        if !AXIsProcessTrusted() {
            NSLog("[MetaWhisp] Accessibility NOT granted — requesting...")
            let opts = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary
            AXIsProcessTrustedWithOptions(opts)
        } else {
            NSLog("[MetaWhisp] Accessibility: YES")
        }

        // 3. Hotkeys: Right ⌘ = transcribe, Right ⌥ tap = voice+translate, Right ⌥ hold = translate selection
        hotkeyService.register(
            onToggle: { [weak self] in self?.coordinator.toggle() },
            onPTTStart: { [weak self] in self?.coordinator.startPTT() },
            onPTTStop: { [weak self] in self?.coordinator.stopPTT() },
            onTranslateToggle: { [weak self] in self?.coordinator.toggleWithTranslation() },
            onTranslateLongPress: { [weak self] in self?.selectionTranslator.translateSelection() }
        )

        // 4. Find downloaded models
        await modelManager.fetchAvailableModels()
        NSLog("[MetaWhisp] Downloaded models: %@", "\(modelManager.downloadedModels)")

        // 5. Auto-switch to cloud if Pro subscription is active
        if LicenseService.shared.isPro && AppSettings.shared.transcriptionEngine != "cloud" {
            NSLog("[MetaWhisp] 🔄 Pro subscription detected — auto-switching to cloud transcription")
            AppSettings.shared.transcriptionEngine = "cloud"
        }

        // 6. Load selected model (skip if cloud transcription is selected — WhisperKit not created, saves ~1 GB RAM)
        let isCloudMode = AppSettings.shared.transcriptionEngine == "cloud"
        if isCloudMode {
            NSLog("[MetaWhisp] ☁️ Cloud transcription selected — WhisperKit not loaded (RAM saved)")
        } else {
            let engine = WhisperKitEngine()
            self.whisperEngine = engine
            self.coordinator.whisperEngine = engine

            let modelId = AppSettings.shared.selectedModel
            NSLog("[MetaWhisp] Selected model: %@, language: %@", modelId, AppSettings.shared.transcriptionLanguage)

            if modelManager.isDownloaded(modelId),
               let variant = modelManager.variantName(modelId)
            {
                NSLog("[MetaWhisp] Loading model: \(variant)...")
                do {
                    try await engine.loadModel(variant, progressHandler: nil)
                    NSLog("[MetaWhisp] ✅ Model loaded successfully")
                    if coordinator.lastError?.contains("model") == true {
                        coordinator.lastError = nil
                    }
                } catch {
                    NSLog("[MetaWhisp] ❌ Failed to load model: \(error)")
                    coordinator.lastError = "Failed to load model: \(error.localizedDescription)"
                }
            } else {
                NSLog("[MetaWhisp] ⚠️ No downloaded model found for '\(modelId)'")
                coordinator.lastError = "No model loaded. Go to Settings to download one."
            }
        }

        // 7. Configure screen context with persistence
        screenContext.configure(modelContainer: historyService.modelContainer)
        if AppSettings.shared.screenContextEnabled {
            let interval = AppSettings.shared.screenContextInterval
            screenContext.startMonitoring(interval: interval)
        }

        // 9a. Configure MemoryExtractor + TaskExtractor — both trigger-based on voice transcription.
        // Omi-aligned: voice transcript input, not periodic screen OCR polling.
        // spec://iterations/ITER-001#architecture.extractor + spec://BACKLOG#B1
        memoryExtractor.configure(screenContext: screenContext, modelContainer: historyService.modelContainer)
        taskExtractor.configure(screenContext: screenContext, modelContainer: historyService.modelContainer)

        // 9c. Configure ChatService (RAG over memories + transcripts + tasks).
        // spec://BACKLOG#B2
        chatService.configure(modelContainer: historyService.modelContainer)

        // 9d. Configure ConversationGrouper (C1.1) + StructuredGenerator (C1.2).
        // Grouper fires StructuredGenerator whenever a conversation closes.
        conversationGrouper.configure(modelContainer: historyService.modelContainer)
        structuredGenerator.configure(modelContainer: historyService.modelContainer)

        // 9e. Configure ScreenExtractor (Phase 2 R1) — hourly batch analysis of screen activity.
        screenExtractor.configure(modelContainer: historyService.modelContainer)
        if AppSettings.shared.screenExtractionEnabled {
            screenExtractor.startPeriodic(interval: AppSettings.shared.screenExtractionInterval)
        }

        // 9f. Configure FileIndexer + FileMemoryExtractor (Phase 3 E1).
        fileIndexer.configure(modelContainer: historyService.modelContainer)
        fileMemoryExtractor.configure(modelContainer: historyService.modelContainer)
        if AppSettings.shared.fileIndexingEnabled {
            fileIndexer.startPeriodic(interval: AppSettings.shared.fileIndexingInterval)
        }

        // 9g. Configure AppleNotesReader (Phase 3 E2).
        appleNotesReader.configure(modelContainer: historyService.modelContainer)
        if AppSettings.shared.appleNotesEnabled {
            appleNotesReader.startPeriodic(interval: AppSettings.shared.appleNotesInterval)
        }

        // 9h. Configure CalendarReader (Phase 3 E3).
        calendarReader.configure(modelContainer: historyService.modelContainer)
        if AppSettings.shared.calendarReaderEnabled {
            calendarReader.startPeriodic(interval: AppSettings.shared.calendarReaderInterval)
        }

        // 9b. Configure AdviceService (kept for legacy AdviceItem display in UI only).
        // Periodic advice generation disabled — replaced by TaskExtractor (Omi pattern).
        // spec://BACKLOG#B1
        adviceService.configure(screenContext: screenContext, modelContainer: historyService.modelContainer)

        // Ensure notification permission is requested at least once so notifications work
        // when TaskExtractor / MemoryExtractor want to surface events.
        Task { @MainActor in
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            if settings.authorizationStatus == .notDetermined {
                _ = await NotificationService.shared.requestPermission()
            }
        }

        // 10. Watch for intelligence settings changes
        observeIntelligenceSettings()
    }

    /// Open System Settings > Microphone page.
    func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Watch for intelligence feature toggles and react in realtime.
    private func observeIntelligenceSettings() {
        var lastScreenContext = AppSettings.shared.screenContextEnabled
        var lastAdvice = AppSettings.shared.adviceEnabled
        var lastMeeting = AppSettings.shared.meetingRecordingEnabled
        var lastMemories = AppSettings.shared.memoriesEnabled

        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .sink { [weak self] _ in
                guard let self else { return }
                let newScreenContext = AppSettings.shared.screenContextEnabled
                let newAdvice = AppSettings.shared.adviceEnabled

                if newScreenContext != lastScreenContext {
                    lastScreenContext = newScreenContext
                    Task { @MainActor in
                        if newScreenContext {
                            // Proactively request permission so user sees TCC dialog
                            _ = await PermissionsService.shared.requestScreenRecording()
                            self.screenContext.startMonitoring(interval: AppSettings.shared.screenContextInterval)
                            NSLog("[MetaWhisp] Screen context enabled")
                        } else {
                            self.screenContext.stopMonitoring()
                            NSLog("[MetaWhisp] Screen context disabled")
                        }
                    }
                }

                if newAdvice != lastAdvice {
                    lastAdvice = newAdvice
                    // Periodic advice generation retired — TaskExtractor replaces it (Omi pattern).
                    // Toggle now only affects visibility of legacy AdviceItem records in UI.
                    NSLog("[MetaWhisp] AI advice toggle: %@ (periodic disabled — see spec://BACKLOG#B1)", newAdvice ? "ON" : "OFF")
                }

                let newMeeting = AppSettings.shared.meetingRecordingEnabled
                if newMeeting != lastMeeting {
                    lastMeeting = newMeeting
                    if newMeeting {
                        Task { @MainActor in
                            // Warm up the permission dialog so user isn't surprised when they click Record
                            _ = await PermissionsService.shared.requestScreenRecording()
                            NSLog("[MetaWhisp] Meeting recording enabled (permission pre-requested)")
                        }
                    }
                }

                // Memory extraction toggle is now stateless — MemoryExtractor.triggerOnTranscription
                // checks `settings.memoriesEnabled` at fire time. Nothing to start/stop.
                let newMemories = AppSettings.shared.memoriesEnabled
                if newMemories != lastMemories {
                    lastMemories = newMemories
                    NSLog("[MetaWhisp] Memory extraction %@", newMemories ? "enabled" : "disabled")
                }
            }
            .store(in: &cancellables)
    }

    /// Toggle meeting recording (mic + system audio together → transcription).
    func toggleMeetingRecording() {
        // Clear stale error so UI updates cleanly on retry
        meetingRecorder.lastError = nil
        systemAudioCapture.lastError = nil

        if meetingRecorder.isRecording || meetingRecorder.isStarting {
            stopMeetingRecording()
        } else {
            startMeetingRecording()
        }
    }

    private func startMeetingRecording() {
        // MeetingRecorder handles mic + system audio in parallel.
        // Errors surface via meetingRecorder.lastError (shown in popover).
        meetingRecorder.start()
        NSLog("[MetaWhisp] ▶️ Meeting recording start requested")
    }

    private func stopMeetingRecording() {
        let samples = meetingRecorder.stop()
        NSLog("[MetaWhisp] Meeting stopped, %d mixed samples", samples.count)

        guard samples.count > 16000 else { // > 1 second
            NSLog("[MetaWhisp] Meeting recording too short, discarding")
            return
        }

        // Segment long recordings into chunks for WhisperKit (max ~5 min each)
        let chunkSize = Int(16000 * 300) // 5 minutes at 16kHz
        let chunks: [[Float]]
        if samples.count > chunkSize {
            chunks = stride(from: 0, to: samples.count, by: chunkSize).map {
                Array(samples[$0..<min($0 + chunkSize, samples.count)])
            }
        } else {
            chunks = [samples]
        }

        Task {
            // Use the SAME engine the main coordinator uses (on-device WhisperKit or cloud).
            // Reading `coordinator.activeEngine` at transcription time picks up whatever the user
            // has selected + any model that's been loaded since app launch.
            guard let engine = coordinator.activeEngine, engine.isModelLoaded else {
                let mode = AppSettings.shared.transcriptionEngine == "cloud" ? "Cloud" : "On-device"
                coordinator.lastError = "\(mode) transcription not ready — open Settings and select a model"
                NSLog("[MetaWhisp] ❌ Meeting transcribe: engine not ready (%@)", mode)
                return
            }
            NSLog("[MetaWhisp] Meeting transcribing via %@", engine.name)

            var fullText = ""
            let startTime = CFAbsoluteTimeGetCurrent()

            for (i, chunk) in chunks.enumerated() {
                let rms = TranscriptionCoordinator.calculateRMS(chunk)
                NSLog("[MetaWhisp] Meeting chunk %d/%d: %d samples, RMS=%.4f", i + 1, chunks.count, chunk.count, rms)

                // Skip chunks that are essentially silence — Whisper will hallucinate on them
                if rms < 0.0005 {
                    NSLog("[MetaWhisp] ⏭️  Chunk %d too quiet (RMS=%.5f), skipping", i + 1, rms)
                    continue
                }

                do {
                    let lang = AppSettings.shared.transcriptionLanguage == "auto" ? nil : AppSettings.shared.transcriptionLanguage
                    let result = try await engine.transcribe(audioSamples: chunk, language: lang, promptWords: ["MetaWhisp"])
                    let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }

                    // Apply the SAME hallucination filter the main coordinator uses.
                    // Whisper generates "Продолжение следует...", "Спасибо за просмотр", etc.
                    // on silence/noise — those must be filtered out.
                    if TranscriptionCoordinator.isAlwaysHallucination(text) {
                        NSLog("[MetaWhisp] ⚠️  Chunk %d: filtered always-hallucination: '%@'", i + 1, String(text.prefix(60)))
                        continue
                    }
                    if rms < 0.003, TranscriptionCoordinator.isHallucination(text) {
                        NSLog("[MetaWhisp] ⚠️  Chunk %d: filtered hallucination (RMS=%.4f): '%@'", i + 1, rms, String(text.prefix(60)))
                        continue
                    }

                    if !fullText.isEmpty { fullText += "\n\n" }
                    fullText += text
                } catch {
                    NSLog("[MetaWhisp] ❌ Meeting chunk %d failed: %@", i + 1, error.localizedDescription)
                }
            }

            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            let duration = Double(samples.count) / 16000.0

            guard !fullText.isEmpty else {
                NSLog("[MetaWhisp] Meeting transcription empty (all chunks silent or hallucinated)")
                meetingRecorder.lastError = "🎤 No speech detected in recording"
                return
            }

            // Save to history
            let result = TranscriptionResult(
                text: fullText,
                language: AppSettings.shared.transcriptionLanguage,
                duration: duration,
                processingTime: elapsed,
                segments: []
            )
            var meetingConvId: UUID? = nil
            if let item = historyService.save(result) {
                item.source = "meeting"
                item.modelName = AppSettings.shared.selectedModel
                // Assign to Conversation (C1.1) — grouper creates a dedicated completed conversation for the meeting.
                conversationGrouper.assign(historyItem: item)
                meetingConvId = item.conversationId
            }

            // Fire advice + memory + task triggers on meeting transcription (C1.3 — with conversationId FK).
            if fullText.count >= 20 {
                adviceService.triggerOnTranscription(text: fullText, source: "meeting")
                memoryExtractor.triggerOnTranscription(text: fullText, source: "meeting", conversationId: meetingConvId)
                taskExtractor.triggerOnTranscription(text: fullText, source: "meeting", conversationId: meetingConvId)
            }

            NSLog("[MetaWhisp] ✅ Meeting transcribed: %.0fs audio → %d words in %.1fs", duration, fullText.split(separator: " ").count, elapsed)
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // User may have changed permissions in System Settings — re-check everything
        PermissionsService.shared.refresh()

        // Re-start services that previously failed due to missing Screen Recording permission.
        // When user grants permission AFTER app launch and returns to the app, this catches that
        // transition and activates dependent services without requiring app restart.
        Task { @MainActor in
            // Give TCC a moment to settle after permission grant
            try? await Task.sleep(for: .milliseconds(500))

            let hasScreen = CGPreflightScreenCaptureAccess()

            if hasScreen && AppSettings.shared.screenContextEnabled && !screenContext.isActive {
                NSLog("[MetaWhisp] 🔄 Screen Recording granted — restarting ScreenContext monitor")
                screenContext.startMonitoring(interval: AppSettings.shared.screenContextInterval)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        NSLog("[MetaWhisp] Terminating")
    }

    /// Draw MW waveform logo programmatically for menu bar (template image).
    private static func createMWMenuBarIcon() -> NSImage {
        let w: CGFloat = 20
        let h: CGFloat = 14
        let img = NSImage(size: NSSize(width: w, height: h), flipped: true) { rect in
            let path = NSBezierPath()
            path.lineWidth = 1.8
            path.lineCapStyle = .round
            path.lineJoinStyle = .round

            // MW waveform shape — matches the logo
            // M: up-down-up  W: down-up-down
            let pts: [(CGFloat, CGFloat)] = [
                (1, 10),     // start bottom-left
                (3, 3),      // M peak 1
                (5.5, 8),    // M valley
                (8, 3),      // M peak 2 / center
                (10.5, 10),  // W valley 1
                (13, 4),     // W peak
                (15.5, 10),  // W valley 2
                (18, 3),     // end top-right
            ]

            path.move(to: NSPoint(x: pts[0].0, y: pts[0].1))
            // Use curve through points for smooth waveform
            for i in 1..<pts.count {
                let prev = pts[i - 1]
                let curr = pts[i]
                let cx1 = prev.0 + (curr.0 - prev.0) * 0.5
                let cx2 = prev.0 + (curr.0 - prev.0) * 0.5
                path.curve(to: NSPoint(x: curr.0, y: curr.1),
                           controlPoint1: NSPoint(x: cx1, y: prev.1),
                           controlPoint2: NSPoint(x: cx2, y: curr.1))
            }

            NSColor.black.setStroke()
            path.stroke()
            return true
        }
        img.isTemplate = true
        return img
    }

    // MARK: - URL Scheme Handler

    @objc private func handleURLEvent(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        guard let urlString = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: urlString),
              url.scheme == "metawhisp",
              url.host == "auth",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let token = components.queryItems?.first(where: { $0.name == "token" })?.value
        else {
            NSLog("[DeepLink] Invalid URL received")
            return
        }

        NSLog("[DeepLink] Received auth token: %@...", String(token.prefix(8)))
        Task {
            await LicenseService.shared.activate(token: token)
            // Show the main window so user sees their activated Pro status
            NSApp.activate(ignoringOtherApps: true)
            self.openMainWindow()
        }
    }
}
