import SwiftData
import SwiftUI

/// "About Me" sheet — shows what the app has learned about the USER
/// (2026-04-29). Lives behind the "About me" button in the Conversations
/// header. Reads `UserProfileService.currentSections` to render groups.
///
/// Excludes `kind == "person"` memories — those are about other people, not
/// the user. So Sam / Alex / etc don't show up here; only memories with
/// the user as subject (projects they build, preferences, decisions, facts).
struct AboutMeView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var sections: [UserProfileService.Section] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().background(MW.hairlineColor)
            if sections.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(sections) { section in
                            sectionView(section)
                        }
                    }
                    .padding(20)
                }
            }
        }
        .frame(width: 560, height: 640)
        .background(MW.bg)
        .onAppear { reload() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("About me")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(MW.textPrimary)
                Text("What MetaWhisp has learned about you")
                    .font(MW.monoSm)
                    .foregroundStyle(MW.textMuted)
            }
            Spacer()
            Button {
                reload()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12))
                    .foregroundStyle(MW.textSecondary)
                    .padding(8)
                    .background(Circle().fill(MW.subtle))
            }
            .buttonStyle(.plain)
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(MW.textMuted)
                    .padding(8)
                    .background(Circle().fill(MW.subtle))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "person.crop.circle.dashed")
                .font(.system(size: 38))
                .foregroundStyle(MW.textDim)
            Text("Nothing yet")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(MW.textPrimary)
            Text("Memories about you appear here as you talk, record meetings, and connect Apple Notes / Calendar / Files.")
                .font(MW.monoSm)
                .foregroundStyle(MW.textMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func sectionView(_ section: UserProfileService.Section) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(section.title.uppercased())
                    .font(.system(size: 9, weight: .bold))
                    .tracking(1.4)
                    .foregroundStyle(MW.textMuted)
                Text("(\(section.entries.count))")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(MW.textDim)
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(section.entries) { entry in
                    entryRow(entry)
                }
            }
        }
    }

    private func entryRow(_ entry: UserProfileService.Entry) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•").foregroundStyle(MW.textDim)
            VStack(alignment: .leading, spacing: 2) {
                if let subj = entry.subject, !subj.isEmpty,
                   let charact = entry.characterization, !charact.isEmpty {
                    (Text(subj).font(.system(size: 13, weight: .semibold))
                        + Text(" — ").font(.system(size: 13))
                        + Text(charact).font(.system(size: 13)))
                        .foregroundStyle(MW.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(entry.content)
                        .font(.system(size: 13))
                        .foregroundStyle(MW.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("\(entry.sourceApp) · \(relativeAge(entry.createdAt))")
                    .font(.system(size: 9))
                    .foregroundStyle(MW.textDim)
            }
            Spacer()
        }
    }

    // MARK: - Helpers

    private func reload() {
        guard let app = AppDelegate.shared else { return }
        sections = UserProfileService.currentSections(in: app.historyService.modelContainer)
    }

    private func relativeAge(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
