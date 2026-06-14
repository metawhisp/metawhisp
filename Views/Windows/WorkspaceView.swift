import SwiftUI

/// Workspace — single hub for the work-organization surfaces. Sub-sections:
/// Tasks / Projects / Goals. Consolidates three former top-level sidebar tabs
/// into one, mirroring the Library hub pattern: a top pill picker over sub-views
/// that each keep their own header + filters. Workspace adds only the picker.
///
/// Default sub-section is Tasks, so deep-links that previously opened the Tasks
/// tab (`openMainWindow(tab: .workspace)`) land exactly where they used to.
struct WorkspaceView: View {
    @State private var section: Section = .tasks

    /// Liquid Glass design — TitleCase pill labels, matching the Library picker.
    enum Section: String, CaseIterable {
        case tasks = "Tasks"
        case projects = "Projects"
        case goals = "Goals"
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
    }

    /// Pill-shaped chips, same primitive + layout as `LibraryView.picker`.
    private var picker: some View {
        HStack(spacing: 8) {
            ForEach(Section.allCases, id: \.self) { s in
                GlassChipButton(
                    label: s.rawValue,
                    isActive: section == s,
                    radius: 999,
                    action: { section = s }
                )
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }
}
