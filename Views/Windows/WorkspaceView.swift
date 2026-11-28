import SwiftUI

/// Workspace — the work-organization hub: Projects / Tasks / Goals, a pill picker over sub-views that each keep their
/// own header. It opens on Projects (owner, 2026-11-26: projects and tasks are one; FEAT-0006 §9b). A notification
/// about a task asks for Tasks through `open(_:)`, so a "Task added" tap still lands on the tasks.
struct WorkspaceView: View {
    @State private var section: Section

    init(initialSection: Section? = nil) {
        _section = State(initialValue: Self.startingSection(initialSection))
    }

    /// The section a new Workspace shows: the one asked for, else the one `open(_:)` asked for (once), else Projects.
    @MainActor static func startingSection(_ initial: Section?) -> Section {
        defer { requested = nil }
        return initial ?? requested ?? .projects
    }

    /// Liquid Glass design — TitleCase pill labels, matching the Library picker.
    enum Section: String, CaseIterable {
        case projects = "Projects"
        case tasks = "Tasks"
        case goals = "Goals"
    }

    /// The section the next Workspace shows, asked for by `open(_:)` before the window switches to it.
    @MainActor private static var requested: Section?

    /// Opens the main window on Workspace at `section` — whether Workspace is already showing or not.
    @MainActor static func open(_ section: Section) {
        requested = section
        AppDelegate.shared?.openMainWindow(tab: .workspace)
        NotificationCenter.default.post(name: .showWorkspaceSection, object: section)
    }

    var body: some View {
        VStack(spacing: 0) {
            picker
            Rectangle().fill(MW.border).frame(height: MW.hairline)

            switch section {
            case .tasks: TasksView()
            case .projects: ProjectsView()
            case .goals: GoalsView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onReceive(NotificationCenter.default.publisher(for: .showWorkspaceSection)) { note in
            if let asked = note.object as? Section {
                section = asked
                Self.requested = nil
            }
        }
    }

    /// Pill-shaped chips, same primitive + layout as `LibraryView.picker`.
    private var picker: some View {
        HStack(spacing: 8) {
            SegmentStrip(options: Section.allCases, selection: $section) { $0.rawValue }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }
}

extension Notification.Name {
    /// `WorkspaceView.open(_:)` — the Workspace on screen switches to the section in `object`.
    static let showWorkspaceSection = Notification.Name("MetaWhisp.showWorkspaceSection")
}
