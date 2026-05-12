import SwiftUI

/// Main window content — custom dark sidebar + detail area in BLOCKS style.
struct MainWindowView: View {
    @ObservedObject var coordinator: TranscriptionCoordinator
    @ObservedObject var modelManager: ModelManagerService
    @ObservedObject var recorder: AudioRecordingService
    var historyService: HistoryService

    /// Drives the sidebar footer pips. AppSettings publishes change events
    /// when @AppStorage-backed properties flip, so the footer recomposes
    /// the moment the user toggles e.g. "Proactive insights" in Settings.
    @ObservedObject private var settings = AppSettings.shared
    /// Drives the tier pip ("free" / "pro"). LicenseService publishes
    /// `isPro` after license activation/deactivation.
    @ObservedObject private var license = LicenseService.shared

    @State var selectedTab: SidebarTab

    init(
        coordinator: TranscriptionCoordinator,
        modelManager: ModelManagerService,
        recorder: AudioRecordingService,
        historyService: HistoryService,
        initialTab: SidebarTab = .dashboard
    ) {
        self.coordinator = coordinator
        self.modelManager = modelManager
        self.recorder = recorder
        self.historyService = historyService
        _selectedTab = State(initialValue: initialTab)
    }

    enum SidebarTab: String, CaseIterable, Identifiable {
        case dashboard = "Dashboard"
        case library = "Library"
        case projects = "Projects"
        case goals = "Goals"
        case tasks = "Tasks"
        case chat = "MetaChat"
        case dictionary = "Dictionary"
        case settings = "Settings"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .dashboard: "gauge.with.dots.needle.33percent"
            case .library: "books.vertical"
            case .projects: "folder.badge.person.crop"
            case .goals: "target"
            case .tasks: "checklist"
            case .chat: "message"
            case .dictionary: "character.book.closed"
            case .settings: "gearshape"
            }
        }
    }

    var body: some View {
        ZStack {
            // Liquid Glass page wash — radial warm + cool stops on a vertical
            // gradient. Mirrors `--bg-grad` in tokens.css. Hero materials
            // (sidebar / cards) refract through this. See PageWash component.
            PageWash()

            HStack(spacing: 0) {
                sidebar
                    .frame(width: 220)
                    .padding(.leading, 12)
                    .padding(.vertical, 12)

                detailContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.leading, 4)
            }
        }
        .modelContainer(historyService.modelContainer)
        .onReceive(NotificationCenter.default.publisher(for: .switchMainTab)) { notification in
            if let tab = notification.object as? SidebarTab {
                selectedTab = tab
            }
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
                Text("MetaWhisp")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(MW.textPrimary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)

            GlassDivider().padding(.horizontal, 8).padding(.bottom, 6)

            // Tab items via the SidebarItem primitive.
            VStack(spacing: 2) {
                ForEach(SidebarTab.allCases) { tab in
                    SidebarItem(
                        title: tab.rawValue,
                        icon: tab.icon,
                        isActive: selectedTab == tab,
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
    ///   - `transcriptionEngine`: primary dictation engine ("ondevice" or "cloud")
    ///   - `processingMode == "structured"`: post-transcription LLM cleanup
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
        let primaryCloud = settings.transcriptionEngine == "cloud"
        let hasLocalLLM = settings.localLLMEnabled && !settings.localLLMActiveModelID.isEmpty
        let cloudFeatures = settings.processingMode == "structured"
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

    /// Color follows the label's "leaning":
    ///   - all-local labels → green (idle) — no network roundtrips
    ///   - all-cloud → light blue (postProcess) — networked, semantically remote
    ///   - hybrid (mix) → orange (processing) — intermediate
    private var processingModeColor: Color {
        switch processingModeLabel {
        case "cloud":                       return MW.postProcess
        case "on-device+cloud",
             "local+cloud",
             "on-device+local+cloud":       return MW.processing
        default:                            return MW.idle   // "on-device" / "local" / "on-device+local"
        }
    }

    private var tierLabel: String {
        license.isPro ? "pro" : "free"
    }

    private var tierColor: Color {
        // Pro = green (active subscription); free = dim grey (no accent steal).
        license.isPro ? MW.idle : MW.textDim
    }

    @ViewBuilder
    private var detailContent: some View {
        switch selectedTab {
        case .dashboard:
            DashboardView(coordinator: coordinator)
        case .library:
            LibraryView()
        case .projects:
            ProjectsView()
        case .goals:
            GoalsView()
        case .tasks:
            TasksView()
        case .chat:
            ChatView()
        case .dictionary:
            DictionaryView()
        case .settings:
            MainSettingsView(modelManager: modelManager)
        }
    }
}
