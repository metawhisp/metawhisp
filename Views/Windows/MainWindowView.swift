import SwiftUI

/// Main window content — custom dark sidebar + detail area in BLOCKS style.
struct MainWindowView: View {
    @ObservedObject var coordinator: TranscriptionCoordinator
    @ObservedObject var modelManager: ModelManagerService
    @ObservedObject var recorder: AudioRecordingService
    @ObservedObject var historyService: HistoryService
    /// Whether the engine can transcribe now — the Dashboard's next step reads it.
    let modelPreparer: ModelPreparer

    /// Drives the sidebar footer pips. AppSettings publishes change events
    /// when @AppStorage-backed properties flip, so the footer recomposes
    /// the moment the user toggles e.g. "Proactive insights" in Settings.
    @ObservedObject private var settings = AppSettings.shared
    /// ITER-039 — pip flips to "local" the moment Phi-4 finishes loading
    /// into RAM. Observed so the footer animates the green dot instantly
    /// instead of staying blue until next re-render.
    @ObservedObject private var localLLM = LocalLLMService.shared
    /// Drives the tier pip ("free" / "pro"). LicenseService publishes
    /// `isPro` after license activation/deactivation.
    @ObservedObject private var license = LicenseService.shared

    @State var selectedTab: SidebarTab
    /// Below `railBelow` the sidebar folds to its icons, so a narrow window keeps its width for the screen.
    @State private var railOnly = false
    static let railBelow: CGFloat = 760

    init(
        coordinator: TranscriptionCoordinator,
        modelManager: ModelManagerService,
        modelPreparer: ModelPreparer,
        recorder: AudioRecordingService,
        historyService: HistoryService,
        initialTab: SidebarTab = .dashboard
    ) {
        self.coordinator = coordinator
        self.modelManager = modelManager
        self.modelPreparer = modelPreparer
        self.recorder = recorder
        self.historyService = historyService
        _selectedTab = State(initialValue: initialTab)
    }

    enum SidebarTab: String, CaseIterable, Identifiable {
        case dashboard = "Dashboard"
        case library = "Library"
        case workspace = "Workspace"
        case weeklyInsights = "Weekly Insights"
        case chat = "MetaChat"
        case dictionary = "Dictionary"
        case settings = "Settings"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .dashboard: "gauge.with.dots.needle.33percent"
            case .library: "books.vertical"
            case .workspace: "checklist"
            case .weeklyInsights: "lightbulb"
            case .chat: "message"
            case .dictionary: "character.book.closed"
            case .settings: "gearshape"
            }
        }
    }

    /// The smallest the window may be: about half the old 900 pt, every tab one column there (owner, 2026-11-26:
    /// allow it twice as narrow, one column left). Declared here, by the content, because the hosting view sets the
    /// window's minimum from its content; every tab must fit it (MainWindowWidthTests).
    static let minimumSize = NSSize(width: 450, height: 600)

    var body: some View {
        ZStack {
            // The wall — the window's one ground (ITER-087). See PageWash.
            PageWash()

            HStack(spacing: 0) {
                // The title bar is transparent and has no text (ITER-087): the window buttons sit on the wall, and the
                // sidebar starts just under them — its rounded corner ran through them when it reached the top (owner,
                // 2026-11-25). Both columns keep the title bar's safe area, so nothing lies under its drag region.
                sidebar
                    .frame(width: railOnly ? 52 : 220)
                    .padding(.leading, 12)
                    .padding(.top, 4)
                    .padding(.bottom, 12)

                detailContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.leading, 4)
            }
        }
        .modelContainer(historyService.modelContainer)
        // System controls (switches, progress) take the user's accent, not macOS's (ITER-087).
        .tint(MW.controlTint)
        .overlay {
            // AUD-007 / ITER-049 A1 — blocking recovery surface when the
            // persistent store couldn't be opened (temporary in-memory session).
            if case let .degraded(reason, backupPath) = historyService.health {
                StoreRecoveryOverlay(reason: reason, backupPath: backupPath)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .switchMainTab)) { notification in
            if let tab = notification.object as? SidebarTab {
                selectedTab = tab
            }
        }
        // The window's minimum, said by the content the hosting view sizes the window from.
        .frame(minWidth: Self.minimumSize.width, minHeight: Self.minimumSize.height)
        // Flips only when the window crosses the line, not on every pixel of a resize.
        .onGeometryChange(for: Bool.self) { $0.size.width < Self.railBelow } action: { folded in
            if folded != railOnly { railOnly = folded }
        }
    }

    // MARK: - Custom Sidebar (glass-hero)

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Brand block: app icon + "MetaWhisp".
            HStack(spacing: 10) {
                Image(nsImage: NSImage(named: "AppIcon") ?? NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 30, height: 30)
                if !railOnly {
                    Text("MetaWhisp")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(MW.textPrimary)
                    Spacer()
                }
            }
            .frame(maxWidth: .infinity, alignment: railOnly ? .center : .leading)
            .padding(.horizontal, railOnly ? 0 : 12)
            .padding(.vertical, 12)

            GlassDivider().padding(.horizontal, 8).padding(.bottom, 6)

            // Tab items via the SidebarItem primitive.
            VStack(spacing: 2) {
                ForEach(SidebarTab.allCases) { tab in
                    SidebarItem(
                        title: tab.rawValue,
                        icon: tab.icon,
                        isActive: selectedTab == tab,
                        compact: railOnly,
                        action: { selectedTab = tab }
                    )
                }
            }
            .padding(.horizontal, 6)

            Spacer()

            // Version + processing-mode + tier pips. Replaces a previous
            // hard-coded "● on-device" label that was decorative-only and
            // misleading for users on Cloud Whisper / Pro proxy paths.
            // Both pips derive from settings + license live, so flipping
            // a Cloud-feature toggle in Settings instantly updates the footer.
            // The folded rail has no room for them; they come back with the full sidebar.
            if !railOnly {
                HStack(spacing: 8) {
                    Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")")
                        .font(MW.monoSm)
                        .foregroundStyle(MW.textDim)
                    Spacer()
                    statusPip(label: processingModeLabel, color: processingModeColor)
                    statusPip(label: tierLabel, color: tierColor)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
        }
        .mwCard(radius: MW.rLarge, elevation: .hero)
    }

    // MARK: - Footer status pips

    /// Reusable colored-dot + label pip for the sidebar footer.
    /// `color` is the dot fill; the label always uses `MW.textMuted` so the
    /// pip is unobtrusive — the dot carries the accent.
    private func statusPip(label: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 5, height: 5)
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(MW.textMuted)
        }
    }

    /// Decides the processing-mode label based on which paths the user
    /// has actually wired up. Source-of-truth flags:
    ///   - `coordinator.usesCloud`: the dictation engine in use — cloud only with Pro or a key (A4)
    ///   - `processingMode` Structured or Target (`usesModel`): post-transcription LLM cleanup
    ///   - `proactiveEnabled`: ITER-027 insight extraction (cloud LLM)
    ///   - `ttsCloudEnabled`: cloud TTS for voice replies
    ///   - `liveMeetingAdviceEnabled`: live coach during meetings
    ///   - `localLLMEnabled` + `localLLMActiveModelID`: ITER-039 local LLM is loaded
    ///
    /// `cloud` features all require Pro proxy so they're real cloud roundtrips.
    /// `local` features run through MLX-hosted model OR Apple Foundation Models.
    ///
    /// Label combinations (ITER-039):
    ///   - "on-device" — fully local Whisper + no post-processing LLM
    ///   - "local" — Whisper on-device + LOCAL LLM for cleanup/intelligence
    ///   - "cloud" — cloud Whisper + cloud LLM (Pro)
    ///   - "on-device+cloud" — local Whisper + cloud LLM
    ///   - "local+cloud" — local LLM for processing + cloud Whisper for transcription
    ///   - "on-device+local" — fully local stack (Whisper + local LLM)
    private var processingModeLabel: String {
        let primaryCloud = coordinator.usesCloud
        // ITER-039 Phase 5b — pip says "local" ONLY when the model weights
        // are actually loaded into RAM. `localLLMActiveModelID` non-empty
        // means the user picked one; `isReady` means it's truly serving
        // tokens. Without the `isReady` gate, the pip would lie during the
        // ~5-10s warm-up between Make active and first inference.
        let hasLocalLLM = settings.localLLMEnabled
            && !settings.localLLMActiveModelID.isEmpty
            && LocalLLMService.shared.isReady
        let cloudFeatures = ProcessingMode(rawValue: settings.processingMode)?
            .asksModel(isPro: license.isPro && license.licenseKey != nil) == true
            || settings.proactiveEnabled
            || settings.ttsCloudEnabled
            || settings.liveMeetingAdviceEnabled
        // When local LLM is active, structured/processing fires on-device — only
        // truly remote features (proactive insights, cloud TTS, live meeting
        // advice) count as «cloud features».
        let actualCloudFeatures = hasLocalLLM
            ? (settings.proactiveEnabled || settings.ttsCloudEnabled || settings.liveMeetingAdviceEnabled)
            : cloudFeatures
        let hasCloud = primaryCloud || actualCloudFeatures
        let hasLocalDictation = !primaryCloud

        // Six possible states, ordered by likelihood for status pip display:
        if hasLocalDictation && hasLocalLLM && !hasCloud {
            return "on-device+local"  // fully on-device stack
        }
        if hasLocalDictation && hasLocalLLM && hasCloud {
            return "on-device+local+cloud"  // hybrid: local Whisper + local LLM + cloud insight/TTS
        }
        if hasLocalLLM && hasCloud {
            return "local+cloud"  // cloud Whisper + local LLM
        }
        if hasLocalLLM {
            return "local"
        }
        if hasCloud && hasLocalDictation { return "on-device+cloud" }
        if hasCloud { return "cloud" }
        return "on-device"
    }

    /// The dot is the user's accent whatever the mode (owner, 2026-11-25: no green but in Mint, no blue); the label
    /// says the mode.
    private var processingModeColor: Color { MW.ok }

    private var tierLabel: String {
        license.isPro ? "pro" : "free"
    }

    private var tierColor: Color {
        // Pro = the accent (active subscription); free = dim grey.
        license.isPro ? MW.ok : MW.textDim
    }

    @ViewBuilder
    private var detailContent: some View {
        switch selectedTab {
        case .dashboard:
            DashboardView(coordinator: coordinator, modelPreparer: modelPreparer)
        case .library:
            LibraryView()
        case .workspace:
            WorkspaceView()
        case .weeklyInsights:
            WeeklyInsightsView()
        case .chat:
            ChatWithInboxView()
        case .dictionary:
            DictionaryView()
        case .settings:
            MainSettingsView(modelManager: modelManager)
        }
    }
}
