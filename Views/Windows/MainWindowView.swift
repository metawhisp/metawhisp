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
        case tasks = "Tasks"
        case chat = "MetaChat"
        case dictionary = "Dictionary"
        case settings = "Settings"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .dashboard: "gauge.with.dots.needle.33percent"
            case .library: "books.vertical"
            case .tasks: "checklist"
            case .chat: "message"
            case .dictionary: "character.book.closed"
            case .settings: "gearshape"
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            // Custom dark sidebar
            sidebar
            // Separator
            Rectangle().fill(MW.border).frame(width: MW.hairline)
            // Detail
            detailContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(MW.bg)
        .modelContainer(historyService.modelContainer)
        .onReceive(NotificationCenter.default.publisher(for: .switchMainTab)) { notification in
            if let tab = notification.object as? SidebarTab {
                selectedTab = tab
            }
        }
    }

    // MARK: - Custom Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Logo header
            Text("MW")
                .font(MW.monoTitle)
                .foregroundStyle(MW.textPrimary)
                .tracking(2)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 12)

            Rectangle().fill(MW.border).frame(height: MW.hairline)
                .padding(.bottom, 8)

            // Tab items
            ForEach(SidebarTab.allCases) { tab in
                sidebarItem(tab)
            }

            Spacer()

            // Version at bottom
            Rectangle().fill(MW.border).frame(height: MW.hairline)
            Text("v0.0.1")
                .font(MW.monoSm)
                .foregroundStyle(MW.textMuted)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
        }
        .frame(width: 170)
        .background(MW.surface)
    }

    private func sidebarItem(_ tab: SidebarTab) -> some View {
        Button {
            selectedTab = tab
        } label: {
            HStack(spacing: 8) {
                Image(systemName: tab.icon)
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 16)
                Text(tab.rawValue.uppercased())
                    .font(MW.label)
                    .tracking(0.8)
                Spacer()
            }
            .foregroundStyle(selectedTab == tab ? MW.textPrimary : MW.textMuted)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(selectedTab == tab ? Color.white.opacity(0.06) : .clear)
            .overlay(
                Rectangle()
                    .fill(selectedTab == tab ? Color.white.opacity(0.5) : .clear)
                    .frame(width: 2),
                alignment: .leading
            )
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
