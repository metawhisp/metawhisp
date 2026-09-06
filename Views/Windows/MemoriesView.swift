import SwiftData
import SwiftUI

/// Browse / edit / delete user memories.
/// Independent from AI Advice — user can have memories without advice, or vice versa.
/// spec://iterations/ITER-001#architecture.ui
struct MemoriesView: View {
    @Query(
        filter: #Predicate<UserMemory> { !$0.isDismissed },
        sort: \UserMemory.createdAt,
        order: .reverse
    )
    private var memories: [UserMemory]

    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var license = LicenseService.shared
    @ObservedObject private var localLLM = LocalLLMService.shared
    @Environment(\.modelContext) private var modelContext

    @State private var selectedFilter: Filter = .all
    @State private var editingMemory: UserMemory?
    @State private var isExtracting = false
    @State private var extractionResult: String?

    enum Filter: String, CaseIterable {
        case all = "All"
        case review = "Needs review"
        case system = "System"
        case interesting = "Interesting"
    }

    /// ITER-047 Element B — generic gate (local LLM counts) for the reminder bar.
    private var hasLLMAccess: Bool {
        LLMAccess.has(apiKey: settings.activeAPIKey, isPro: license.isPro, localReady: localLLM.isReady)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !hasLLMAccess { LLMAccessBar() }
            header
            Rectangle().fill(MW.border).frame(height: MW.hairline)

            if settings.memoriesEnabled {
                filterBar
                Rectangle().fill(MW.border).frame(height: MW.hairline)

                if filteredMemories.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(filteredMemories) { memory in
                                VStack(alignment: .leading, spacing: 6) {
                                    MemoryRowView(memory: memory,
                                                  onEdit: { editingMemory = memory },
                                                  onDelete: { delete(memory) })
                                    if memory.needsReview {
                                        HStack(spacing: 8) {
                                            Text("Read off your screen — not used until you confirm")
                                                .font(MW.monoSm)
                                                .foregroundStyle(MW.textMuted)
                                            Spacer()
                                            Button("Confirm") { confirm(memory) }
                                                .buttonStyle(.borderless)
                                                .font(MW.monoSm)
                                            Button("Discard") { delete(memory) }
                                                .buttonStyle(.borderless)
                                                .font(MW.monoSm)
                                                .foregroundStyle(MW.textMuted)
                                        }
                                        .padding(.horizontal, 4)
                                    }
                                }
                            }
                        }
                        .padding(16)
                    }
                }
            } else {
                disabledState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(item: $editingMemory) { memory in
            MemoryEditSheet(memory: memory) {
                editingMemory = nil
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("MEMORIES")
                    .font(MW.monoLg)
                    .foregroundStyle(MW.textPrimary)
                    .tracking(2)
                Spacer()
                if settings.memoriesEnabled {
                    Button(action: extractNow) {
                        HStack(spacing: 4) {
                            if isExtracting {
                                ProgressView().controlSize(.mini)
                            } else {
                                Image(systemName: "sparkles").font(.system(size: 10))
                            }
                            Text(isExtracting ? "EXTRACTING…" : "EXTRACT NOW")
                                .font(MW.label).tracking(0.6)
                        }
                        .foregroundStyle(MW.textSecondary)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .overlay(RoundedRectangle(cornerRadius: MW.rSmall, style: .continuous).stroke(MW.border, lineWidth: 0.5))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isExtracting)
                }
                Toggle(isOn: $settings.memoriesEnabled) {
                    Text("COLLECT")
                        .font(MW.label).tracking(1)
                        .foregroundStyle(settings.memoriesEnabled ? MW.textPrimary : MW.textMuted)
                }
                .toggleStyle(.switch)
                .controlSize(.small)
            }
            if let result = extractionResult {
                Text(result)
                    .font(MW.monoSm)
                    .foregroundStyle(MW.textSecondary)
                    .padding(.top, 4)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func extractNow() {
        isExtracting = true
        extractionResult = nil
        let beforeCount = memories.count
        Task { @MainActor in
            guard let appDelegate = AppDelegate.shared else {
                extractionResult = "Extractor not available (SwiftUI context issue)"
                isExtracting = false
                return
            }
            await appDelegate.memoryExtractor.extractOnce()
            try? await Task.sleep(for: .milliseconds(500))
            let newCount = memories.count
            let delta = newCount - beforeCount
            NSLog("[MemoriesView] EXTRACT NOW finished — %d memories before, %d after (banner: %@)", beforeCount, newCount, delta > 0 ? "added" : "none")
            extractionResult = delta > 0
                ? "Added \(delta) new \(delta == 1 ? "memory" : "memories")"
                : "No new memories this cycle (nothing valuable to extract)"
            isExtracting = false
        }
    }

    private var filterBar: some View {
        HStack(spacing: 8) {
            ForEach(Filter.allCases, id: \.self) { filter in
                let isActive = selectedFilter == filter
                Text(filter.rawValue.uppercased())
                    .font(MW.label)
                    .tracking(0.8)
                    .foregroundStyle(isActive ? MW.textPrimary : MW.textMuted)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(isActive ? MW.elevated : .clear)
                    .overlay(Rectangle().stroke(isActive ? MW.borderLight : MW.border, lineWidth: MW.hairline))
                    .onTapGesture { selectedFilter = filter }
            }
            Spacer()
            Text("\(filteredMemories.count) memories")
                .font(MW.monoSm)
                .foregroundStyle(MW.textMuted)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private var filteredMemories: [UserMemory] {
        switch selectedFilter {
        // ITER-071.6 — proposals read off the screen are held out of the main
        // list: they are not facts about the user until the user says so.
        case .all: return memories.filter { !$0.needsReview }
        case .review: return memories.filter { $0.needsReview }
        case .system: return memories.filter { $0.category == "system" && !$0.needsReview }
        case .interesting:
            return memories.filter { $0.category == "interesting" && !$0.needsReview }
        }
    }

    /// Accept a screen-proposed fact: from here on the assistant may use it.
    private func confirm(_ memory: UserMemory) {
        do {
            try MutationService.shared.commit(.memorySaved(memory.id), in: modelContext) {
                memory.needsReview = false
                memory.updatedAt = Date()
            }
        } catch {
            NSLog("[Memories] confirm failed: %@", error.localizedDescription)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "brain")
                .font(.system(size: 32))
                .foregroundStyle(MW.textMuted)
            Text("No memories yet")
                .font(MW.monoLg)
                .foregroundStyle(MW.textSecondary)
            Text("Memories are extracted automatically from your screen activity and voice transcriptions every 10 minutes.")
                .font(MW.mono)
                .foregroundStyle(MW.textMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var disabledState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "brain")
                .font(.system(size: 32))
                .foregroundStyle(MW.textMuted)
            Text("Memory collection is off")
                .font(MW.monoLg)
                .foregroundStyle(MW.textSecondary)
            Text("Turn on COLLECT above to let MetaWhisp learn facts about you for personalized advice.")
                .font(MW.mono)
                .foregroundStyle(MW.textMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func delete(_ memory: UserMemory) {
        // SB-3 / AUD-030 — soft dismiss AND remove the vault file (only on a
        // successful save). Previously the Obsidian .md lingered forever.
        do {
            try MutationService.shared.commit(.memoryDismissed(memory.id), in: modelContext) {
                memory.isDismissed = true
                memory.updatedAt = Date()
            }
        } catch {
            NSLog("[MemoriesView] dismiss save failed: %@", error.localizedDescription)
        }
    }
}

// MARK: - Row

private struct MemoryRowView: View {
    let memory: UserMemory
    let onEdit: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(memory.category.uppercased())
                    .font(MW.label).tracking(0.6)
                    .foregroundStyle(MW.textSecondary)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(MW.elevated)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                Text(memory.sourceApp)
                    .font(MW.monoSm)
                    .foregroundStyle(MW.textMuted)
                    .lineLimit(1)
                Spacer()
                Text(memory.createdAt.formatted(date: .abbreviated, time: .omitted))
                    .font(MW.monoSm)
                    .foregroundStyle(MW.textMuted)
                if isHovered {
                    Button(action: onEdit) {
                        Image(systemName: "pencil")
                            .font(.system(size: 10))
                            .foregroundStyle(MW.textSecondary)
                    }
                    .buttonStyle(.plain)
                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .font(.system(size: 10))
                            .foregroundStyle(.red.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                }
            }
            Text(memory.content)
                .font(MW.mono)
                .foregroundStyle(MW.textPrimary)
        }
        .padding(10)
        .mwCard(radius: MW.rSmall, elevation: .flat)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Edit sheet

private struct MemoryEditSheet: View {
    @Bindable var memory: UserMemory
    let onDismiss: () -> Void

    @Environment(\.modelContext) private var modelContext
    @State private var editedContent: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("EDIT MEMORY").font(MW.monoLg).tracking(1.5).foregroundStyle(MW.textPrimary)
                Spacer()
                Button(action: onDismiss) {
                    Image(systemName: "xmark").font(.system(size: 11)).foregroundStyle(MW.textMuted)
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 6) {
                Text(memory.category.uppercased())
                    .font(MW.label).tracking(0.6)
                    .foregroundStyle(MW.textSecondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(MW.elevated)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                Text("from \(memory.sourceApp)")
                    .font(MW.monoSm).foregroundStyle(MW.textMuted)
            }

            TextEditor(text: $editedContent)
                .font(MW.mono)
                .foregroundStyle(MW.textPrimary)
                .padding(8)
                .frame(minHeight: 80)
                .overlay(RoundedRectangle(cornerRadius: MW.rSmall, style: .continuous).stroke(MW.border, lineWidth: 0.5))

            Text("Keep memories concise (max 15 words). Start system facts with 'User'.")
                .font(MW.monoSm).foregroundStyle(MW.textMuted)

            HStack {
                Spacer()
                Button("Cancel", action: onDismiss)
                    .font(MW.mono)
                Button("Save") {
                    // SB-3 — re-export the edited memory to the vault + refresh MCP
                    // on a successful save.
                    do {
                        try MutationService.shared.commit(.memorySaved(memory.id), in: modelContext) {
                            memory.content = editedContent
                            memory.updatedAt = Date()
                        }
                    } catch {
                        NSLog("[MemoriesView] edit save failed: %@", error.localizedDescription)
                    }
                    onDismiss()
                }
                .font(MW.mono)
                .keyboardShortcut(.return)
            }
        }
        .padding(16)
        .frame(width: 480)
        .onAppear { editedContent = memory.content }
    }
}
