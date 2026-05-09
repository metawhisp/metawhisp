import AppKit
import Combine
import Foundation
import Sparkle
import SwiftData
import SwiftUI
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
    /// Top-level mic capture — used by dictation (Right ⌘ short tap) and
    /// voice question (long-press). Independent AVAudioEngine.
    let recorder = AudioRecordingService()
    let systemAudioCapture = SystemAudioCaptureService()
    /// Dedicated mic capture for meeting recording. SEPARATE instance from
    /// `recorder` — sharing one AudioRecordingService caused 3 cascading bugs:
    /// (a) voice-question received the WHOLE meeting buffer (15 min, ~950s);
    /// (b) `recorder.stop()` on voice-question release killed the AVAudioEngine,
    ///     so the meeting captured 0 mic samples for the rest of the call;
    /// (c) MeetingCoach repeatedly asked "Turn on microphone" because the mic
    ///     literally went silent mid-meeting after the user did a voice question.
    /// Each AudioRecordingService owns its own AVAudioEngine — multiple
    /// engines tapping the default input device coexist fine.
    private let meetingMic = AudioRecordingService()
    /// Captures mic + system audio in parallel for meeting recording.
    lazy var meetingRecorder = MeetingRecorder(mic: meetingMic, systemAudio: systemAudioCapture)
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
    /// ITER-027 — produces ONE actionable insight per evaluation tick
    /// (replaces cosine-retrieval list of related conversations). Wired
    /// into `proactiveContextService` so the existing `onNewContext` hook
    /// fires it under the same gates (composing app, OCR ≥ 80 chars, …).
    let insightAssistantService = InsightAssistantService()
    let liveMeetingAdvisor = LiveMeetingAdvisor()
    let dailySummaryService = DailySummaryService()
    let weeklyPatternDetector = WeeklyPatternDetector()
    let screenExtractor = ScreenExtractor()
    /// Realtime per-window task detector — reference-pattern proactive assistant (ITER-006).
    let realtimeScreenReactor = RealtimeScreenReactor()
    let fileIndexer = FileIndexerService()
    let fileMemoryExtractor = FileMemoryExtractor()
    let appleNotesReader = AppleNotesReaderService()
    let obsidianSync = ObsidianSyncService()
    let calendarReader = CalendarReaderService()
    let ttsService = TTSService()
    let floatingVoiceWindow = FloatingVoiceWindowController()
    /// Meeting Copilot overlay controller (ITER-019.2). Subscribes to
    /// `MeetingCoachState.shared.$isVisible` at init and shows/hides the
    /// floating panel automatically — no further wiring needed.
    let meetingCoachWindow = MeetingCoachWindowController()
    /// Per-meeting Recap popup controller (2026-04-29). Subscribes to
    /// `MeetingRecapState.shared.$isVisible` at init.
    let meetingRecapWindow = MeetingRecapWindowController()
    /// In-app notification stack — replaces both macOS-native UN banners and
    /// the standalone ProactiveChip window. Single Liquid Glass design, max
    /// 4 cards, top-right. Auto-shows when items appear, hides when empty.
    let notificationStackController = MWNotificationStackController()
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

    /// Single source of truth for the active call session detected via window
    /// title. Replaces the old `lastCallContext` / `didAutoStartRecording`
    /// scatter. Lifecycle in `CallSessionMachine`.
    var currentCallSession: CallSession?
    private var didAutoStartRecording = false
    /// Debounce for callEnded: when callContext flips to nil, wait this long
    /// before actually firing stop. Cancelled if callContext returns. Avoids
    /// premature stops on a brief tab-switch while still catching real call
    /// ends. Default 60s — see `armCallEndedDebounce`.
    private var callEndedDebounceTask: Task<Void, Never>?
    /// ITER-034 (2026-05-08) — calendar-end-aware auto-stop. When a
    /// recording starts via `.calendarReady(name, eventID)`, we schedule a
    /// task to fire at `EKEvent.endDate + grace` and run
    /// `CalendarEndStopDecision.evaluate(...)`. Outcomes: stop now, notify
    /// + extend, or hard stop after too many notifies. Cleared on
    /// `stopMeetingRecording`. Replaces the never-implemented earlier slot.
    private var calendarHardStopTask: Task<Void, Never>?
    /// Counter for `notifyAndExtend` rounds. Reset on each new recording.
    private var calendarEndNotifyAttempts: Int = 0
    /// Fast 1-sec polling loop for `MeetingAutoStartGate`. Samples frontmost
    /// window state, audio level, calendar events; feeds to gate; on
    /// `.fallbackReady` / `.calendarReady` runs the countdown + audio-sniff
    /// → start recording flow. Runs only when no recording is active.
    /// spec://iterations/ITER-026-v2-meeting-auto-start
    private var meetingAutoStartTickTask: Task<Void, Never>?
    /// True while the 5-sec countdown plashka is up. Prevents the fast tick
    /// loop from re-firing the gate while a countdown is already running.
    private var meetingCountdownInFlight = false
    /// ITER-028.2 (2026-05-06) — calendar `EKEvent.eventIdentifier` captured
    /// at the moment the current recording started. Used by the fast-tick
    /// loop together with `BackToBackTransition.decide(...)` to detect when
    /// the user transitioned from calendar event A to calendar event B.
    /// `nil` for fallback/manual recordings — those don't have a comparable
    /// calendar baseline, so back-to-back logic skips them.
    ///
    /// Replaces the previous `recordingFrontmostTitle` window-title heuristic
    /// which misfired daily because Google Meet tab titles mutate from
    /// generic to specific in the first ~1s after page mount. See
    /// `specs/health-reports/2026-05-05.md` and `2026-05-06-morning.md` for
    /// the 100% kill rate that motivated this rewrite.
    private var recordingCalendarEventID: String?
    /// Display name of the call context that was detected when the current
    /// meeting recording started ("Google Meet", "Zoom"). Used by
    /// `ConversationGrouper.assign(...)` at close so a lid-bounce reopens the
    /// SAME conversation instead of fragmenting one real call into N rows.
    /// Set on auto-start path; nil when user pressed RECORD manually.
    private var currentMeetingCallContext: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self
        FileLogger.setup()

        // Apply saved theme
        MW.applyTheme(AppSettings.shared.appTheme)

        // Re-read launch-at-login status. The user could have flipped the
        // registration from System Settings → General → Login Items while the
        // app was off; reading here ensures the Settings toggle reflects
        // reality on first open of this session.
        LaunchAtLoginManager.shared.updateStatus()

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

        // ITER-026 v2 — fast 1-sec polling loop drives `MeetingAutoStartGate`.
        // Gate requires `frontmost + fullscreen` sustained 10s before
        // proposing auto-start; replaces the old "first detect → 5s countdown
        // → start" path which fired on any single tick that matched.
        startMeetingAutoStartTickLoop()

        // ITER-012: layered defense against zombie meeting recordings. MeetingRecorder
        // can self-stop on silence or max-duration; route both back through the same
        // pipeline as a manual stop so transcription/extraction still runs.
        meetingRecorder.onAutoStop = { [weak self] reason in
            guard let self else { return }
            NSLog("[MeetingRecorder] Auto-stop fired: %@", String(describing: reason))
            NotificationService.shared.postMeetingAutoStopped(reason: reason)
            self.stopMeetingRecording(reason: "recorder-auto-stop:\(reason)")
        }
        // ITER-026 v2 — manual recordings get a non-blocking 2h reminder
        // instead of auto-stop. Card just informs; recording continues until
        // the user presses STOP.
        meetingRecorder.onManualHeartbeat = { [weak self] in
            guard let self, self.meetingRecorder.isRecording else { return }
            let note = MWNotification(
                kind: .recordingStopped,
                title: "Recording: 2 hours elapsed",
                body: "Manual recording is still going. Tap × if you want to keep it running.",
                onTap: nil  // tap doesn't stop — manual mode requires explicit STOP
            )
            MWNotificationStack.shared.push(note)
            // Re-arm so the card fires again every 2h until user stops.
            // Implemented by armManualHeartbeat reset on next start; for now
            // this is one-shot. Most manual recordings end well before the
            // second 2h mark anyway.
            _ = self  // keep weak-self happy for the closure
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

        // ITER-026 — one-time cleanup of calendar-derived TaskItems. The old
        // CalendarReaderService.scanNow pipeline turned every upcoming event
        // into a "task" (~10/day at this user's density), polluting chat
        // context for weeks. The pipeline is gone; here we dismiss whatever
        // it left behind so the user doesn't have to bulk-clean by hand.
        Task { @MainActor [weak self] in
            self?.migrateCalendarTasksOnce()
            self?.migrateSilenceStopMinutesOnce()
        }

        // ITER-027 — Proactive context service is now powered by the
        // InsightAssistantService (LLM-based insight extraction) instead
        // of cosine retrieval. embeddingService is no longer a dependency
        // here — it's still used elsewhere (MetaChat RAG, project clustering).
        proactiveContextService.configure(
            modelContainer: historyService.modelContainer,
            insightAssistant: insightAssistantService
        )

        // ITER-014 — Project aggregator. Backfills primaryProject for legacy completed
        // conversations + runs an embedding-similarity merge pass after backfill so
        // "ChatApp"/"ЧатЭп"/"ChatAppAI" collapse to one canonical row.
        projectAggregator.configure(modelContainer: historyService.modelContainer)
        Task { @MainActor [weak self] in
            // Wait longer than the embeddings backfill so the centroid pass below has
            // vectors to work with.
            try? await Task.sleep(for: .seconds(15))
            guard let self else { return }
            await self.projectAggregator.backfillProjects(structuredGenerator: self.structuredGenerator)
            await self.projectAggregator.mergeAliases()
            // ITER-032.2 (2026-05-08) — one-shot curative pass that
            // reclassifies conversations tagged with hallucinated/typo
            // project names, then re-picks canonical-by-conversation-count,
            // then prunes orphan aliases. Runs once per major version bump
            // (gated by `@AppStorage` flag); future launches no-op.
            if !AppSettings.shared.didCurativePass_iter032_2 {
                NSLog("[ProjectAggregator] curative pass — first run after upgrade")
                _ = await self.projectAggregator.curativePass(generator: self.structuredGenerator)
                AppSettings.shared.didCurativePass_iter032_2 = true
            }
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

        // 9g.1 Configure ObsidianSync (2026-04-28). Outbound: appends new
        // memories to <vault>/MetaWhisp/Journal.md so they propagate into
        // the user's broader Obsidian-based knowledge graph.
        obsidianSync.configure(modelContainer: historyService.modelContainer)
        if AppSettings.shared.obsidianSyncEnabled {
            obsidianSync.startPeriodic()
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
        // MeetingCoach needs the model container to look up UserMemory entries
        // when entities mentioned in the live transcript match prior memories.
        // Lets the LLM produce L5 cross-context suggestions instead of just L2.
        MeetingCoachService.shared.configure(modelContainer: historyService.modelContainer)

        // ITER-026 — notifications now render in-app via `MWNotificationStack`
        // (Liquid Glass cards, top-right). No OS permission needed; the
        // previous UN-based authorization probe is gone.

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
    /// - `name != nil` → call started (fired once when ANY visible window matches a call pattern)
    /// - `name == nil` → no call window anywhere — does NOT stop recording
    ///
    /// **ITER-026 (2026-05-02):** ScreenContextService now scans ALL on-screen windows
    /// (not just the frontmost) to compute `currentCall`. When the user tabs away from
    /// the meeting tab to Slack/Notion/docs the call signal stays alive because the
    /// meeting tab is still on-screen behind. Auto-stop on `name == nil` was removed
    /// entirely — `MeetingRecorder.armSilenceGuard` (10 min < threshold RMS) is the
    /// canonical audio-truth signal for "meeting really ended". Window-loss only
    /// resets `CallSessionMachine` after a 60s grace period so a brief window-list
    /// flicker doesn't fragment the session.
    ///
    /// Respects the 2 settings toggles:
    /// - `autoDetectCalls` — post notification on start
    /// - `callsAutoStartEnabled` — also auto-start recording after 5 s
    private func handleCallContext(_ callName: String?) {
        // Master gate: feature off → ignore.
        guard AppSettings.shared.meetingRecordingEnabled,
              AppSettings.shared.autoDetectCalls
        else { return }

        if let callName {
            // Cancel any pending end-of-session debounce — call context returned
            // before the 180s window expired, so this was just a brief app-switch.
            if callEndedDebounceTask != nil {
                NSLog("[CallDetect] callContext returned — cancelling pending end-of-session debounce")
                callEndedDebounceTask?.cancel()
                callEndedDebounceTask = nil
            }

            // Skip if user is already recording — no notification needed,
            // they're committed.
            let alreadyRecording = meetingRecorder.isRecording
                || meetingRecorder.isStarting
                || recorder.isRecording
            if alreadyRecording {
                NSLog("[CallDetect] %@ detected but already recording — skip", callName)
                return
            }

            // Pure state-machine: decides notify vs suppress. Single source of
            // truth replaces the old autoInFlight + didAutoStartRecording locks.
            let autoStart = AppSettings.shared.callsAutoStartEnabled
            let (newSession, decision) = CallSessionMachine.onDetect(
                name: callName,
                current: currentCallSession,
                autoStartEnabled: autoStart
            )
            currentCallSession = newSession

            switch decision {
            case .suppressDuplicate:
                NSLog("[CallDetect] %@ already announced this session — suppress (1 call = 1 notify)", callName)
                return
            case .suppressBecauseDeclined:
                NSLog("[CallDetect] %@ user declined recording for this session — suppress (no auto-restart)", callName)
                return
            case let .fireNotify(name, armCountdown):
                // ITER-026 v2 — info-only "call detected" notification. Auto-start
                // is now governed by `MeetingAutoStartGate` via the fast tick
                // loop in `runMeetingAutoStartTick`. The gate requires
                // `frontmost + fullscreen` sustained for 10 seconds before
                // firing so a leftover Meet tab can never trigger a recording.
                NotificationService.shared.postCallDetected(appName: name, autoStart: armCountdown)
                if armCountdown {
                    NSLog("[CallDetect] %@ detected — gate now monitoring for sustained signal (10s frontmost+fullscreen)", name)
                }
            }
        } else {
            // ITER-026 — callContext=nil after multi-window scan = NO call
            // window visible anywhere on screen. We do NOT auto-stop the
            // recording on this signal alone. User explicit feedback
            // 2026-05-02: "то что сейчас в окне нету записи, это не значит,
            // что записи нет — есть еще другие факторы (звук), которые
            // говорят что запись идёт".
            //
            // Recording stop responsibilities now sit cleanly in two places:
            //   - `MeetingRecorder.armSilenceGuard` — stops when audioLevel <
            //     `silenceRMSThreshold` for `meetingSilenceStopMinutes` (10
            //     min default). That's the audio-truth signal.
            //   - `MeetingRecorder.armMaxDurationGuard` — hard cap (4h
            //     default).
            // Window-scan loss only resets the call-session state machine so
            // a new call with the same app name later isn't suppressed as a
            // duplicate. We schedule a generous 60s grace period for that
            // reset so a momentary window-list flicker doesn't fragment the
            // session.
            guard currentCallSession != nil else { return }
            guard callEndedDebounceTask == nil else {
                NSLog("[CallDetect] Session-end grace already armed — ignoring duplicate nil transition")
                return
            }
            NSLog("[CallDetect] No call window across all desktops — arming 60s session-end grace (no recording stop)")
            callEndedDebounceTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled, let self else { return }
                self.currentCallSession = CallSessionMachine.onSessionEnd(self.currentCallSession)
                self.callEndedDebounceTask = nil
                NSLog("[CallDetect] Session cleared after 60s grace (recording untouched — silence guard owns stop)")
            }
        }
    }

    /// Toggle meeting recording (mic + system audio together → transcription).
    func toggleMeetingRecording() {
        // Clear stale error so UI updates cleanly on retry
        meetingRecorder.lastError = nil
        systemAudioCapture.lastError = nil

        if meetingRecorder.isRecording || meetingRecorder.isStarting {
            stopMeetingRecording(reason: "user-toggle")
        } else {
            startMeetingRecording()
        }
    }

    private func startMeetingRecording() {
        // MeetingRecorder handles mic + system audio in parallel.
        // Errors surface via meetingRecorder.lastError (shown in popover).
        // ITER-026 v2 — `manualMode: true` because this path is the user's
        // explicit RECORD action (menu bar / hotkey). No silence/maxDuration
        // auto-stops; just a 2h heartbeat card.
        meetingRecorder.start(manualMode: true)
        NSLog("[MetaWhisp] ▶️ Meeting recording start requested (manual mode)")

        // Calendar-based auto-stop was REMOVED 2026-04-29 — meetings routinely
        // overrun their scheduled end (a 30-min meeting going 50 min is normal),
        // and the 5-minute buffer kept firing premature stops. The silence
        // detector (1 min < 0.025 RMS) handles "meeting actually ended" much
        // more reliably without depending on calendar accuracy. callEnded
        // debounce + maxDuration cap remain as the other safety nets.
        calendarHardStopTask?.cancel()
        calendarHardStopTask = nil
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

        // Tasks linked to this conversation — committed only.
        let taskDesc = FetchDescriptor<TaskItem>(
            predicate: #Predicate { $0.conversationId == conversationId && !$0.isDismissed }
        )
        let allTasks = (try? ctx.fetch(taskDesc)) ?? []
        let activeTasks = allTasks.filter { $0.status != "staged" && $0.status != "dismissed" }
        let taskCount = activeTasks.count

        // Memories linked.
        let memDesc = FetchDescriptor<UserMemory>(
            predicate: #Predicate { $0.conversationId == conversationId && !$0.isDismissed }
        )
        let memories = (try? ctx.fetch(memDesc)) ?? []
        let memoryCount = memories.count

        // Title priority: CALENDAR EVENT first (when CalendarReader linked the
        // meeting to an EKEvent), else LLM summary title. User wants the
        // calendar-event name as primary — the LLM "Acme Chat Updates" /
        // "Quick note" fallbacks were noise compared to the actual event.
        let title: String = {
            if let cal = conv?.calendarEventTitle?.trimmingCharacters(in: .whitespaces),
               !cal.isEmpty {
                return cal
            }
            return conv?.title ?? ""
        }()
        let overview = conv?.overview ?? ""

        // Transcript = concatenation of HistoryItems for this conversation.
        let histDesc = FetchDescriptor<HistoryItem>(
            predicate: #Predicate { $0.conversationId == conversationId }
        )
        let hist = (try? ctx.fetch(histDesc)) ?? []
        let transcript = hist.sorted { $0.createdAt < $1.createdAt }
            .map { $0.text }.joined(separator: "\n\n")

        let durationSec: Double = {
            if let finished = conv?.finishedAt, let started = conv?.startedAt {
                return finished.timeIntervalSince(started)
            }
            return 0
        }()

        // ─── RECAP DURATION GATE ─────────────────────────────────────────
        // Skip only if duration < 60s (ghost auto-start/stop loops). Fallback
        // titles ("Meeting" / "Quick note") used to suppress here too — that
        // was wrong: user wants to see SOMETHING after every real call, even
        // if the LLM didn't have enough text to invent a great title.
        // Always surface the recap, trust the user to glance at it.
        guard durationSec >= 60 else {
            NSLog("[MeetingRecap] suppressed — duration %.0fs below 60s threshold", durationSec)
            return
        }
        // ───────────────────────────────────────────────────────────────────

        // Surface: in-app Recap popup (if the toggle is on). The previous
        // "macOS banner + recap window" pair double-notified the user about
        // the same event and was the loudest visual overlap in the top-right
        // corner — dropped per ITER-026 unification. The Recap window itself
        // is the canonical surface for finished meetings.
        if AppSettings.shared.meetingRecapPopupEnabled, let conv {
            let actionItems: [MeetingRecapState.ActionItem] = activeTasks.map { t in
                MeetingRecapState.ActionItem(
                    id: t.id, description: t.taskDescription,
                    assignee: t.assignee, completed: t.completed
                )
            }
            let memoryRows: [MeetingRecapState.MemoryRow] = memories.map { m in
                MeetingRecapState.MemoryRow(
                    id: m.id, kind: m.kind, subject: m.subject,
                    characterization: m.characterization, content: m.content
                )
            }

            // Decode StructuredGenerator's structured fields (ITER-021).
            // These ARE generated and saved to ZCONVERSATION but recap UI
            // wasn't reading them — leaving the popup with just ABOUT and
            // huge empty space. See `MeetingRecapState.Payload` doc for
            // 2026-05-01 user report.
            let participants: [String] = {
                // Calendar attendees first (objective list from EKEvent),
                // fall back to LLM-extracted participants from transcript.
                if let raw = conv.calendarAttendeesJSON,
                   let names = Self.decodeStringArray(raw), !names.isEmpty {
                    return names
                }
                if let raw = conv.participantsJSON,
                   let names = Self.decodeStringArray(raw) {
                    return names
                }
                return []
            }()
            let decisions = (conv.decisionsJSON.flatMap(Self.decodeStringArray)) ?? []
            let nextSteps = (conv.nextStepsJSON.flatMap(Self.decodeStringArray)) ?? []

            let payload = MeetingRecapState.Payload(
                conversationId: conversationId,
                emoji: conv.emoji,
                title: title.isEmpty ? "Meeting" : title,
                overview: overview,
                durationSec: durationSec,
                language: AppSettings.shared.transcriptionLanguage,
                calendarEventTitle: conv.calendarEventTitle,
                participants: participants,
                decisions: decisions,
                nextSteps: nextSteps,
                actionItems: actionItems,
                memories: memoryRows,
                transcript: transcript
            )
            MeetingRecapState.shared.present(payload)
        }

        // Per-meeting Obsidian markdown + calendar event notes patch.
        // Self-contained — no-op if Obsidian sync isn't enabled.
        Task { @MainActor [weak self] in
            guard let self else { return }
            await MeetingObsidianWriter.shared.write(
                conversationId: conversationId,
                modelContainer: self.historyService.modelContainer
            )
        }
    }

    /// Switches the main window to the Library → Conversations tab and
    /// surfaces the matching conversation. Called by the Recap popup's
    /// "Open in Library" button. Uses the existing `openConversation`
    /// notification (defined in `MainWindowController`) for deep-linking.
    func openConversationInLibrary(id: UUID) {
        mainWindow.open(
            coordinator: coordinator,
            modelManager: modelManager,
            recorder: recorder,
            historyService: historyService,
            projectAggregator: projectAggregator,
            initialTab: .library
        )
        // Slight delay so the Library view has time to mount before we tell
        // it which conversation to expand.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            NotificationCenter.default.post(
                name: .openConversation,
                object: id
            )
        }
    }

    /// Stops the active meeting recording. The `reason` is logged so
    /// post-mortems can tell apart user-tap, back-to-back, silence guard,
    /// 2h heartbeat, etc. without guessing from log neighbours
    /// (ITER-028.1, 2026-05-06 — every previous "why did the recording
    /// stop after 86s" question required cross-grepping).
    private func stopMeetingRecording(reason: String) {
        NSLog("[MetaWhisp] ▶️ stopMeetingRecording reason=%@", reason)
        // Reset auto-detect flag — any follow-up manual recording starts from a clean slate.
        // Without this a subsequent manual recording would be auto-stopped on the next call-end event.
        didAutoStartRecording = false
        autoRecordCountdownTask?.cancel()
        autoRecordCountdownTask = nil
        // ITER-028.2 — clear calendar event baseline so the next recording
        // captures its own. (Replaced the old `recordingFrontmostTitle` clear.)
        recordingCalendarEventID = nil

        // Mark the active call session as user-declined: while the same call
        // window is still in front, window-detect won't re-arm a countdown.
        // Cleared by the 60s session-end grace timer in `handleCallContext`.
        if currentCallSession != nil {
            currentCallSession = CallSessionMachine.onUserStopped(currentCallSession)
            NSLog("[CallDetect] stopMeetingRecording — marked session declined for %@",
                  currentCallSession?.name ?? "(none)")
        }
        // Do NOT clear `currentMeetingCallContext` here — `persistMeetingTranscript`
        // runs in the Task below and needs to read it for `conversationGrouper.assign`.
        // It's overwritten on the next auto-start; manual starts begin with whatever
        // was last set (which is harmless for the resume window check — that lookup
        // is filtered to recent inProgress/completed conversations regardless).
        // Clear pending callEnded debounce + calendar hard stop — they're stale
        // now that recording is ending.
        callEndedDebounceTask?.cancel()
        callEndedDebounceTask = nil
        calendarHardStopTask?.cancel()
        calendarHardStopTask = nil

        // Try to reuse `LiveMeetingAdvisor` partials as the final transcript.
        // The advisor was already transcribing the same audio in 30s chunks for
        // realtime advice — re-transcribing on stop() doubled the cloud cost
        // (a 30-min meeting → 60min billed). `finalize()` returns the assembled
        // partials + the offsets where we left off; nil means advisor was off
        // or collected nothing, in which case we fall back to a full pass.
        let liveResult = liveMeetingAdvisor.finalize()

        // Snapshot the tail audio (samples since the advisor's last successful
        // tick) BEFORE `recorder.stop()` wipes the buffers. ≤ chunkSeconds of
        // audio. peekSamples is non-destructive and safe while mic still runs.
        let tailMic: [Float]
        let tailSys: [Float]
        if let live = liveResult {
            tailMic = meetingRecorder.mic.peekSamples(from: live.micOffsetAtFinalize)
            tailSys = meetingRecorder.systemAudio.peekSamples(from: live.sysOffsetAtFinalize)
        } else {
            tailMic = []
            tailSys = []
        }

        let (micSamples, sysSamples) = meetingRecorder.stop()
        NSLog("[MetaWhisp] Meeting stopped: mic=%d samples, system=%d samples",
              micSamples.count, sysSamples.count)

        guard micSamples.count + sysSamples.count > 16000 else { // > 1 second total
            NSLog("[MetaWhisp] Meeting recording too short, discarding")
            return
        }

        Task {
            // Engine selection is the same for both paths — reads `coordinator.activeEngine`
            // at runtime so the user's current setting (cloud vs on-device) wins.
            guard let engine = coordinator.activeEngine, engine.isModelLoaded else {
                let mode = AppSettings.shared.transcriptionEngine == "cloud" ? "Cloud" : "On-device"
                coordinator.lastError = "\(mode) transcription not ready — open Settings and select a model"
                NSLog("[MetaWhisp] ❌ Meeting transcribe: engine not ready (%@)", mode)
                return
            }

            let startTime = CFAbsoluteTimeGetCurrent()
            let fullText: String

            if let live = liveResult {
                NSLog("[MetaWhisp] Meeting reusing LiveAdvisor partials (%d collected, %d chars) — only tail needs transcribe",
                      live.partialCount, live.text.count)
                fullText = await self.assembleMeetingTranscriptFromLive(
                    liveText: live.text,
                    tailMic: tailMic,
                    tailSys: tailSys,
                    engine: engine
                )
            } else {
                NSLog("[MetaWhisp] Meeting transcribing via %@ (no live partials — dual-stream pass)", engine.name)
                fullText = await self.transcribeMeetingDualStream(mic: micSamples, system: sysSamples, engine: engine)
            }

            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            let duration = Double(max(micSamples.count, sysSamples.count)) / 16000.0

            guard !fullText.isEmpty else {
                NSLog("[MetaWhisp] Meeting transcription empty (all chunks silent or hallucinated)")
                meetingRecorder.lastError = "🎤 No speech detected in recording"
                return
            }

            self.persistMeetingTranscript(fullText: fullText, duration: duration, elapsed: elapsed)
            NSLog("[MetaWhisp] ✅ Meeting transcribed: %.0fs audio → %d words in %.1fs", duration, fullText.split(separator: " ").count, elapsed)
        }
    }

    /// Pseudo-diarized re-transcribe: mic and system audio go through Whisper
    /// in two SEPARATE passes, then segments are merged by timestamp and
    /// rendered with `Me:` / `Them:` prefixes. Reference adaptation of
    /// multichannel per-channel speaker labels — Whisper has no multichannel
    /// mode, so we run the two channels through it independently. mic and
    /// system samples are NEVER summed, so cross-channel mix-in artifacts
    /// (e.g. system browser audio leaking into mic transcript as "AYA Google")
    /// are physically impossible.
    ///
    /// Cost: ~2× the old single-mix path (transcribes mic + system separately).
    /// Whichever side is empty (no system audio in mic-only mode) produces
    /// zero chunks → zero spend on that side.
    ///
    /// Sequential, not parallel — the engine instance is shared and Whisper
    /// transcribe is not guaranteed to be safe under concurrent calls. Latency
    /// = mic-pass + system-pass.
    private func transcribeMeetingDualStream(
        mic: [Float],
        system: [Float],
        engine: TranscriptionEngine
    ) async -> String {
        let micSegments = await transcribeStreamChunked(samples: mic, engine: engine, speaker: .me)
        let sysSegments = await transcribeStreamChunked(samples: system, engine: engine, speaker: .them)
        let merged = DualStreamMerger.mergeStreams(mic: micSegments, system: sysSegments)
        NSLog("[MetaWhisp] Meeting dual-stream: mic=%d segments, system=%d segments → %d merged",
              micSegments.count, sysSegments.count, merged.count)
        return DualStreamMerger.renderTranscript(merged)
    }

    /// Transcribe ONE channel (mic or system) into per-chunk StreamSegments.
    /// Phase A wins preserved: silence-boundary chunk cuts + VAD trim per chunk.
    /// Each surviving chunk produces one StreamSegment whose start/end seconds
    /// reflect the chunk's position in the original buffer (for downstream
    /// time-sorted merge with the other channel).
    private func transcribeStreamChunked(
        samples: [Float],
        engine: TranscriptionEngine,
        speaker: Speaker
    ) async -> [StreamSegment] {
        guard !samples.isEmpty else { return [] }
        let chunks = AppDelegate.splitOnSilenceBoundaries(samples: samples, targetChunkSec: 300, searchWindowSec: 15)
        let label = speaker == .me ? "Me" : "Them"

        var segments: [StreamSegment] = []
        var offsetSamples = 0
        for (i, rawChunk) in chunks.enumerated() {
            let chunkStartSec = Double(offsetSamples) / 16000.0
            let chunkEndSec = Double(offsetSamples + rawChunk.count) / 16000.0
            offsetSamples += rawChunk.count

            // VAD trim — strip leading/trailing silence so Whisper has less
            // material to hallucinate over.
            let chunk = AppDelegate.trimSilenceEdges(samples: rawChunk)
            let rms = TranscriptionCoordinator.calculateRMS(chunk)
            NSLog("[MetaWhisp] Meeting %@ chunk %d/%d: %d→%d samples after trim, RMS=%.4f",
                  label, i + 1, chunks.count, rawChunk.count, chunk.count, rms)

            if chunk.count < 8000 || rms < 0.0005 {
                NSLog("[MetaWhisp] ⏭️  %@ chunk %d too quiet/short — skip", label, i + 1)
                continue
            }

            do {
                let lang = AppSettings.shared.transcriptionLanguage == "auto" ? nil : AppSettings.shared.transcriptionLanguage
                let result = try await engine.transcribe(audioSamples: chunk, language: lang, promptWords: ["MetaWhisp"])
                let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }

                if TranscriptionCoordinator.isAlwaysHallucination(text) {
                    NSLog("[MetaWhisp] ⚠️  %@ chunk %d: filtered always-hallucination: '%@'", label, i + 1, String(text.prefix(60)))
                    continue
                }
                if rms < 0.003, TranscriptionCoordinator.isHallucination(text) {
                    NSLog("[MetaWhisp] ⚠️  %@ chunk %d: filtered hallucination (RMS=%.4f): '%@'", label, i + 1, rms, String(text.prefix(60)))
                    continue
                }

                // ITER-026 — emit ONE StreamSegment per Whisper utterance, not
                // per chunk. Previously we collapsed every chunk's text into a
                // single 5-min segment with `startSec=chunkStartSec`,
                // `endSec=chunkEndSec`. Result: in the merged transcript, mic
                // and system streams alternated as 5-MINUTE BLOCKS instead of
                // interleaving by actual speech timing — "Me: <5 min monologue>
                // / Them: <5 min monologue>". User reported this as "опять
                // кривая неразборчивая хуйня" 2026-05-02.
                //
                // Whisper already gives us per-utterance start/end via
                // `result.segments` (TranscriptionResult.Segment). Use them.
                // Each Whisper segment becomes its own StreamSegment with
                // absolute timing = chunkStartSec + whisperSeg.start so the
                // merger interleaves at real-utterance grain.
                let whisperSegments = result.segments
                if whisperSegments.isEmpty {
                    // Fallback for engines that don't populate segments —
                    // emit one segment covering the chunk (old behaviour).
                    segments.append(StreamSegment(text: text, startSec: chunkStartSec, endSec: chunkEndSec, speaker: speaker))
                } else {
                    for w in whisperSegments {
                        let utteranceText = w.text.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !utteranceText.isEmpty else { continue }
                        let absStart = chunkStartSec + w.start
                        let absEnd = chunkStartSec + w.end
                        segments.append(StreamSegment(text: utteranceText, startSec: absStart, endSec: absEnd, speaker: speaker))
                    }
                }
            } catch {
                NSLog("[MetaWhisp] ❌ Meeting %@ chunk %d failed: %@", label, i + 1, error.localizedDescription)
            }
        }
        return segments
    }

    /// Decode a JSON `[String]` array stored on `Conversation`'s structured
    /// fields (participantsJSON / decisionsJSON / nextStepsJSON). Returns
    /// nil on parse failure, empty array passes through unchanged.
    /// Used by `fireMeetingRecap` to lift LLM-extracted lists into the
    /// recap popup payload.
    static func decodeStringArray(_ raw: String) -> [String]? {
        guard let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([String].self, from: data)
    }

    /// Split samples into chunks of ~`targetChunkSec` length, but cut at the
    /// QUIETEST 500ms window within ±`searchWindowSec` of the target boundary.
    /// Real speech rarely has 500ms of silence mid-word — this lands cuts on
    /// natural pauses and stops Whisper from losing words at boundaries.
    static func splitOnSilenceBoundaries(samples: [Float], targetChunkSec: Int, searchWindowSec: Int) -> [[Float]] {
        let sampleRate = 16000
        let target = targetChunkSec * sampleRate
        guard samples.count > target else { return [samples] }
        let searchHalf = searchWindowSec * sampleRate
        let windowSize = sampleRate / 2  // 500ms RMS window

        var out: [[Float]] = []
        var cursor = 0
        while cursor < samples.count {
            let remaining = samples.count - cursor
            if remaining <= target {
                out.append(Array(samples[cursor..<samples.count]))
                break
            }
            // Initial guess: target-cursor mark.
            let guess = cursor + target
            // Search range — clamp inside buffer.
            let searchStart = max(cursor + target / 2, guess - searchHalf)
            let searchEnd = min(samples.count - windowSize, guess + searchHalf)

            var bestIdx = guess
            var bestRMS: Float = .greatestFiniteMagnitude
            var i = searchStart
            // Step every 100ms (1600 samples) — cheap scan.
            let step = sampleRate / 10
            while i + windowSize <= searchEnd {
                let win = Array(samples[i..<i+windowSize])
                let rms = TranscriptionCoordinator.calculateRMS(win)
                if rms < bestRMS {
                    bestRMS = rms
                    bestIdx = i + windowSize / 2  // cut in middle of quietest window
                }
                i += step
            }
            out.append(Array(samples[cursor..<bestIdx]))
            cursor = bestIdx
        }
        return out
    }

    /// Strip leading/trailing silence from a chunk. Defines silence as
    /// `RMS < 0.005` over a 100ms window. Keeps speech-only audio so Whisper
    /// has less material to hallucinate over.
    static func trimSilenceEdges(samples: [Float]) -> [Float] {
        let sampleRate = 16000
        let win = sampleRate / 10  // 100ms
        let threshold: Float = 0.005
        guard samples.count > win * 2 else { return samples }

        // Find first non-silent window.
        var start = 0
        while start + win <= samples.count {
            let rms = TranscriptionCoordinator.calculateRMS(Array(samples[start..<start+win]))
            if rms >= threshold { break }
            start += win
        }
        // Find last non-silent window.
        var end = samples.count - win
        while end > start {
            let rms = TranscriptionCoordinator.calculateRMS(Array(samples[end..<end+win]))
            if rms >= threshold { break }
            end -= win
        }
        let trimmedEnd = min(samples.count, end + win)
        guard trimmedEnd > start else { return samples }
        return Array(samples[start..<trimmedEnd])
    }

    /// Reuse path: take the joined LiveAdvisor partials and append a single
    /// transcription of the tail (audio between the advisor's last successful
    /// tick and meeting stop). One engine call instead of N chunked calls.
    private func assembleMeetingTranscriptFromLive(
        liveText: String,
        tailMic: [Float],
        tailSys: [Float],
        engine: TranscriptionEngine
    ) async -> String {
        var fullText = liveText

        let tailMixed = MeetingRecorder.mix(mic: tailMic, system: tailSys)
        // Skip tail transcribe if it's tiny (≤ 1s) or below silence floor — same
        // RMS floor the chunked path uses, so silence behaves identically.
        guard tailMixed.count >= 16000 else {
            NSLog("[MetaWhisp] Meeting tail negligible (%d samples) — skip", tailMixed.count)
            return fullText
        }
        let rms = TranscriptionCoordinator.calculateRMS(tailMixed)
        guard rms >= 0.0005 else {
            NSLog("[MetaWhisp] Meeting tail silent (RMS=%.5f) — skip", rms)
            return fullText
        }

        do {
            let lang = AppSettings.shared.transcriptionLanguage == "auto" ? nil : AppSettings.shared.transcriptionLanguage
            let result = try await engine.transcribe(audioSamples: tailMixed, language: lang, promptWords: ["MetaWhisp"])
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            // Apply the same hallucination filter as the chunked path.
            if !text.isEmpty,
               !TranscriptionCoordinator.isAlwaysHallucination(text),
               !(rms < 0.003 && TranscriptionCoordinator.isHallucination(text)) {
                if !fullText.isEmpty { fullText += "\n\n" }
                fullText += text
                NSLog("[MetaWhisp] Meeting tail transcribed (%.1fs, %d chars)", Double(tailMixed.count) / 16000.0, text.count)
            } else {
                NSLog("[MetaWhisp] Meeting tail filtered (empty or hallucination)")
            }
        } catch {
            NSLog("[MetaWhisp] ❌ Meeting tail transcribe failed (keeping live partials): %@", error.localizedDescription)
        }
        return fullText
    }

    /// Persist the assembled transcript + downstream side effects (history,
    /// conversation grouping, recap notification, advice trigger). Identical
    /// for both the live-reuse and chunked-fallback paths.
    private func persistMeetingTranscript(fullText: String, duration: Double, elapsed: TimeInterval) {
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
            // `currentMeetingCallContext` enables grouper's resume-window logic
            // so a lid-bounce/wake-from-sleep doesn't fragment one call into N rows.
            conversationGrouper.assign(historyItem: item, callContext: currentMeetingCallContext, meetingDurationSec: duration)

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

    // MARK: - ITER-026 v2 — dictation-during-meeting hooks

    /// Called by `TranscriptionCoordinator` whenever a top-level dictation /
    /// voice question / translate hotkey starts. If a meeting recording is
    /// active, pause its mic stream so the user's spoken words don't leak
    /// into the meeting transcript, AND show a card with an "End meeting"
    /// button so the user can finalize the recording right there.
    func dictationDidStart() {
        guard meetingRecorder.isRecording else { return }
        meetingRecorder.pauseMic()
        let endNote = MWNotification(
            kind: .recordingStopped,
            title: "Meeting recording in progress",
            body: "Tap to end meeting now (otherwise it continues after dictation)",
            onTap: { [weak self] in
                guard let self else { return }
                NSLog("[CallDetect] User tapped 'End meeting' from dictation card")
                self.stopMeetingRecording(reason: "dictation-end-card-tap")
            }
        )
        MWNotificationStack.shared.push(endNote)
    }

    /// Called when the dictation/voice/translate hotkey path finishes
    /// (transcription completed OR cancelled OR error). Resumes mic capture
    /// for the still-running meeting if any.
    func dictationDidEnd() {
        guard meetingRecorder.isRecording else { return }
        meetingRecorder.resumeMic()
    }

    // MARK: - ITER-026 v2 — meeting auto-start gate

    /// 1-sec polling loop. Samples frontmost window state + fullscreen +
    /// audio activity, feeds `MeetingAutoStartGate.evaluate(...)`, and on
    /// `.fallbackReady` runs the countdown + audio-sniff sequence.
    /// Skips entirely while a recording is already running or while a
    /// countdown is mid-flight — those states own the audio pipeline.
    private func startMeetingAutoStartTickLoop() {
        meetingAutoStartTickTask?.cancel()
        meetingAutoStartTickTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }

                // Skip while a countdown is in flight — gate is mid-decision.
                if self.meetingCountdownInFlight {
                    continue
                }

                // Master gate: feature toggles. Same check whether we're
                // recording or not — if user disabled meetings entirely
                // we don't even evaluate the gate.
                guard AppSettings.shared.meetingRecordingEnabled,
                      AppSettings.shared.autoDetectCalls,
                      AppSettings.shared.callsAutoStartEnabled
                else {
                    MeetingAutoStartGate.shared.reset()
                    continue
                }

                // Sample frontmost window state — needed for both gate
                // evaluation and back-to-back detection.
                guard let frontApp = NSWorkspace.shared.frontmostApplication else {
                    MeetingAutoStartGate.shared.reset()
                    continue
                }
                let bundleID = frontApp.bundleIdentifier ?? ""
                let appName = frontApp.localizedName ?? ""
                let title = self.frontmostWindowTitle(pid: frontApp.processIdentifier) ?? ""
                let callName = SystemAudioCaptureService.detectCallContext(
                    bundleID: bundleID, appName: appName, windowTitle: title
                )

                // Fullscreen check: window covers the screen's visibleFrame.
                let isFullscreen = self.isFrontmostWindowFullscreen()

                // Calendar STRONG signal: any non-allday event that has just
                // started (within last 65s, not yet ended). Lets the gate
                // bypass the 10-sec sustained fallback when calendar says
                // "you have a meeting now". User explicit spec 2026-05-02:
                // "Если митинг начинается в два, то ровно в два часа
                // начинается запись".
                var calendarEvent: (id: String, title: String)? = nil
                if let ev = self.calendarReader.eventStartingNow(),
                   let id = ev.eventIdentifier {
                    let title = (ev.title?.trimmingCharacters(in: .whitespaces)).flatMap { $0.isEmpty ? nil : $0 } ?? "Meeting"
                    calendarEvent = (id: id, title: title)
                }

                // Audio: gate currently can't probe audio without a recorder
                // running. Pass `false` — fallback path needs only window
                // sustain. Post-countdown audio-sniff (after meeting starts)
                // catches AFK / silent-room cases.
                let decision = MeetingAutoStartGate.shared.evaluate(
                    callName: callName,
                    isFullscreen: isFullscreen,
                    audioActive: false,
                    calendarEventNow: calendarEvent
                )

                // ITER-028.2 (2026-05-06) — back-to-back transition detection
                // via stable calendar `EKEvent.eventIdentifier`. Replaces the
                // 2026-05-04 window-title heuristic that misfired daily.
                // While a recording is active, ask the pure-function decider
                // whether the latest gate state means the user transitioned
                // to a new calendar event. Manual recordings short-circuit
                // inside `BackToBackTransition.decide`.
                if self.meetingRecorder.isRecording {
                    let bbDecision = BackToBackTransition.decide(
                        currentRecordingEventID: self.recordingCalendarEventID,
                        gateDecision: decision,
                        isManualMode: self.meetingRecorder.isManualMode
                    )
                    if case let .stopAndRestart(newEventID, newName) = bbDecision {
                        NSLog("[CallDetect] back-to-back via eventID: newID=%@ ('%@') != recordedID=%@ → stop A, immediately fire B countdown",
                              newEventID, newName,
                              self.recordingCalendarEventID ?? "(nil)")
                        self.stopMeetingRecording(reason: "back-to-back-eventID:\(newEventID)")
                        // CC-14 fix: gate already consumed its single
                        // `.calendarReady(B)` emission this tick, and won't
                        // re-emit B on subsequent ticks
                        // (`MeetingAutoStartGate.lastCalendarEventID` blocks
                        // it). So we MUST fire B's countdown right here, in
                        // the same tick, or B is silently lost. We have
                        // newEventID and newName from the same gate output.
                        await self.runCountdownAndStartRecording(name: newName, source: "calendar", calendarEventID: newEventID)
                    }
                    // No transition (or A→B already kicked off) — either way
                    // do NOT fall through to the countdown switch below.
                    continue
                }
                if self.meetingRecorder.isStarting {
                    continue
                }

                // Not recording → handle the countdown decisions normally.
                switch decision {
                case .idle, .tracking:
                    continue
                case let .fallbackReady(name):
                    NSLog("[CallDetect] gate fallback ready for %@ — running countdown", name)
                    await self.runCountdownAndStartRecording(name: name, source: "fallback", calendarEventID: nil)
                case let .calendarReady(name, eventID):
                    NSLog("[CallDetect] gate calendar ready for %@ (eventID=%@) — running countdown", name, eventID)
                    await self.runCountdownAndStartRecording(name: name, source: "calendar", calendarEventID: eventID)
                }
            }
        }
    }

    /// Window-title for the given pid via Accessibility API. Mirror of the
    /// helper inside `ScreenContextService.getActiveWindowTitle` so the gate
    /// loop doesn't depend on the screen-context tick (30s) for fresh data.
    private func frontmostWindowTitle(pid: pid_t) -> String? {
        let appRef = AXUIElementCreateApplication(pid)
        var focusedWindow: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appRef, kAXFocusedWindowAttribute as CFString, &focusedWindow)
        guard result == .success, let window = focusedWindow else { return nil }
        // swiftlint:disable:next force_cast — AX API is dynamic, but this
        // pattern is well-established across the codebase.
        let axWindow = window as! AXUIElement
        var titleValue: CFTypeRef?
        let titleResult = AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &titleValue)
        guard titleResult == .success else { return nil }
        return titleValue as? String
    }

    /// Whether the frontmost window covers the entire visibleFrame of its
    /// screen (no menu bar / dock visible).
    private func isFrontmostWindowFullscreen() -> Bool {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return false }
        let pid = frontApp.processIdentifier
        let appRef = AXUIElementCreateApplication(pid)
        var focusedWindow: CFTypeRef?
        let r = AXUIElementCopyAttributeValue(appRef, kAXFocusedWindowAttribute as CFString, &focusedWindow)
        guard r == .success, let win = focusedWindow else { return false }
        let axWin = win as! AXUIElement
        // Use kAXFullScreenAttribute first — set by macOS native fullscreen.
        var fsValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(axWin, "AXFullScreen" as CFString, &fsValue) == .success,
           let isFS = fsValue as? Bool, isFS {
            return true
        }
        // Fallback: window bounds match screen visibleFrame.
        var posValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axWin, kAXPositionAttribute as CFString, &posValue) == .success,
              AXUIElementCopyAttributeValue(axWin, kAXSizeAttribute as CFString, &sizeValue) == .success
        else { return false }
        var pos = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posValue as! AXValue, .cgPoint, &pos)
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        // Compare against screen frame containing the window — within 8pt slack.
        guard let screen = NSScreen.screens.first(where: { NSPointInRect(pos, $0.frame) }) ?? NSScreen.main else { return false }
        let f = screen.frame
        let slack: CGFloat = 8
        return abs(pos.x - f.origin.x) < slack
            && abs(pos.y - f.origin.y) < slack
            && abs(size.width - f.size.width) < slack
            && abs(size.height - f.size.height) < slack
    }

    /// Show the 5-sec countdown plashka, then start `meetingRecorder`. Three
    /// seconds into the recording, sample `audioLevel` — if silent, stop and
    /// don't persist (AFK / room actually empty). Otherwise normal flow.
    private func runCountdownAndStartRecording(name: String, source: String, calendarEventID: String?) async {
        meetingCountdownInFlight = true
        defer { meetingCountdownInFlight = false }

        // 5-sec countdown with cancellable plashka.
        let countdownNote = MWNotification(
            kind: .call,
            title: "\(name) — recording in 5s",
            body: "Tap × on this card to cancel",
            onTap: nil
        )
        let cancelToken = countdownNote.id
        MWNotificationStack.shared.push(countdownNote)
        for _ in 0..<5 {
            try? await Task.sleep(for: .seconds(1))
            // If user dismissed by clicking ×, the card is no longer in the stack.
            let stillVisible = MWNotificationStack.shared.items.contains { $0.id == cancelToken }
            guard stillVisible else {
                NSLog("[CallDetect] %@ countdown cancelled by user", name)
                MeetingAutoStartGate.shared.reset()
                return
            }
        }
        MWNotificationStack.shared.dismiss(id: cancelToken)

        // Re-check: user may have manually started/stopped during countdown.
        guard !meetingRecorder.isRecording, !meetingRecorder.isStarting, !recorder.isRecording else {
            NSLog("[CallDetect] %@ countdown end — but already recording, skip auto-start", name)
            return
        }

        // Start recording. ITER-026 v2 — gate-triggered = NOT manual; full
        // silence + maxDuration guards apply.
        NSLog("[CallDetect] ▶️ %@ auto-start (%@, eventID=%@)", name, source, calendarEventID ?? "(nil)")
        didAutoStartRecording = true
        currentMeetingCallContext = name
        // ITER-028.2 (2026-05-06) — store the calendar event ID so the
        // back-to-back detector can compare against gate ticks. Stable
        // across the meeting; replaces the flaky window-title heuristic.
        // `nil` for fallback path (sustained-window) — those don't have a
        // comparable calendar baseline; back-to-back simply skips them.
        recordingCalendarEventID = calendarEventID
        calendarEndNotifyAttempts = 0
        meetingRecorder.start(manualMode: false)

        // ITER-034 — schedule the calendar-end auto-stop. Fires at
        // `EKEvent.endDate + grace` and decides via
        // `CalendarEndStopDecision.evaluate(...)`. Skipped for:
        //   • fallback path (no eventID)
        //   • events the calendar API can't resolve (nil)
        //   • all-day events (heuristic: > 6h duration treated as all-day)
        if let eventID = calendarEventID,
           let event = self.calendarReader.event(forIdentifier: eventID) {
            let endDate = event.endDate ?? Date().addingTimeInterval(3600)
            let durationSec = endDate.timeIntervalSince(event.startDate ?? Date())
            if durationSec <= 6 * 3600 {
                self.armCalendarEndStopTask(eventID: eventID, eventEnd: endDate)
            } else {
                NSLog("[CalendarEndStop] skip arming for '%@' (duration %.0fs > 6h, treated as all-day)",
                      name, durationSec)
            }
        }

        // 3-sec post-start audio sniff. If meeting room is empty (AFK / no
        // one talking) we stop without saving so the user doesn't get a
        // "Quick note (empty)" Conversation row clogging Library.
        try? await Task.sleep(for: .seconds(3))
        if meetingRecorder.isRecording, meetingRecorder.audioLevel < 0.01 {
            NSLog("[CallDetect] ⚠️ %@ post-start sniff — silence (audioLevel=%.4f), stopping discardly",
                  name, meetingRecorder.audioLevel)
            // Stop recorder — its onAutoStop won't fire (this isn't an auto-stop reason),
            // we just stop and don't persist anything.
            _ = meetingRecorder.stop()
            didAutoStartRecording = false
            currentMeetingCallContext = nil
            calendarHardStopTask?.cancel()
            calendarHardStopTask = nil
        }
    }

    /// ITER-034 — schedule calendar-end auto-stop. Re-schedules itself on
    /// `notifyAndExtend` outcomes. Cancelled by `stopMeetingRecording`.
    private func armCalendarEndStopTask(eventID: String, eventEnd: Date) {
        calendarHardStopTask?.cancel()
        let attemptsAtSchedule = calendarEndNotifyAttempts
        let now = Date()
        let grace = CalendarEndStopDecisionRules.defaultGraceSeconds
        // Fire at endDate + grace, OR right now if already past (e.g.
        // re-arm after a notifyAndExtend whose deadline already lapsed).
        let fireAt = max(eventEnd.addingTimeInterval(grace), now.addingTimeInterval(1))
        let delay = fireAt.timeIntervalSince(now)
        NSLog("[CalendarEndStop] armed for eventID=%@ end=%@ fireIn=%.0fs (attempt=%d)",
              eventID, "\(eventEnd)", delay, attemptsAtSchedule)
        calendarHardStopTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            // If recording stopped/changed underneath us, bail.
            guard self.meetingRecorder.isRecording,
                  self.recordingCalendarEventID == eventID else {
                NSLog("[CalendarEndStop] fire — but state moved on, skip")
                return
            }
            // Sample current audio level (max of mic + system, already
            // aggregated by MeetingRecorder).
            let rms = self.meetingRecorder.audioLevel
            let decision = CalendarEndStopDecision.evaluate(
                now: Date(),
                eventEnd: eventEnd,
                audioRMSLastNSec: rms,
                notifyAttemptsSoFar: self.calendarEndNotifyAttempts
            )
            NSLog("[CalendarEndStop] fire eventID=%@ rms=%.4f attempts=%d decision=%@",
                  eventID, rms, self.calendarEndNotifyAttempts, "\(decision)")
            switch decision {
            case .keepRunning:
                // Should not normally happen at fire time (we slept past
                // grace). Re-arm in 60s as safety.
                self.armCalendarEndStopTask(eventID: eventID, eventEnd: eventEnd)
            case .stopNow:
                self.stopMeetingRecording(reason: "calendar-end-grace:\(eventID)")
            case let .notifyAndExtend(newDeadline):
                self.calendarEndNotifyAttempts += 1
                let card = MWNotification(
                    kind: .recordingStopped,
                    title: "Meeting overrunning",
                    body: "Calendar event ended. Tap to stop now or it will re-check in 5 min.",
                    onTap: { [weak self] in
                        guard let self else { return }
                        self.stopMeetingRecording(reason: "calendar-end-overrun-card-tap:\(eventID)")
                    }
                )
                MWNotificationStack.shared.push(card)
                // Re-arm: pretend the new deadline is the eventEnd-anchor +
                // grace, so we sleep until newDeadline before re-evaluating.
                let pseudoEnd = newDeadline.addingTimeInterval(-CalendarEndStopDecisionRules.defaultGraceSeconds)
                self.armCalendarEndStopTask(eventID: eventID, eventEnd: pseudoEnd)
            case .hardStop:
                self.stopMeetingRecording(reason: "calendar-end-hard-stop:\(eventID)")
            }
        }
    }

    // MARK: - ITER-026 calendar-task migration

    /// Idempotent one-time migration of `meetingSilenceStopMinutes`. Older
    /// builds shipped 10 min as default; ITER-026 v2 lowers to 3 min so
    /// back-to-back calls stop merging into one zombie recording. Run at
    /// launch under a flag so user-tweaked values are preserved (only
    /// rewrite if the stored value matches the legacy default of 10).
    private func migrateSilenceStopMinutesOnce() {
        guard !AppSettings.shared.didMigrateSilenceStop else { return }
        if AppSettings.shared.meetingSilenceStopMinutes >= 9.5 {
            AppSettings.shared.meetingSilenceStopMinutes = 3
            NSLog("[ITER-026] ✅ Migrated meetingSilenceStopMinutes 10 → 3")
        }
        AppSettings.shared.didMigrateSilenceStop = true
    }

    /// Idempotent one-time cleanup: dismiss every committed `TaskItem` whose
    /// `sourceApp == "Calendar"`. Belt + suspenders: also catches rows where
    /// `sourceApp` is unexpectedly nil/empty but `dueAt != nil && conversationId == nil`
    /// (the calendar-pipe's signature: hard-due, no transcript origin).
    /// Voice-extracted tasks always have a `conversationId` so they survive.
    private func migrateCalendarTasksOnce() {
        guard !AppSettings.shared.didMigrateCalendarTasks else { return }
        let ctx = ModelContext(historyService.modelContainer)
        let desc = FetchDescriptor<TaskItem>(
            predicate: #Predicate { !$0.isDismissed && !$0.completed }
        )
        guard let all = try? ctx.fetch(desc) else { return }
        var dismissed = 0
        for t in all {
            let isCalendarSource = (t.sourceApp == "Calendar")
            let looksLikeOrphanCalendar = (t.conversationId == nil && t.dueAt != nil && (t.sourceApp == nil || t.sourceApp?.isEmpty == true))
            if isCalendarSource || looksLikeOrphanCalendar {
                t.isDismissed = true
                t.status = "dismissed"
                t.updatedAt = Date()
                dismissed += 1
            }
        }
        if dismissed > 0 {
            try? ctx.save()
            NSLog("[ITER-026] ✅ Dismissed %d legacy calendar-derived tasks", dismissed)
        }
        AppSettings.shared.didMigrateCalendarTasks = true
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
