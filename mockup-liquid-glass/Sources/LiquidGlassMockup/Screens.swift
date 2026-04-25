import SwiftUI

// ==============================================================================
// MARK: - Dashboard
// ==============================================================================

struct DashboardScreen: View {
    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: Glass.s20) {
                screenHeader
                statusRow
                DailySummaryCard()
                ActivityCard()
                StatsGrid()
            }
        }
    }

    private var screenHeader: some View {
        VStack(alignment: .leading, spacing: Glass.s2) {
            Text("Dashboard")
                .font(Glass.label).tracking(1.2).textCase(.uppercase)
                .foregroundStyle(Glass.textMuted)
            Text("Good evening, Andrey")
                .font(Glass.display)
                .foregroundStyle(Glass.textPrimary)
        }
    }

    private var statusRow: some View {
        HStack(spacing: Glass.s12) {
            HStack(spacing: Glass.s8) {
                Circle().fill(Glass.statusOk).frame(width: 6, height: 6)
                    .shadow(color: Glass.statusOk.opacity(0.6), radius: 4)
                Text("Ready")
                    .font(Glass.bodyMedium)
                    .foregroundStyle(Glass.textPrimary)
                Text("Right ⌘ to dictate · long-press for MetaChat")
                    .font(Glass.caption)
                    .foregroundStyle(Glass.textMuted)
            }
            Spacer()
            HStack(spacing: Glass.s6) {
                Image(systemName: "mic.fill").font(.system(size: 10))
                Text("Record")
            }
            .font(Glass.bodyMedium)
            .foregroundStyle(Glass.textPrimary)
            .glassChip(selected: false, radius: Glass.rTiny)
        }
        .padding(.horizontal, Glass.s16)
        .padding(.vertical, Glass.s12)
        .glassPanel(radius: Glass.rMedium, elevation: .flat)
    }
}

// MARK: Daily Summary

private struct DailySummaryCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Glass.s16) {
            HStack(alignment: .firstTextBaseline) {
                Text("Today's Summary")
                    .font(Glass.h1)
                    .foregroundStyle(Glass.textPrimary)
                Spacer()
                Text("22:00")
                    .font(Glass.dataSmall)
                    .foregroundStyle(Glass.textMuted)
                HStack(spacing: Glass.s4) {
                    Image(systemName: "sparkles").font(.system(size: 10))
                    Text("Generate now")
                        .font(Glass.caption)
                }
                .foregroundStyle(Glass.textSecondary)
                .glassChip(radius: Glass.rTiny)
            }

            VStack(alignment: .leading, spacing: Glass.s8) {
                Text("Heavy MetaWhisp dev day · Overchat SEO push")
                    .font(Glass.h2)
                    .foregroundStyle(Glass.textPrimary)
                Text("Shipped three commits to MetaWhisp — Staged Tasks, Embeddings, Daily Summary — paired with the team on Atomic Bot SEO fixes, and drafted the Overchat Q2 pricing memo. Cleared the Telegram backlog and scheduled the client review for Thursday.")
                    .font(Glass.body)
                    .foregroundStyle(Glass.textSecondary)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: Glass.s8) {
                bullet("Shipped Staged Tasks review bin — 58 noise items archived")
                bullet("Backfilled 17 memories + 11 tasks with embeddings")
                bullet("Reviewed Atomic Bot backlink report with Vlad")
                bullet("Drafted Overchat Q2 pricing memo")
            }

            GlassDivider().padding(.vertical, Glass.s4)

            HStack(spacing: Glass.s24) {
                stat("3", "Conversations")
                stat("5", "Memories")
                stat("7", "Completed")
                stat("2", "New tasks")
                Spacer()
                Text("Generated 22:01")
                    .font(Glass.dataSmall)
                    .foregroundStyle(Glass.textDim)
            }
        }
        .padding(Glass.s20)
        .glassPanel(radius: Glass.rMedium, elevation: .raised)
    }

    private func bullet(_ s: String) -> some View {
        HStack(alignment: .top, spacing: Glass.s8) {
            Circle()
                .fill(Glass.textDim)
                .frame(width: 4, height: 4)
                .padding(.top, 7)
            Text(s)
                .font(Glass.body)
                .foregroundStyle(Glass.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: Glass.s2) {
            Text(value)
                .font(Glass.dataLarge)
                .foregroundStyle(Glass.textPrimary)
            Text(label)
                .font(Glass.caption)
                .foregroundStyle(Glass.textMuted)
        }
    }
}

// MARK: Activity card

private struct ActivityCard: View {
    private let apps: [(String, String, Double)] = [
        ("Xcode", "2h 14m", 0.38),
        ("Telegram", "1h 22m", 0.24),
        ("Safari", "55m", 0.16),
        ("Claude", "38m", 0.11),
        ("Notion", "26m", 0.11),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Glass.s16) {
            HStack(alignment: .firstTextBaseline) {
                Text("Last 24h on screen")
                    .font(Glass.h2)
                    .foregroundStyle(Glass.textPrimary)
                Spacer()
                Text("Top 5")
                    .font(Glass.caption)
                    .foregroundStyle(Glass.textMuted)
            }

            VStack(spacing: 0) {
                ForEach(Array(apps.enumerated()), id: \.offset) { idx, item in
                    let (name, time, ratio) = item
                    appRow(name: name, time: time, ratio: ratio)
                    if idx < apps.count - 1 { GlassDivider() }
                }
            }
        }
        .padding(Glass.s20)
        .glassPanel(radius: Glass.rMedium, elevation: .raised)
    }

    private func appRow(name: String, time: String, ratio: Double) -> some View {
        HStack(spacing: Glass.s12) {
            Text(name)
                .font(Glass.bodyMedium)
                .foregroundStyle(Glass.textPrimary)
                .frame(width: 90, alignment: .leading)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.06))
                        .frame(height: 4)
                    Capsule().fill(Color.primary.opacity(0.70))
                        .frame(width: max(4, geo.size.width * ratio), height: 4)
                }
            }
            .frame(height: 4)

            Text(time)
                .font(Glass.dataMedium)
                .foregroundStyle(Glass.textPrimary)
                .frame(width: 60, alignment: .trailing)

            Text("\(Int(ratio * 100))%")
                .font(Glass.dataSmall)
                .foregroundStyle(Glass.textMuted)
                .frame(width: 40, alignment: .trailing)
        }
        .padding(.vertical, Glass.s10)
    }
}

// MARK: Stats grid

private struct StatsGrid: View {
    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Glass.s12), count: 4),
                  spacing: Glass.s12) {
            card("Streak", "12", "days")
            card("Words", "12.4k", "this week")
            card("Tasks", "73%", "completion")
            card("Memories", "142", "total")
        }
    }

    private func card(_ label: String, _ value: String, _ sub: String) -> some View {
        VStack(alignment: .leading, spacing: Glass.s4) {
            Text(label.uppercased())
                .font(Glass.label).tracking(0.8)
                .foregroundStyle(Glass.textMuted)
            Text(value)
                .font(Glass.dataLarge)
                .foregroundStyle(Glass.textPrimary)
            Text(sub)
                .font(Glass.caption)
                .foregroundStyle(Glass.textMuted)
        }
        .padding(Glass.s16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPanel(radius: Glass.rSmall, elevation: .flat)
    }
}

// ==============================================================================
// MARK: - Tasks
// ==============================================================================

struct TasksScreen: View {
    @State private var candidatesExpanded = true

    private let staged: [(String, String, String)] = [
        ("Verify email address", "Finder", "19:02"),
        ("Set minimum balance", "ChatGPT Atlas", "18:55"),
    ]
    private let committed: [(String, Bool, String?)] = [
        ("Check new referral pages on overchat.ai", false, "Tomorrow"),
        ("Protest staged tasks flow end-to-end", false, nil),
        ("Buy milk", false, "Today"),
        ("Reply to Mike about SEO report", false, nil),
        ("Design yoga app onboarding", true, nil),
    ]

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: Glass.s20) {
                screenHeader
                if !staged.isEmpty { candidatesBin }
                mainList
            }
        }
    }

    private var screenHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: Glass.s2) {
                Text("Tasks")
                    .font(Glass.label).tracking(1.2).textCase(.uppercase)
                    .foregroundStyle(Glass.textMuted)
                HStack(alignment: .firstTextBaseline, spacing: Glass.s8) {
                    Text("\(committed.count)")
                        .font(Glass.display)
                        .foregroundStyle(Glass.textPrimary)
                    Text("active")
                        .font(Glass.h2)
                        .foregroundStyle(Glass.textMuted)
                }
            }
            Spacer()
            HStack(spacing: Glass.s4) {
                Image(systemName: "sparkles").font(.system(size: 11))
                Text("Extract now")
            }
            .font(Glass.bodyMedium)
            .foregroundStyle(Glass.textPrimary)
            .glassChip()
        }
    }

    private var candidatesBin: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { candidatesExpanded.toggle() }
            } label: {
                HStack(spacing: Glass.s8) {
                    Image(systemName: candidatesExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Glass.textMuted)
                    Text("Review candidates")
                        .font(Glass.bodyMedium)
                        .foregroundStyle(Glass.textPrimary)
                    Text("\(staged.count)")
                        .font(Glass.dataSmall)
                        .foregroundStyle(Glass.textSecondary)
                        .padding(.horizontal, Glass.s6)
                        .padding(.vertical, 1)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.primary.opacity(0.08))
                        )
                    Spacer()
                    Text("Auto-extracted from screen")
                        .font(Glass.caption)
                        .foregroundStyle(Glass.textMuted)
                }
                .padding(.horizontal, Glass.s16)
                .padding(.vertical, Glass.s12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if candidatesExpanded {
                GlassDivider()
                VStack(spacing: 0) {
                    ForEach(Array(staged.enumerated()), id: \.offset) { idx, item in
                        let (desc, app, time) = item
                        candidateRow(desc: desc, app: app, time: time)
                        if idx < staged.count - 1 { GlassDivider() }
                    }
                }
            }
        }
        .glassPanel(radius: Glass.rMedium, elevation: .flat)
    }

    private func candidateRow(desc: String, app: String, time: String) -> some View {
        HStack(spacing: Glass.s12) {
            HStack(spacing: Glass.s6) {
                iconButton("checkmark")
                iconButton("xmark", muted: true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(desc)
                    .font(Glass.body)
                    .foregroundStyle(Glass.textPrimary)
                HStack(spacing: Glass.s8) {
                    Text(app)
                        .font(Glass.caption)
                        .foregroundStyle(Glass.textMuted)
                    Circle().fill(Glass.textDim).frame(width: 2, height: 2)
                    Text(time)
                        .font(Glass.dataSmall)
                        .foregroundStyle(Glass.textMuted)
                }
            }
            Spacer()
        }
        .padding(.horizontal, Glass.s16)
        .padding(.vertical, Glass.s12)
    }

    private func iconButton(_ symbol: String, muted: Bool = false) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(muted ? Glass.textMuted : Glass.textPrimary)
            .frame(width: 24, height: 24)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
            }
    }

    private var mainList: some View {
        VStack(spacing: 0) {
            ForEach(Array(committed.enumerated()), id: \.offset) { idx, item in
                let (desc, done, due) = item
                taskRow(desc: desc, completed: done, due: due)
                if idx < committed.count - 1 { GlassDivider() }
            }
        }
        .glassPanel(radius: Glass.rMedium, elevation: .raised)
    }

    private func taskRow(desc: String, completed: Bool, due: String?) -> some View {
        HStack(spacing: Glass.s12) {
            Image(systemName: completed ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(completed ? Glass.textSecondary : Glass.textMuted)
            Text(desc)
                .font(Glass.body)
                .foregroundStyle(completed ? Glass.textMuted : Glass.textPrimary)
                .strikethrough(completed)
            Spacer()
            if let due {
                Text(due)
                    .font(Glass.caption)
                    .foregroundStyle(Glass.textSecondary)
                    .glassChip(radius: 6)
            }
            Image(systemName: "ellipsis")
                .font(.system(size: 12))
                .foregroundStyle(Glass.textDim)
        }
        .padding(.horizontal, Glass.s16)
        .padding(.vertical, Glass.s12)
    }
}

// ==============================================================================
// MARK: - Settings
// ==============================================================================

struct SettingsScreen: View {
    enum Tab: String, CaseIterable, Identifiable {
        case general = "General"
        case dictation = "Dictation"
        case ai = "AI"
        case integrations = "Integrations"
        var id: String { rawValue }
    }

    @State private var selected: Tab = .ai
    @State private var memoriesOn = true
    @State private var adviceOn = true
    @State private var summaryOn = true
    @State private var cloudTTS = true
    @State private var summaryTime = Calendar.current.date(bySettingHour: 22, minute: 0, second: 0, of: Date())!
    @State private var voice = "Nova"

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: Glass.s20) {
                screenHeader
                tabBar
                if selected == .ai {
                    aiTab
                } else {
                    placeholder
                }
            }
        }
    }

    private var screenHeader: some View {
        VStack(alignment: .leading, spacing: Glass.s2) {
            Text("Settings")
                .font(Glass.label).tracking(1.2).textCase(.uppercase)
                .foregroundStyle(Glass.textMuted)
            Text("Preferences")
                .font(Glass.display)
                .foregroundStyle(Glass.textPrimary)
        }
    }

    private var tabBar: some View {
        HStack(spacing: Glass.s6) {
            ForEach(Tab.allCases) { tab in
                Text(tab.rawValue)
                    .font(Glass.bodyMedium)
                    .foregroundStyle(selected == tab ? Glass.textPrimary : Glass.textSecondary)
                    .glassChip(selected: selected == tab, radius: Glass.rTiny)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.12)) { selected = tab }
                    }
            }
            Spacer()
        }
    }

    private var aiTab: some View {
        VStack(spacing: Glass.s16) {
            settingsGroup(title: "Memory") {
                toggleRow("Extract memories from voice & screen", binding: $memoriesOn,
                          subtitle: "Facts about you used to personalize AI Advice and MetaChat.")
            }
            settingsGroup(title: "AI Advice") {
                toggleRow("AI Advice", binding: $adviceOn,
                          subtitle: "Contextual suggestions based on screen activity and transcriptions.",
                          footnote: "Included with Pro · no API key required")
            }
            settingsGroup(title: "Daily Summary") {
                toggleRow("Generate nightly recap", binding: $summaryOn,
                          subtitle: "Summary of conversations, tasks, memories, and top apps.")
                if summaryOn {
                    GlassDivider()
                    valueRow("Scheduled time", detail: AnyView(
                        DatePicker("", selection: $summaryTime, displayedComponents: .hourAndMinute)
                            .labelsHidden()
                            .datePickerStyle(.compact)
                    ))
                }
            }
            settingsGroup(title: "Voice") {
                toggleRow("Speak answers to voice questions", binding: .constant(true))
                GlassDivider()
                toggleRow("Cloud voice", binding: $cloudTTS,
                          subtitle: "Natural voices via OpenAI · Pro required.")
                if cloudTTS {
                    GlassDivider()
                    valueRow("Voice", detail: AnyView(
                        Menu {
                            ForEach(["Alloy", "Echo", "Fable", "Onyx", "Nova", "Shimmer"], id: \.self) { v in
                                Button(v) { voice = v }
                            }
                        } label: {
                            HStack(spacing: Glass.s4) {
                                Text(voice).font(Glass.bodyMedium)
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: 9))
                            }
                            .foregroundStyle(Glass.textPrimary)
                            .glassChip(selected: false, radius: Glass.rTiny)
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                    ))
                }
            }
        }
    }

    // MARK: Settings row primitives

    private func settingsGroup<Content: View>(title: String,
                                              @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Glass.s8) {
            Text(title.uppercased())
                .font(Glass.label).tracking(1.2)
                .foregroundStyle(Glass.textMuted)
                .padding(.horizontal, Glass.s4)
            VStack(spacing: 0) {
                content()
            }
            .glassPanel(radius: Glass.rMedium, elevation: .raised)
        }
    }

    private func toggleRow(_ title: String,
                           binding: Binding<Bool>,
                           subtitle: String? = nil,
                           footnote: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Glass.s12) {
            VStack(alignment: .leading, spacing: Glass.s2) {
                Text(title)
                    .font(Glass.body)
                    .foregroundStyle(Glass.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(Glass.caption)
                        .foregroundStyle(Glass.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let footnote {
                    HStack(spacing: Glass.s6) {
                        Circle().fill(Glass.statusOk).frame(width: 5, height: 5)
                        Text(footnote)
                            .font(Glass.caption)
                            .foregroundStyle(Glass.textMuted)
                    }
                    .padding(.top, 2)
                }
            }
            Spacer(minLength: Glass.s12)
            Toggle("", isOn: binding)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .padding(.horizontal, Glass.s16)
        .padding(.vertical, Glass.s12)
    }

    private func valueRow(_ title: String, detail: AnyView) -> some View {
        HStack(spacing: Glass.s12) {
            Text(title)
                .font(Glass.body)
                .foregroundStyle(Glass.textPrimary)
            Spacer()
            detail
        }
        .padding(.horizontal, Glass.s16)
        .padding(.vertical, Glass.s10)
    }

    private var placeholder: some View {
        VStack(spacing: Glass.s8) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(Glass.textDim)
                .padding(.top, Glass.s24)
            Text("\(selected.rawValue) settings")
                .font(Glass.h2)
                .foregroundStyle(Glass.textSecondary)
            Text("Other tabs use the same grouped row style. Swap the AI tab for a preview.")
                .font(Glass.body)
                .foregroundStyle(Glass.textMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Glass.s32)
                .padding(.bottom, Glass.s32)
        }
        .frame(maxWidth: .infinity)
        .glassPanel(radius: Glass.rMedium, elevation: .raised)
    }
}

// ==============================================================================
// MARK: - MetaChat
// ==============================================================================

struct MetaChatScreen: View {
    var body: some View {
        VStack(spacing: Glass.s16) {
            header
            conversation
            composer
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: Glass.s2) {
                Text("MetaChat")
                    .font(Glass.label).tracking(1.2).textCase(.uppercase)
                    .foregroundStyle(Glass.textMuted)
                Text("Ask anything about your data")
                    .font(Glass.h1)
                    .foregroundStyle(Glass.textPrimary)
            }
            Spacer()
            HStack(spacing: Glass.s4) {
                Circle().fill(Glass.statusOk).frame(width: 6, height: 6)
                Text("Pro · Cerebras")
                    .font(Glass.caption)
            }
            .foregroundStyle(Glass.textMuted)
        }
    }

    private var conversation: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: Glass.s12) {
                bubble("what did I promise the client today?", isUser: true)
                bubble("You promised to send a revised doc to Client X by Thursday and to share the updated A/B test link. Both have been captured as Tasks — review them in the Tasks tab.",
                       isUser: false)
                bubble("who is Vasya and what does he do", isUser: true)
                bubble("Vasya is one of the developers in your network. From memory: he owns the MeetRecorder backend and recently fixed an SEO issue on Atomic Bot. Last mentioned yesterday in the Q2 planning call.",
                       isUser: false)
            }
            .padding(.vertical, Glass.s4)
        }
    }

    private func bubble(_ text: String, isUser: Bool) -> some View {
        HStack(alignment: .bottom, spacing: Glass.s8) {
            if isUser { Spacer(minLength: Glass.s40) }
            VStack(alignment: isUser ? .trailing : .leading, spacing: Glass.s4) {
                Text(text)
                    .font(Glass.body)
                    .foregroundStyle(Glass.textPrimary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Glass.s12)
                    .padding(.vertical, Glass.s10)
                    .frame(maxWidth: 480, alignment: isUser ? .trailing : .leading)
                    .background {
                        ZStack {
                            RoundedRectangle(cornerRadius: Glass.rSmall, style: .continuous)
                                .fill(isUser ? Color.primary.opacity(0.10) : Color.clear)
                            RoundedRectangle(cornerRadius: Glass.rSmall, style: .continuous)
                                .fill(.ultraThinMaterial)
                            RoundedRectangle(cornerRadius: Glass.rSmall, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: Glass.rSmall, style: .continuous))
            }
            if !isUser { Spacer(minLength: Glass.s40) }
        }
    }

    private var composer: some View {
        HStack(spacing: Glass.s10) {
            Text("Type a question…")
                .font(Glass.body)
                .foregroundStyle(Glass.textMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "mic")
                .font(.system(size: 14))
                .foregroundStyle(Glass.textSecondary)
                .frame(width: 28, height: 28)
                .glassChip(radius: Glass.rTiny)
            Image(systemName: "arrow.up")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: Glass.rTiny, style: .continuous)
                        .fill(Color.primary.opacity(0.85))
                )
        }
        .padding(.horizontal, Glass.s12)
        .padding(.vertical, Glass.s8)
        .glassPanel(radius: Glass.rMedium, elevation: .flat)
    }
}

// ==============================================================================
// MARK: - Placeholder
// ==============================================================================

struct PlaceholderScreen: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: Glass.s20) {
            VStack(alignment: .leading, spacing: Glass.s2) {
                Text(title)
                    .font(Glass.label).tracking(1.2).textCase(.uppercase)
                    .foregroundStyle(Glass.textMuted)
                Text(subtitle)
                    .font(Glass.display)
                    .foregroundStyle(Glass.textPrimary)
            }
            Spacer()
        }
    }
}
