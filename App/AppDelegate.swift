import AppKit
import Combine
import Foundation
import Sparkle
import SwiftData
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
    let embeddingService = EmbeddingService()
    let projectAggregator = ProjectAggregator()
    let chatToolExecutor = ChatToolExecutor()
    let proactiveContextService = ProactiveContextService()
    let liveMeetingAdvisor = LiveMeetingAdvisor()
    let dailySummaryService = DailySummaryService()
    let weeklyPatternDetector = WeeklyPatternDetector()
    let screenExtractor = ScreenExtractor()
    /// Realtime per-window task detector — reference-pattern proactive assistant (ITER-006).
    let realtimeScreenReactor = RealtimeScreenReactor()
    let fileIndexer = FileIndexerService()
    let fileMemoryExtractor = FileMemoryExtractor()
    let appleNotesReader = AppleNotesReaderService()
    let calendarReader = CalendarReaderService()
    let ttsService = TTSService()
    let floatingVoiceWindow = FloatingVoiceWindowController()
    var coordinator: TranscriptionCoordinator!
    let overlay = RecordingOverlayController()
    let mainWindow = MainWindowController()
    let onboardingWindow = OnboardingWindowController()
    var selectionTranslator: SelectionTranslator!
    var updaterController: SPUStandardUpdaterController!
    private var cancellables = Set<AnyCancellable>()

    // Call auto-detection state (ITER-002). Tracks whether the currently-active
    // recording was started by auto-detect — only then do we auto-stop on call end.
    private var autoRecordCountdownTask: Task<Void, Never>?
    private var didAutoStartRecording = false

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
        // Memory + task triggers on transcription.
        // AdviceService reference kept for backward compat (existing AdviceItem records shown in UI),
        // but periodic advice generation is disabled — replaced by TaskExtractor (spec://BACKLOG#B1).
        coordinator.adviceService = adviceService
        coordinator.memoryExtractor = memoryExtractor
        coordinator.taskExtractor = taskExtractor
        coordinator.conversationGrouper = conversationGrouper
        coordinator.chatService = chatService
        chatService.ttsService = ttsService
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
            projectAggregator: projectAggregator,
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
            onTranslateLongPress: { [weak self] in self?.selectionTranslator.translateSelection() },
            onVoiceQuestionStart: { [weak self] in self?.coordinator.startVoiceQuestion() },
            onVoiceQuestionStop: { [weak self] in self?.coordinator.stopVoiceQuestion() }
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
        // Call auto-detection hook (ITER-002): piggy-back on the existing window-polling loop.
        screenContext.onCallContext = { [weak self] callName in
            self?.handleCallContext(callName)
        }

        // ITER-012: layered defense against zombie meeting recordings. MeetingRecorder
        // can self-stop on silence or max-duration; route both back through the same
        // pipeline as a manual stop so transcription/extraction still runs.
        meetingRecorder.onAutoStop = { [weak self] reason in
            guard let self else { return }
            NSLog("[MeetingRecorder] Auto-stop fired: %@", String(describing: reason))
            NotificationService.shared.postMeetingAutoStopped(reason: reason)
            self.stopMeetingRecording()
        }
        // Realtime task reactor (ITER-006): fire LLM task classifier on each new ScreenContext.
        // Self-gated by settings toggle + debounce — wiring is fire-and-forget.
        realtimeScreenReactor.configure(modelContainer: historyService.modelContainer)
        realtimeScreenReactor.meetingRecorder = meetingRecorder
        screenContext.onContextPersisted = { [weak self] ctx in
            Task { @MainActor in
                await self?.realtimeScreenReactor.react(to: ctx)
                // ITER-015 — proactive chip evaluates the same context, gated hard
                // by settings / cooldown / blacklist / composing-intent inside.
                self?.proactiveContextService.onNewContext(ctx)
            }
        }
        if AppSettings.shared.screenContextEnabled {
            let interval = AppSettings.shared.screenContextInterval
            screenContext.startMonitoring(interval: interval)
        }

        // 9a. Configure MemoryExtractor + TaskExtractor — both trigger-based on voice transcription.
        // : voice transcript input, not periodic screen OCR polling.
        // spec://iterations/ITER-001#architecture.extractor + spec://BACKLOG#B1
        memoryExtractor.configure(screenContext: screenContext, modelContainer: historyService.modelContainer)
        taskExtractor.configure(screenContext: screenContext, modelContainer: historyService.modelContainer)

        // 9c. Configure ChatService (RAG over memories + transcripts + tasks + screen OCR).
        // spec://BACKLOG#B2 + spec://iterations/ITER-003-screen-aware-intelligence#scope.1
        chatService.configure(modelContainer: historyService.modelContainer)
        chatService.screenContext = screenContext
        // ITER-014 — let MetaChat see active project clusters via <active_projects>.
        chatService.projectAggregator = projectAggregator
        // ITER-016 — wire tool executor for conversational mutation.
        // ITER-017 v3 — also pass embeddingService so search* read-only tools rank semantically.
        chatToolExecutor.configure(
            modelContainer: historyService.modelContainer,
            embeddingService: embeddingService
        )
        chatService.toolExecutor = chatToolExecutor

        // 9d. Configure ConversationGrouper (C1.1) + StructuredGenerator (C1.2).
        // Grouper fires StructuredGenerator + extractors on conversation close.
        conversationGrouper.configure(modelContainer: historyService.modelContainer)
        structuredGenerator.configure(modelContainer: historyService.modelContainer)
        // Wire embedding so StructuredGenerator embeds each closed conversation
        // right after title/overview populate (ITER-011).
        structuredGenerator.embeddingService = embeddingService
        // Wire project aggregator so StructuredGenerator seeds ProjectAlias rows
        // on close (ITER-014).
        structuredGenerator.projectAggregator = projectAggregator
        // Wire calendar reader so StructuredGenerator links closed conversations
        // to matching EKEvents (ITER-018). Linker is no-op when calendar is OFF.
        structuredGenerator.calendarReader = calendarReader

        // One-time backfill on launch + periodic 30-min sweep (ITER-021).
        // Launch covers conversations that closed before the app was running;
        // periodic catches anything that closes WHILE the app is up but the
        // proxy was briefly unavailable. Together they make "Quick note" stuck
        // forever impossible.
        Task { @MainActor [weak self] in
            await self?.structuredGenerator.backfillPlaceholders()
            self?.structuredGenerator.startPeriodicBackfill()
        }

        // 9d+. Embedding service (ITER-008 + ITER-011) — semantic RAG + dedup for Pro users.
        embeddingService.configure(modelContainer: historyService.modelContainer)

        // ITER-015 — Proactive context service. Configured after embedding service
        // so it can do semantic retrieval when the chip evaluates relevance.
        proactiveContextService.configure(
            modelContainer: historyService.modelContainer,
            embeddingService: embeddingService
        )

        // ITER-014 — Project aggregator. Backfills primaryProject for legacy completed
        // conversations + runs an embedding-similarity merge pass after backfill so
        // "Overchat"/"Оверчат"/"OverchatAI" collapse to one canonical row.
        projectAggregator.configure(modelContainer: historyService.modelContainer)
        Task { @MainActor [weak self] in
            // Wait longer than the embeddings backfill so the centroid pass below has
            // vectors to work with.
            try? await Task.sleep(for: .seconds(15))
            await self?.projectAggregator.backfillProjects(structuredGenerator: self?.structuredGenerator ?? StructuredGenerator())
            await self?.projectAggregator.mergeAliases()
        }
        Task { @MainActor [weak self] in
            // Small delay so initial app launch isn't slowed by the backfill LLM calls.
            try? await Task.sleep(for: .seconds(3))
            await self?.embeddingService.backfillMissing()
        }

        // 9d++. Daily summary (ITER-009) — nightly recap with scheduled delivery.
        dailySummaryService.configure(modelContainer: historyService.modelContainer)
        if AppSettings.shared.dailySummaryEnabled {
            dailySummaryService.startScheduler()
        }

        // ITER-022 G5 — Weekly cross-conversation pattern digest. Sunday wall-clock
        // scheduler ticks every 5 min; fires once per week.
        weeklyPatternDetector.configure(modelContainer: historyService.modelContainer)
        if AppSettings.shared.weeklyPatternsEnabled {
            weeklyPatternDetector.startScheduler()
        }

        // One-time migration for Staged Tasks (ITER-007):
        // Before this rollout all screen-inferred tasks landed in the main Tasks list
        // and produced noise. Move active screen-origin tasks into the "staged" bin so
        // they surface in REVIEW CANDIDATES and the user decides per-item.
        // Fetch filter kept simple (predicate can't mix Optional nil-checks w/o tripping
        // the type checker); refine in memory.
        Task { @MainActor in
            let ctx = ModelContext(historyService.modelContainer)
            let desc = FetchDescriptor<TaskItem>(
                predicate: #Predicate<TaskItem> { !$0.isDismissed }
            )
            guard let all = try? ctx.fetch(desc) else { return }
            let candidates = all.filter {
                $0.screenContextId != nil && ($0.status == nil || $0.status == "committed")
            }
            guard !candidates.isEmpty else { return }
            for task in candidates {
                task.status = "staged"
                task.updatedAt = Date()
            }
            try? ctx.save()
            NSLog("[AppDelegate] Migrated %d existing screen-origin tasks → staged", candidates.count)
        }

        // Periodic sweep: close dictation conversations idle past the gap (10 min) so
        // extractors fire even if the user doesn't dictate again. Cheap — single
        // SwiftData fetch every 60s.
        Task { @MainActor [weak self] in
            while true {
                try? await Task.sleep(for: .seconds(60))
                self?.conversationGrouper.closeStaleConversations()
            }
        }

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
            // ITER-018 — backfill calendar links for completed conversations
            // that landed before the linker existed. Bounded to last 90 days.
            // Delayed so embeddings + projects backfills run first; this is the
            // lowest-priority pass.
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(25))
                await self?.calendarReader.backfillCalendarLinks()
            }
        }

        // 9b. Configure AdviceService (kept for legacy AdviceItem display in UI only).
        // Periodic advice generation disabled — replaced by TaskExtractor.
        // spec://BACKLOG#B1
        adviceService.configure(screenContext: screenContext, modelContainer: historyService.modelContainer)
        // ITER-022 G3 — wire embedding service so memories are semantically ranked
        // against the current screen context before being fed to the advice prompt.
        adviceService.embeddingService = embeddingService

        // ITER-019 — Live advice during meeting recording. Auto-arms via Combine
        // subscription on `meetingRecorder.$isRecording`; auto-disarms on stop.
        // No-op when settings.liveMeetingAdviceEnabled == false.
        liveMeetingAdvisor.configure(
            meetingRecorder: meetingRecorder,
            coordinator: coordinator,
            adviceService: adviceService
        )

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
                    // Periodic advice generation retired — TaskExtractor replaces it.
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

    // MARK: - Call auto-detection (ITER-002)

    /// Called by `ScreenContextService.onCallContext` on **state transitions** only:
    /// - `name != nil` → call started (fired once when user opens Zoom / joins Meet tab)
    /// - `name == nil` → call ended (user left the tab / closed Zoom window)
    ///
    /// **BUG FIX (2026-04-21):** window-title transitions are unreliable DURING an active call.
    /// Tab-switching (Meet → Slack → Meet → Notes → Meet) produces a flurry of `nil` / `callName`
    /// transitions, which the old code treated as repeated call-end + call-start events.
    /// Result: 4 duplicate recordings for 1 real call. Each stop+start cycle created a new
    /// `HistoryItem` in the database with a fresh start time (e.g. second call showing 9:13
    /// instead of 9:00 because it was the *third* restart, not the real beginning).
    ///
    /// **Fix:** once auto-detect has committed to the current call (countdown running OR
    /// recording started), LOCK the decision — ignore all further window transitions. The
    /// recording ends only when the user manually stops it, which resets the lock via
    /// `stopMeetingRecording()` → clears both `didAutoStartRecording` and the countdown task.
    ///
    /// Phase 2 (tracked separately): replace "manual stop only" with audio-silence heuristic
    /// — if `meetingRecorder.audioLevel` stays below a threshold for N minutes, auto-stop.
    ///
    /// Respects the 2 settings toggles:
    /// - `autoDetectCalls` — post notification on start
    /// - `callsAutoStartEnabled` — also auto-start recording after 5 s
    private func handleCallContext(_ callName: String?) {
        // Master gate: feature off → ignore.
        guard AppSettings.shared.meetingRecordingEnabled,
              AppSettings.shared.autoDetectCalls
        else { return }

        // LOCK: auto-detect already committed (countdown pending OR recording active).
        // Any window-title change is now noise — don't stop, don't start again.
        // Released when `stopMeetingRecording()` clears both fields.
        let autoInFlight = (autoRecordCountdownTask != nil) || didAutoStartRecording
        if autoInFlight {
            NSLog("[CallDetect] Locked (auto in flight) — ignoring transition: %@",
                  callName ?? "nil")
            return
        }

        if let callName {
            // --- CALL STARTED (first detection — no auto flight yet) ---

            // Skip if user is already recording (manual or prior auto).
            let alreadyRecording = meetingRecorder.isRecording
                || meetingRecorder.isStarting
                || recorder.isRecording
            if alreadyRecording {
                NSLog("[CallDetect] %@ detected but already recording — skip", callName)
                return
            }

            let autoStart = AppSettings.shared.callsAutoStartEnabled
            NotificationService.shared.postCallDetected(appName: callName, autoStart: autoStart)

            guard autoStart else { return }

            // 5 s countdown → start recording. The `autoRecordCountdownTask != nil` check
            // above now acts as a lock: any further transition won't cancel it, preventing
            // the user from losing the countdown by tab-switching in the first 5s.
            autoRecordCountdownTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, let self else { return }
                // Re-check manual-recording state at fire time.
                guard !self.meetingRecorder.isRecording,
                      !self.meetingRecorder.isStarting,
                      !self.recorder.isRecording
                else {
                    NSLog("[CallDetect] Countdown fired but user started recording manually — skip")
                    return
                }
                NSLog("[CallDetect] ▶️ Auto-start recording for %@", callName)
                self.didAutoStartRecording = true
                self.meetingRecorder.start()
                // Countdown done — task can be nil'd but didAutoStartRecording keeps the lock.
                self.autoRecordCountdownTask = nil
            }
        } else {
            // --- CALL ENDED transition ---
            // ITER-012: previously this branch did nothing for manual recordings,
            // which produced the 7-hour zombie scenario when the user manually
            // started a recording during a call and never stopped it. Now: if a
            // recording is active when the call ends, stop it.
            //
            // Safety: this fires ONLY on a true window-title transition away from
            // a call window (debounced at source in ScreenContextService). Random
            // tab switches don't trigger it because detectCallContext keeps
            // returning the call name as long as the meet window stays active.
            if meetingRecorder.isRecording || meetingRecorder.isStarting {
                NSLog("[CallDetect] ⏹ Call ended — auto-stopping active recording")
                NotificationService.shared.postMeetingAutoStopped(reason: .callEnded)
                stopMeetingRecording()
            } else {
                NSLog("[CallDetect] Pre-commit nil transition — no recording to stop")
            }
        }
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

    /// ITER-012: builds the per-meeting recap notification ~8s after the meeting
    /// stops. By that point StructuredGenerator + extractors have usually finished;
    /// even if title/overview are still empty we send a minimal recap with counts.
    /// Click → opens Library tab.
    private func fireMeetingRecap(for conversationId: UUID) {
        let ctx = ModelContext(historyService.modelContainer)

        // Look up the conversation.
        var convDesc = FetchDescriptor<Conversation>(
            predicate: #Predicate { $0.id == conversationId }
        )
        convDesc.fetchLimit = 1
        let conv = (try? ctx.fetch(convDesc))?.first

        // Count linked tasks (committed only — staged candidates aren't user-confirmed).
        let taskDesc = FetchDescriptor<TaskItem>(
            predicate: #Predicate { $0.conversationId == conversationId && !$0.isDismissed }
        )
        let allTasks = (try? ctx.fetch(taskDesc)) ?? []
        let taskCount = allTasks.filter { $0.status != "staged" && $0.status != "dismissed" }.count

        // Count linked memories.
        let memDesc = FetchDescriptor<UserMemory>(
            predicate: #Predicate { $0.conversationId == conversationId && !$0.isDismissed }
        )
        let memoryCount = (try? ctx.fetch(memDesc).count) ?? 0

        let title = conv?.title ?? ""
        let overview = conv?.overview ?? ""
        NotificationService.shared.postMeetingRecap(
            title: title,
            overview: overview,
            taskCount: taskCount,
            memoryCount: memoryCount,
            conversationId: conversationId
        )
    }

    private func stopMeetingRecording() {
        // Reset auto-detect flag — any follow-up manual recording starts from a clean slate.
        // Without this a subsequent manual recording would be auto-stopped on the next call-end event.
        didAutoStartRecording = false
        autoRecordCountdownTask?.cancel()
        autoRecordCountdownTask = nil

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
            if let item = historyService.save(result) {
                item.source = "meeting"
                item.modelName = AppSettings.shared.selectedModel
                // Assign to Conversation (C1.1) — grouper creates a dedicated completed
                // conversation for the meeting and fires scheduleOnClose (structured gen +
                // memory + task extractors) automatically.
                conversationGrouper.assign(historyItem: item)

                // ITER-012: per-meeting recap notification. Wait long enough for
                // StructuredGenerator (300ms delay → LLM ≈ 3-5s) and the per-transcript
                // extractors to populate, then summarise into a notification.
                if AppSettings.shared.meetingRecapNotifications,
                   let conversationId = item.conversationId {
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(for: .seconds(8))
                        self?.fireMeetingRecap(for: conversationId)
                    }
                }
            }

            // AdviceService stays per-transcript (it's a real-time signal — user dictates,
            // advice surfaces immediately). Memory + Task extractors now run on conversation
            // close automatically via ConversationGrouper.scheduleOnClose — meetings close
            // on creation (single-shot), so extraction fires there too.
            if fullText.count >= 20 {
                adviceService.triggerOnTranscription(text: fullText, source: "meeting")
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
