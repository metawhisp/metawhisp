import AppKit
import SwiftData
import SwiftUI

/// Full conversation detail view (ITER-021).
///
/// Replaces the previous inline-expand pattern in `ConversationsView` for a
/// dedicated push-navigation surface. Layout:
///
/// - Header: emoji + title + category/project chips + status + dates
/// - Action bar: REGENERATE / STAR / DISCARD
/// - Tabs: SUMMARY / TRANSCRIPT / LINKED
///   - SUMMARY tab — overview + 5 structured sections (decisions / action items /
///     participants / key quotes / next steps). Empty sections hidden.
///   - TRANSCRIPT tab — full scrollable + selectable text.
///   - LINKED tab — pending tasks (split MY / WAITING-ON via ITER-013) + memories.
///
/// Source-of-truth fix for the user-reported "Quick note + (empty)" bug:
/// REGENERATE button calls `StructuredGenerator.regenerate(_:)` which fully
/// resets and re-runs the LLM path. Combined with the expanded launch backfill +
/// new 30-min periodic backfill, conversations should never stay stuck on
/// placeholder fields silently.
///
/// spec://iterations/ITER-021-structured-summary
struct ConversationDetailView: View {
    let conversationId: UUID

    @Environment(\.modelContext) private var modelContext

    @State private var conversation: Conversation?
    @State private var transcript: [HistoryItem] = []
    @State private var linkedTasks: [TaskItem] = []
    @State private var linkedMemories: [UserMemory] = []
    @State private var selectedTab: Tab = .summary
    @State private var isRegenerating = false
    @State private var lastError: String?
    /// ITER-037-followup (2026-05-12) — interactive project assign.
    /// `existingProjects` populated once on appear from distinct values
    /// across all Conversations + UserMemories, so the picker shows
    /// what's already in use as one-click options. `showingNewProjectAlert`
    /// gates the «+ New project» modal.
    @State private var existingProjects: [String] = []
    @State private var showingNewProjectAlert = false
    @State private var newProjectName: String = ""
    /// 2026-05-29 — one-click copy feedback + on-demand action-plan generation.
    @State private var copiedFlash = false
    @State private var actionPlan: String?
    @State private var isGeneratingPlan = false
    @State private var planCopiedFlash = false

    /// Full transcript as one plain-text block — feeds both the COPY button
    /// and the action-plan LLM input.
    private var fullTranscriptText: String {
        ConversationTextAssembler.plainTranscript(transcript.map { $0.displayText })
    }

    private func copyToClipboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    private enum Tab: String, CaseIterable {
        case summary = "SUMMARY"
        case transcript = "TRANSCRIPT"
        case linked = "LINKED"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let conv = conversation {
                header(conv)
                Rectangle().fill(MW.border).frame(height: MW.hairline)
                tabBar
                Rectangle().fill(MW.border).frame(height: MW.hairline)
                ScrollView {
                    VStack(alignment: .leading, spacing: MW.sp16) {
                        switch selectedTab {
                        case .summary:    summaryTab(conv)
                        case .transcript: transcriptTab
                        case .linked:     linkedTab
                        }
                    }
                    .padding(MW.sp16)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: conversationId) {
            await reload()
            loadExistingProjects()  // ITER-037-followup — populate project picker
        }
    }

    // MARK: - Header

    private func header(_ conv: Conversation) -> some View {
        VStack(alignment: .leading, spacing: MW.sp10) {
            HStack(alignment: .center, spacing: MW.sp10) {
                Image(systemName: conv.emoji ?? "bubble.left")
                    .font(.system(size: 22))
                    .foregroundStyle(MW.textSecondary)
                    .frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(conv.title ?? (conv.status == "inProgress" ? "In progress…" : "Untitled"))
                        .font(MW.monoTitle)
                        .foregroundStyle(MW.textPrimary)
                        .lineLimit(2)
                    HStack(spacing: 6) {
                        if let cat = conv.category, !cat.isEmpty, cat != "other" {
                            chip(cat.uppercased())
                        }
                        projectMenu(conv)
                        chip(conv.source.uppercased())
                        Text(conv.startedAt.formatted(date: .abbreviated, time: .shortened))
                            .font(MW.monoSm)
                            .foregroundStyle(MW.textMuted)
                    }
                }
                Spacer()
                actionBar(conv)
            }
            if let ov = conv.overview, !ov.isEmpty, ov != "(empty)" {
                Text(ov)
                    .font(MW.mono)
                    .foregroundStyle(MW.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let err = lastError {
                Text(err)
                    .font(MW.monoSm)
                    .foregroundStyle(.red.opacity(0.85))
            }
        }
        .padding(.horizontal, MW.sp20)
        .padding(.vertical, MW.sp16)
    }

    private func actionBar(_ conv: Conversation) -> some View {
        HStack(spacing: 6) {
            // 2026-05-29 — one-click copy of the whole transcript (no select-all).
            Button {
                copyToClipboard(fullTranscriptText)
                copiedFlash = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copiedFlash = false }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: copiedFlash ? "checkmark" : "doc.on.doc").font(.system(size: 10))
                    Text(copiedFlash ? "COPIED" : "COPY")
                        .font(MW.label).tracking(0.6)
                }
                .foregroundStyle(MW.textSecondary)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .overlay(RoundedRectangle(cornerRadius: MW.rSmall, style: .continuous).stroke(MW.border, lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .disabled(transcript.isEmpty)
            .help("Copy the full transcript to the clipboard")

            // 2026-05-29 — generate meeting write-up + action-plan in-app.
            Button {
                Task { await generatePlan(conv) }
            } label: {
                HStack(spacing: 4) {
                    if isGeneratingPlan {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "checklist").font(.system(size: 10))
                    }
                    Text(isGeneratingPlan ? "WRITING…" : "PLAN")
                        .font(MW.label).tracking(0.6)
                }
                .foregroundStyle(MW.textSecondary)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .overlay(RoundedRectangle(cornerRadius: MW.rSmall, style: .continuous).stroke(MW.border, lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .disabled(isGeneratingPlan || transcript.isEmpty)
            .help("Generate a meeting summary + action plan from the transcript")

            Button {
                Task { await regenerate() }
            } label: {
                HStack(spacing: 4) {
                    if isRegenerating {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.clockwise").font(.system(size: 10))
                    }
                    Text(isRegenerating ? "REGENERATING…" : "REGENERATE")
                        .font(MW.label).tracking(0.6)
                }
                .foregroundStyle(MW.textSecondary)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .overlay(RoundedRectangle(cornerRadius: MW.rSmall, style: .continuous).stroke(MW.border, lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .disabled(isRegenerating)

            Button {
                conv.starred.toggle()
                conv.updatedAt = Date()
                try? modelContext.save()
            } label: {
                Image(systemName: conv.starred ? "star.fill" : "star")
                    .font(.system(size: 12))
                    .foregroundStyle(conv.starred ? MW.textSecondary : MW.textMuted)
                    .padding(6)
                    .overlay(RoundedRectangle(cornerRadius: MW.rSmall, style: .continuous).stroke(MW.border, lineWidth: 0.5))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Tab bar

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases, id: \.self) { t in
                Button {
                    withAnimation(.easeInOut(duration: 0.12)) { selectedTab = t }
                } label: {
                    Text(t.rawValue)
                        .font(MW.label).tracking(0.6)
                        .foregroundStyle(selectedTab == t ? MW.textPrimary : MW.textMuted)
                        .padding(.vertical, 10)
                        .padding(.horizontal, 14)
                        .frame(maxWidth: .infinity)
                        .background(
                            Rectangle()
                                .fill(MW.textPrimary)
                                .frame(height: 2)
                                .opacity(selectedTab == t ? 1 : 0)
                                .padding(.top, 32),
                            alignment: .bottom
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, MW.sp20)
    }

    // MARK: - SUMMARY tab

    private func summaryTab(_ conv: Conversation) -> some View {
        VStack(alignment: .leading, spacing: MW.sp16) {
            if let plan = actionPlan {
                actionPlanCard(plan)
            }
            section(label: "DECISIONS", icon: "checkmark.circle", items: conv.decisions)
            section(label: "ACTION ITEMS", icon: "arrow.forward.circle", items: conv.actionItems)
            participantsSection(conv.participants)
            quotesSection(conv.keyQuotes)
            section(label: "NEXT STEPS", icon: "arrow.uturn.right", items: conv.nextSteps)
            if conv.decisions.isEmpty && conv.actionItems.isEmpty
                && conv.participants.isEmpty && conv.keyQuotes.isEmpty
                && conv.nextSteps.isEmpty {
                emptySummary(conv)
            }
        }
    }

    private func section(label: String, icon: String, items: [String]) -> some View {
        Group {
            if !items.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: icon).font(.system(size: 11)).foregroundStyle(MW.textMuted)
                        Text(label).font(MW.label).tracking(0.6).foregroundStyle(MW.textMuted)
                    }
                    ForEach(items, id: \.self) { item in
                        HStack(alignment: .top, spacing: 8) {
                            Text("•").font(MW.mono).foregroundStyle(MW.textMuted)
                            Text(item).font(MW.mono).foregroundStyle(MW.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer()
                        }
                    }
                }
                .padding(MW.sp12)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .mwCard(radius: MW.rMedium, elevation: .raised)
            }
        }
    }

    private func participantsSection(_ items: [String]) -> some View {
        Group {
            if !items.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "person.2").font(.system(size: 11)).foregroundStyle(MW.textMuted)
                        Text("PARTICIPANTS").font(MW.label).tracking(0.6).foregroundStyle(MW.textMuted)
                    }
                    HStack(spacing: 6) {
                        ForEach(items, id: \.self) { name in
                            Text(name)
                                .font(MW.monoSm)
                                .foregroundStyle(MW.textPrimary)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .overlay(RoundedRectangle(cornerRadius: MW.rSmall, style: .continuous).stroke(MW.border, lineWidth: 0.5))
                        }
                        Spacer()
                    }
                }
                .padding(MW.sp12)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .mwCard(radius: MW.rMedium, elevation: .raised)
            }
        }
    }

    private func quotesSection(_ items: [String]) -> some View {
        Group {
            if !items.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "quote.opening").font(.system(size: 11)).foregroundStyle(MW.textMuted)
                        Text("KEY QUOTES").font(MW.label).tracking(0.6).foregroundStyle(MW.textMuted)
                    }
                    ForEach(items, id: \.self) { quote in
                        Text("\u{201C}\(quote)\u{201D}")
                            .font(MW.mono.italic())
                            .foregroundStyle(MW.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.leading, 12)
                            .overlay(
                                Rectangle()
                                    .fill(MW.border)
                                    .frame(width: 2)
                                    .padding(.vertical, 2),
                                alignment: .leading
                            )
                    }
                }
                .padding(MW.sp12)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .mwCard(radius: MW.rMedium, elevation: .raised)
            }
        }
    }

    /// 2026-05-29 — the generated meeting write-up + action plan. Shown at the
    /// top of SUMMARY after the user taps PLAN. Monospace + selectable, with a
    /// one-tap copy of the whole plan (markdown the user can paste anywhere).
    private func actionPlanCard(_ plan: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "checklist").font(.system(size: 11)).foregroundStyle(MW.textSecondary)
                Text("MEETING + ACTION PLAN").font(MW.label).tracking(0.6).foregroundStyle(MW.textSecondary)
                Spacer()
                Button {
                    copyToClipboard(plan)
                    planCopiedFlash = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { planCopiedFlash = false }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: planCopiedFlash ? "checkmark" : "doc.on.doc").font(.system(size: 10))
                        Text(planCopiedFlash ? "COPIED" : "COPY").font(MW.label).tracking(0.6)
                    }
                    .foregroundStyle(MW.textSecondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .overlay(RoundedRectangle(cornerRadius: MW.rSmall, style: .continuous).stroke(MW.border, lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                Button {
                    actionPlan = nil
                } label: {
                    Image(systemName: "xmark").font(.system(size: 10)).foregroundStyle(MW.textMuted)
                        .padding(4)
                }
                .buttonStyle(.plain)
                .help("Dismiss the plan")
            }
            Text(plan)
                .font(MW.mono)
                .foregroundStyle(MW.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(MW.sp12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .mwCard(radius: MW.rMedium, elevation: .raised)
    }

    private func emptySummary(_ conv: Conversation) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "sparkles").font(.system(size: 22)).foregroundStyle(MW.textMuted)
            Text("No structured summary yet")
                .font(MW.mono).foregroundStyle(MW.textSecondary)
            Text(conv.title == "Quick note"
                 ? "This conversation needs to be regenerated. Click REGENERATE in the header."
                 : "Sections appear here once the LLM extracts decisions, action items, quotes, etc. Try REGENERATE if it's been a while.")
                .font(MW.monoSm).foregroundStyle(MW.textMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
    }

    // MARK: - TRANSCRIPT tab

    private var transcriptTab: some View {
        Group {
            if transcript.isEmpty {
                Text("No transcript items linked.")
                    .font(MW.monoSm)
                    .foregroundStyle(MW.textMuted)
            } else {
                VStack(alignment: .leading, spacing: MW.sp10) {
                    Text("\(transcript.count) item\(transcript.count == 1 ? "" : "s") · \(totalChars) chars")
                        .font(MW.label).tracking(0.6)
                        .foregroundStyle(MW.textMuted)
                    ForEach(transcript) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text(item.createdAt.formatted(date: .omitted, time: .shortened))
                                    .font(MW.monoSm).foregroundStyle(MW.textMuted)
                                if let lang = item.language, !lang.isEmpty {
                                    Text(lang.uppercased())
                                        .font(MW.label).tracking(0.6)
                                        .foregroundStyle(MW.textMuted)
                                }
                                Spacer()
                            }
                            Text(item.displayText)
                                .font(MW.mono)
                                .foregroundStyle(MW.textPrimary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(MW.sp12)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .mwCard(radius: MW.rSmall, elevation: .flat)
                    }
                }
            }
        }
    }

    private var totalChars: Int {
        transcript.reduce(0) { $0 + $1.displayText.count }
    }

    // MARK: - LINKED tab

    private var linkedTab: some View {
        VStack(alignment: .leading, spacing: MW.sp16) {
            // Tasks split by ownership (ITER-013).
            let myTasks = linkedTasks.filter { $0.isMyTask && !$0.completed }
            let waitingMap = Dictionary(grouping: linkedTasks.filter { !$0.isMyTask && !$0.completed }) {
                ($0.assignee ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if !myTasks.isEmpty {
                taskSection(label: "MY TASKS", tasks: myTasks)
            }
            ForEach(waitingMap.keys.sorted(), id: \.self) { name in
                if let group = waitingMap[name], !name.isEmpty {
                    taskSection(label: "WAITING ON \(name.uppercased())", tasks: group)
                }
            }
            if !linkedMemories.isEmpty {
                memoriesSection
            }
            if linkedTasks.isEmpty && linkedMemories.isEmpty {
                Text("No tasks or memories extracted from this conversation.")
                    .font(MW.monoSm).foregroundStyle(MW.textMuted)
            }
        }
    }

    private func taskSection(label: String, tasks: [TaskItem]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(MW.label).tracking(0.6).foregroundStyle(MW.textMuted)
            ForEach(tasks) { t in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "circle").font(.system(size: 11)).foregroundStyle(MW.textMuted)
                    Text(t.taskDescription).font(MW.mono).foregroundStyle(MW.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }
            }
        }
        .padding(MW.sp12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .mwCard(radius: MW.rMedium, elevation: .raised)
    }

    private var memoriesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("MEMORIES").font(MW.label).tracking(0.6).foregroundStyle(MW.textMuted)
            ForEach(linkedMemories) { m in
                VStack(alignment: .leading, spacing: 2) {
                    if let h = m.headline, !h.isEmpty {
                        Text(h).font(MW.mono).foregroundStyle(MW.textPrimary).lineLimit(1)
                    }
                    Text(m.content).font(MW.monoSm).foregroundStyle(MW.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(MW.sp12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .mwCard(radius: MW.rMedium, elevation: .raised)
    }

    // MARK: - Bits

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(MW.label).tracking(0.6)
            .foregroundStyle(MW.textMuted)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).stroke(MW.border, lineWidth: 0.5))
    }

    // MARK: - Project picker (ITER-037-followup)

    /// Inline menu replacing the read-only project chip. User can re-assign
    /// the conversation's `primaryProject` from any value already in use OR
    /// add a new one via the «+ New project» modal. Clearing the project
    /// sets the field back to nil → ObsidianExporter will route future
    /// voice exports to `voices/<HHhMM>--Untagged.md`.
    @ViewBuilder
    private func projectMenu(_ conv: Conversation) -> some View {
        let label = conv.primaryProject?.isEmpty == false ? "📁 \(conv.primaryProject!)" : "📁 No project"
        Menu {
            ForEach(existingProjects, id: \.self) { proj in
                Button {
                    setProject(conv, proj.isEmpty ? nil : proj)
                } label: {
                    if conv.primaryProject == proj {
                        Label(proj, systemImage: "checkmark")
                    } else {
                        Text(proj)
                    }
                }
            }
            Divider()
            Button("+ New project…") {
                newProjectName = ""
                showingNewProjectAlert = true
            }
            if conv.primaryProject != nil {
                Button("Clear project", role: .destructive) {
                    setProject(conv, nil)
                }
            }
        } label: {
            Text(label)
                .font(MW.label).tracking(0.6)
                .foregroundStyle(MW.textMuted)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).stroke(MW.border, lineWidth: 0.5))
        }
        .menuStyle(.borderlessButton)
        .alert("New project name", isPresented: $showingNewProjectAlert) {
            TextField("e.g. MetaWhisp", text: $newProjectName)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                let trimmed = newProjectName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    setProject(conv, trimmed)
                    if !existingProjects.contains(trimmed) {
                        existingProjects.append(trimmed)
                        existingProjects.sort()
                    }
                }
            }
        }
    }

    /// Persist project change + trigger Obsidian re-export so the vault
    /// files for this conversation's HistoryItems move to the new project
    /// folder. Old project's folder files are left in place — user can
    /// click «Export everything» in Settings later to rebuild from scratch.
    private func setProject(_ conv: Conversation, _ newProject: String?) {
        conv.primaryProject = newProject
        conv.updatedAt = Date()
        try? modelContext.save()
        // Re-export every HistoryItem in this conversation so voices land
        // in the right project folder.
        let convID = conv.id
        Task { @MainActor in
            guard let exporter = AppDelegate.shared?.obsidianExporter else { return }
            for item in transcript {
                await exporter.exportHistoryItem(item.id)
            }
            // If it's a meeting, re-export the meeting summary too.
            if conv.source == "meeting" {
                await exporter.exportConversation(convID)
            }
        }
    }

    /// Populate `existingProjects` from distinct values across Conversations
    /// and UserMemories. Sorted, deduped, empty/nil filtered.
    private func loadExistingProjects() {
        var seen = Set<String>()
        let convDesc = FetchDescriptor<Conversation>()
        if let convs = try? modelContext.fetch(convDesc) {
            for c in convs {
                if let p = c.primaryProject?.trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty {
                    seen.insert(p)
                }
            }
        }
        let memDesc = FetchDescriptor<UserMemory>()
        if let mems = try? modelContext.fetch(memDesc) {
            for m in mems {
                if let p = m.project?.trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty {
                    seen.insert(p)
                }
            }
        }
        existingProjects = Array(seen).sorted { $0.lowercased() < $1.lowercased() }
    }

    // MARK: - Data

    private func reload() async {
        var convDesc = FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == conversationId })
        convDesc.fetchLimit = 1
        conversation = try? modelContext.fetch(convDesc).first
        let id = conversationId
        // AUD-016 — no cap: COPY and PLAN treat this as the FULL transcript, so a
        // conversation with more than 200 fragments must not silently lose its
        // tail. The predicate is already conversation-scoped, so this stays cheap.
        let histDesc = FetchDescriptor<HistoryItem>(
            predicate: #Predicate { $0.conversationId == id },
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )
        transcript = (try? modelContext.fetch(histDesc)) ?? []
        let taskDesc = FetchDescriptor<TaskItem>(
            predicate: #Predicate { !$0.isDismissed && $0.conversationId == id },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        linkedTasks = (try? modelContext.fetch(taskDesc)) ?? []
        let memDesc = FetchDescriptor<UserMemory>(
            predicate: #Predicate { !$0.isDismissed && $0.conversationId == id },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        linkedMemories = (try? modelContext.fetch(memDesc)) ?? []
    }

    private func regenerate() async {
        guard let appDelegate = AppDelegate.shared else { return }
        isRegenerating = true
        defer { isRegenerating = false }
        lastError = nil
        await appDelegate.structuredGenerator.regenerate(conversationId: conversationId)
        await reload()
        if let conv = conversation,
           conv.title == "Quick note" || (conv.overview ?? "") == "(empty)" {
            lastError = "Regenerate produced no useful output. The transcript may be too short or the LLM proxy is unavailable."
        }
    }

    /// 2026-05-29 — generate "meeting write-up + action plan" from the
    /// transcript via `StructuredGenerator.generateActionPlan` (heavy tier).
    /// Result renders in a card with its own copy button; the user no longer
    /// pastes the transcript into ChatGPT by hand.
    private func generatePlan(_ conv: Conversation) async {
        guard let appDelegate = AppDelegate.shared else { return }
        isGeneratingPlan = true
        defer { isGeneratingPlan = false }
        lastError = nil
        actionPlan = nil
        do {
            let plan = try await appDelegate.structuredGenerator.generateActionPlan(
                transcript: fullTranscriptText,
                title: conv.title
            )
            actionPlan = plan
            // Plan is most useful next to the structured summary.
            selectedTab = .summary
        } catch {
            lastError = "Couldn't generate the plan: \(error.localizedDescription)"
        }
    }
}
