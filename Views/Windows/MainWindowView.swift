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
            // Hero color wash — gives the glass materials something to refract.
            // Without this the whole window reads as flat gray.
            heroBackground
                .ignoresSafeArea()

            HStack(spacing: 0) {
                sidebar
                    .frame(width: 200)
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

    private var heroBackground: some View {
        LinearGradient(
            colors: MW.isDark
                ? [Color(w: 0.10), Color(w: 0.04)]
                : [Color(w: 0.97), Color(w: 0.92)],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    // MARK: - Custom Sidebar (glass)

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Brand: real app icon + wordmark.
            HStack(spacing: 10) {
                Image(nsImage: NSImage(named: "AppIcon") ?? NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 30, height: 30)
                Text("MetaWhisp")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(MW.textPrimary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)

            GlassDivider().padding(.horizontal, 8).padding(.bottom, 6)

            // Tab items
            VStack(spacing: 2) {
                ForEach(SidebarTab.allCases) { tab in
                    sidebarItem(tab)
                }
            }
            .padding(.horizontal, 6)

            Spacer()

            // Version
            Text("v0.0.1")
                .font(MW.monoSm)
                .foregroundStyle(MW.textDim)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
        }
        .mwCard(radius: MW.rLarge, elevation: .hero)
    }

    private func sidebarItem(_ tab: SidebarTab) -> some View {
        Button {
            selectedTab = tab
        } label: {
            HStack(spacing: 10) {
                Image(systemName: tab.icon)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 18, height: 18)
                Text(tab.rawValue)
                    .font(.system(size: 13, weight: .medium))
                Spacer()
            }
            .foregroundStyle(selectedTab == tab ? MW.textPrimary : MW.textSecondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background {
                if selectedTab == tab {
                    RoundedRectangle(cornerRadius: MW.rSmall, style: .continuous)
                        .fill(Color.primary.opacity(0.10))
                        .overlay(
                            RoundedRectangle(cornerRadius: MW.rSmall, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.16), lineWidth: 0.5)
                        )
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
