import SwiftUI

/// Per-meeting recap popup card (2026-04-29).
///
/// Appears ~8 sec after a meeting recording stops. Shows the structured
/// title/overview/emoji, calendar binding (when matched), action items
/// (toggleable), memories, and Copy / Open-in-Library / Dismiss buttons.
struct MeetingRecapView: View {
    @ObservedObject var state: MeetingRecapState
    /// Called when user clicks Copy — controller handles clipboard write.
    var onCopy: () -> Void
    /// Called when user clicks Open in Library — controller switches main window.
    var onOpenInLibrary: () -> Void
    /// Called when user clicks Dismiss / X.
    var onDismiss: () -> Void
    /// Called when user toggles a task's checkbox — controller persists.
    var onToggleTask: (UUID) -> Void

    var body: some View {
        if let p = state.payload {
            VStack(alignment: .leading, spacing: 0) {
                header(p)
                divider
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if !p.overview.isEmpty {
                            section("ABOUT") {
                                Text(p.overview)
                                    .font(.system(size: 13))
                                    .foregroundStyle(MW.textPrimary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        // WITH — meeting participants. Calendar attendees
                        // preferred (objective EKEvent data); falls back to
                        // LLM-extracted names from transcript when calendar
                        // event has no attendees set.
                        if !p.participants.isEmpty {
                            section("WITH (\(p.participants.count))") {
                                Text(p.participants.joined(separator: ", "))
                                    .font(.system(size: 12.5))
                                    .foregroundStyle(MW.textPrimary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        if !p.decisions.isEmpty {
                            section("DECISIONS (\(p.decisions.count))") {
                                bulletList(p.decisions)
                            }
                        }
                        if !p.actionItems.isEmpty {
                            section("ACTION ITEMS (\(p.actionItems.count))") {
                                VStack(alignment: .leading, spacing: 6) {
                                    ForEach(p.actionItems) { item in
                                        actionRow(item)
                                    }
                                }
                            }
                        }
                        if !p.nextSteps.isEmpty {
                            section("NEXT STEPS (\(p.nextSteps.count))") {
                                bulletList(p.nextSteps)
                            }
                        }
                        if !p.memories.isEmpty {
                            section("MEMORIES (\(p.memories.count))") {
                                VStack(alignment: .leading, spacing: 4) {
                                    ForEach(p.memories) { mem in
                                        memoryRow(mem)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                }
                .frame(maxHeight: 380)
                divider
                actionsBar
            }
            .frame(width: 480)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: MW.rLarge, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: MW.rLarge, style: .continuous)
                    .strokeBorder(MW.border, lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.4), radius: 32, y: 16)
            .padding(40)
        }
    }

    // MARK: - Header

    private func header(_ p: MeetingRecapState.Payload) -> some View {
        HStack(alignment: .top, spacing: 10) {
            // `Conversation.emoji` is set by StructuredGenerator and may hold
            // EITHER a Unicode emoji ("📞") OR an SF Symbol name ("bubble.left").
            // Detect SF symbol by the presence of a dot in the string +
            // absence of any emoji-presentation scalar — render with
            // Image(systemName:) so the user sees a glyph, not raw text.
            if let emoji = p.emoji, !emoji.isEmpty {
                if isSFSymbolName(emoji) {
                    Image(systemName: emoji)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(MW.textSecondary)
                } else {
                    Text(emoji)
                        .font(.system(size: 22))
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(p.title.isEmpty ? "Meeting" : p.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(MW.textPrimary)
                HStack(spacing: 6) {
                    Text(formatDuration(p.durationSec))
                    if let lang = p.language, !lang.isEmpty {
                        Text("·")
                        Text(lang.uppercased())
                    }
                    // Calendar chip removed — title itself is now the calendar
                    // event name when matched, so showing the same string twice
                    // (title + chip) was redundant noise.
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(MW.textMuted)
            }
            Spacer()
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(MW.textMuted)
                    .padding(6)
                    .background(Circle().fill(MW.subtle))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    // MARK: - Body sections

    private func section<Content: View>(_ title: String, @ViewBuilder body: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 9, weight: .semibold))
                .tracking(1.4)
                .foregroundStyle(MW.textMuted)
            body()
        }
    }

    private func actionRow(_ item: MeetingRecapState.ActionItem) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Button {
                onToggleTask(item.id)
            } label: {
                Image(systemName: item.completed ? "checkmark.square.fill" : "square")
                    .font(.system(size: 14))
                    .foregroundStyle(item.completed ? Color.green : MW.textSecondary)
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.description)
                    .font(.system(size: 12.5))
                    .foregroundStyle(item.completed ? MW.textMuted : MW.textPrimary)
                    .strikethrough(item.completed)
                    .fixedSize(horizontal: false, vertical: true)
                if let a = item.assignee, !a.isEmpty {
                    Text("waiting on \(a)")
                        .font(.system(size: 9))
                        .foregroundStyle(MW.textDim)
                }
            }
            Spacer()
        }
    }

    /// Plain bullet list — used for DECISIONS and NEXT STEPS sections.
    /// Same text style as memoryRow but with `•` marker, no kind/subject
    /// structure (these are short factual bullets from StructuredGenerator).
    private func bulletList(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .top, spacing: 6) {
                    Text("•").foregroundStyle(MW.textDim)
                    Text(item)
                        .font(.system(size: 12.5))
                        .foregroundStyle(MW.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }
            }
        }
    }

    private func memoryRow(_ mem: MeetingRecapState.MemoryRow) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("•").foregroundStyle(MW.textDim)
            Group {
                if let kind = mem.kind, let subj = mem.subject, !subj.isEmpty,
                   let charact = mem.characterization, !charact.isEmpty {
                    (Text(kind.uppercased()).font(.system(size: 9, weight: .bold)).foregroundStyle(MW.textMuted)
                        + Text(" \(subj) — ").font(.system(size: 12, weight: .medium)).foregroundStyle(MW.textPrimary)
                        + Text(charact).font(.system(size: 12)).foregroundStyle(MW.textPrimary))
                } else {
                    Text(mem.content)
                        .font(.system(size: 12))
                        .foregroundStyle(MW.textPrimary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
    }

    // MARK: - Footer / actions

    private var divider: some View {
        Rectangle()
            .fill(MW.hairlineColor)
            .frame(height: 0.5)
    }

    private var actionsBar: some View {
        HStack(spacing: 8) {
            Button(action: onCopy) {
                Label("Copy", systemImage: "doc.on.doc")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(MW.textPrimary)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .glassChip(selected: false, radius: MW.rTiny)
            }
            .buttonStyle(.plain)
            Spacer()
            Button(action: onOpenInLibrary) {
                Label("Open in Library", systemImage: "arrow.up.right.square")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: MW.rTiny, style: .continuous)
                            .fill(Color.accentColor.opacity(0.85))
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Helpers

    private func formatDuration(_ sec: Double) -> String {
        let mins = Int(sec / 60)
        if mins < 60 { return "\(mins) min" }
        return "\(mins / 60)h \(mins % 60)m"
    }

    /// True if `s` looks like an SF Symbol name (e.g. "bubble.left",
    /// "phone.connection") rather than a Unicode emoji ("📞"). SF Symbol names
    /// are ASCII + dot-separated. Real emojis use codepoints in private-use
    /// emoji blocks. Cheap heuristic: ASCII + contains a dot = SF Symbol.
    private func isSFSymbolName(_ s: String) -> Bool {
        guard !s.isEmpty else { return false }
        guard s.allSatisfy({ $0.isASCII }) else { return false }
        return s.contains(".")
    }
}
