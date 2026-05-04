import SwiftUI

/// Main window content — custom dark sidebar + detail area in BLOCKS style.
struct MainWindowView: View {
    @ObservedObject var coordinator: TranscriptionCoordinator
    @ObservedObject var modelManager: ModelManagerService
    @ObservedObject var recorder: AudioRecordingService
    var historyService: HistoryService

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

            // Version + on-device status pip — matches mockup footer.
            HStack(spacing: 8) {
                Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")")
                    .font(MW.monoSm)
                    .foregroundStyle(MW.textDim)
                Spacer()
                HStack(spacing: 5) {
                    Circle()
                        .fill(MW.idle)
                        .frame(width: 5, height: 5)
                    Text("on-device")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(MW.textMuted)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .mwCard(radius: MW.rLarge, elevation: .hero)
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
