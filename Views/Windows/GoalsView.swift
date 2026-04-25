import SwiftData
import SwiftUI

/// Goals — top-level tab. Three goal shapes (boolean / scale / numeric).
/// Goals feed MetaChat (`<active_goals>` block) and DailySummary (energy line).
/// spec://BACKLOG#Phase5.G1
struct GoalsView: View {
    @Query(
        filter: #Predicate<Goal> { !$0.isDismissed },
        sort: \Goal.createdAt,
        order: .reverse
    )
    private var goals: [Goal]

    @Environment(\.modelContext) private var modelContext
    @State private var showNewSheet = false
    @State private var editing: Goal?

    private var activeGoals: [Goal] { goals.filter { $0.isActive } }
    private var archivedGoals: [Goal] { goals.filter { !$0.isActive } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle().fill(MW.border).frame(height: MW.hairline)
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(isPresented: $showNewSheet) {
            GoalEditorSheet(existing: nil) { newGoal in
                modelContext.insert(newGoal)
                try? modelContext.save()
            }
        }
        .sheet(item: $editing) { goal in
            GoalEditorSheet(existing: goal) { _ in
                goal.updatedAt = Date()
                try? modelContext.save()
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Goals")
                .font(MW.monoTitle)
                .foregroundStyle(MW.textPrimary)
            Spacer()
            Button {
                showNewSheet = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "plus").font(.system(size: 10))
                    Text("NEW GOAL").font(MW.label).tracking(0.6)
                }
                .foregroundStyle(MW.textSecondary)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .overlay(RoundedRectangle(cornerRadius: MW.rSmall, style: .continuous).stroke(MW.border, lineWidth: 0.5))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Text("\(activeGoals.count) active")
                .font(MW.monoSm).foregroundStyle(MW.textMuted)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if goals.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(activeGoals) { goal in
                        goalCard(goal)
                    }
                    if !archivedGoals.isEmpty {
                        Text("ARCHIVED")
                            .font(MW.label).tracking(0.8)
                            .foregroundStyle(MW.textMuted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 12)
                        ForEach(archivedGoals) { goal in
                            goalCard(goal)
                        }
                    }
                }
                .padding(16)
            }
        }
    }

    // MARK: - Goal card

    private func goalCard(_ goal: Goal) -> some View {
        // Refresh progress for boolean/scale at the start of each day.
        let _ = goal.resetIfNewDay()

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: iconFor(goal))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(MW.textSecondary)
                    .frame(width: 22, height: 22)

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(goal.title)
                            .font(MW.mono)
                            .foregroundStyle(goal.isActive ? MW.textPrimary : MW.textMuted)
                            .strikethrough(!goal.isActive)
                        Spacer()
                        Text(goal.progressLabel)
                            .font(MW.monoSm)
                            .foregroundStyle(MW.textSecondary)
                    }
                    if let desc = goal.goalDescription, !desc.isEmpty {
                        Text(desc)
                            .font(MW.monoSm)
                            .foregroundStyle(MW.textMuted)
                            .lineLimit(2)
                    }
                }

                Menu {
                    Button(goal.isActive ? "Archive" : "Reactivate") {
                        goal.isActive.toggle()
                        goal.updatedAt = Date()
                        try? modelContext.save()
                    }
                    Button("Edit") { editing = goal }
                    Divider()
                    Button("Delete", role: .destructive) {
                        goal.isDismissed = true
                        goal.updatedAt = Date()
                        try? modelContext.save()
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 11))
                        .foregroundStyle(MW.textMuted)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 22, height: 22)
            }

            // Progress control (varies by goal type)
            if goal.isActive {
                progressControl(goal)
            }
        }
        .padding(12)
        .mwCard(radius: MW.rSmall, elevation: .flat)
    }

    @ViewBuilder
    private func progressControl(_ goal: Goal) -> some View {
        switch goal.goalType {
        case "boolean":
            Button {
                goal.currentValue = goal.currentValue >= 1 ? 0 : 1
                goal.lastProgressAt = Date()
                goal.updatedAt = Date()
                try? modelContext.save()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: goal.currentValue >= 1 ? "checkmark.square.fill" : "square")
                        .font(.system(size: 14))
                        .foregroundStyle(goal.currentValue >= 1 ? MW.textSecondary : MW.textMuted)
                    Text(goal.currentValue >= 1 ? "Done today" : "Mark done")
                        .font(MW.monoSm)
                        .foregroundStyle(MW.textSecondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

        case "scale":
            let lo = goal.minValue ?? 1
            let hi = goal.maxValue ?? 10
            VStack(alignment: .leading, spacing: 4) {
                Slider(
                    value: Binding(
                        get: { goal.currentValue },
                        set: { v in
                            goal.currentValue = v.rounded()
                            goal.lastProgressAt = Date()
                            goal.updatedAt = Date()
                            try? modelContext.save()
                        }
                    ),
                    in: lo...hi,
                    step: 1
                )
                .controlSize(.small)
                progressBar(goal.progressFraction)
            }

        case "numeric":
            HStack(spacing: 6) {
                Button("−5") { adjustNumeric(goal, by: -5) }.buttonStyle(.plain)
                Button("−1") { adjustNumeric(goal, by: -1) }.buttonStyle(.plain)
                progressBar(goal.progressFraction)
                Button("+1") { adjustNumeric(goal, by: 1) }.buttonStyle(.plain)
                Button("+5") { adjustNumeric(goal, by: 5) }.buttonStyle(.plain)
            }
            .font(MW.monoSm)
            .foregroundStyle(MW.textSecondary)

        default:
            EmptyView()
        }
    }

    private func progressBar(_ frac: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(MW.border.opacity(0.3))
                Rectangle()
                    .fill(MW.textSecondary.opacity(0.7))
                    .frame(width: geo.size.width * CGFloat(min(max(frac, 0), 1)))
            }
        }
        .frame(height: 4)
        .clipShape(Capsule())
    }

    private func adjustNumeric(_ goal: Goal, by delta: Double) {
        goal.currentValue = max(0, goal.currentValue + delta)
        goal.lastProgressAt = Date()
        goal.updatedAt = Date()
        try? modelContext.save()
    }

    private func iconFor(_ goal: Goal) -> String {
        switch goal.goalType {
        case "boolean": return "checkmark.circle"
        case "scale":   return "slider.horizontal.3"
        case "numeric": return "chart.bar"
        default:        return "target"
        }
    }

    // MARK: - Empty

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "target")
                .font(.system(size: 32))
                .foregroundStyle(MW.textMuted)
            Text("No goals yet")
                .font(MW.monoLg).foregroundStyle(MW.textSecondary)
            Text("Goals are persistent targets MetaWhisp tracks across the day. Three shapes: a daily checkbox, a 1-N rating, or progress toward a number.")
                .font(MW.mono).foregroundStyle(MW.textMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            Button {
                showNewSheet = true
            } label: {
                Text("CREATE FIRST GOAL").font(MW.label).tracking(0.6)
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .overlay(RoundedRectangle(cornerRadius: MW.rSmall, style: .continuous).stroke(MW.border, lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .padding(.top, 8)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Editor sheet

private struct GoalEditorSheet: View {
    /// nil = creating; non-nil = editing existing.
    let existing: Goal?
    let onSave: (Goal) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var title: String
    @State private var description: String
    @State private var goalType: String
    @State private var targetValue: String
    @State private var minValue: String
    @State private var maxValue: String
    @State private var unit: String

    init(existing: Goal?, onSave: @escaping (Goal) -> Void) {
        self.existing = existing
        self.onSave = onSave
        _title       = State(initialValue: existing?.title ?? "")
        _description = State(initialValue: existing?.goalDescription ?? "")
        _goalType    = State(initialValue: existing?.goalType ?? "boolean")
        _targetValue = State(initialValue: existing?.targetValue.map { stringFrom($0) } ?? "")
        _minValue    = State(initialValue: existing?.minValue.map { stringFrom($0) } ?? "1")
        _maxValue    = State(initialValue: existing?.maxValue.map { stringFrom($0) } ?? "10")
        _unit        = State(initialValue: existing?.unit ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(existing == nil ? "New goal" : "Edit goal")
                .font(MW.monoLg)
                .foregroundStyle(MW.textPrimary)

            VStack(alignment: .leading, spacing: 6) {
                Text("TITLE").font(MW.label).tracking(0.6).foregroundStyle(MW.textMuted)
                TextField("e.g. Write 1000 words", text: $title)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("DESCRIPTION (optional)").font(MW.label).tracking(0.6).foregroundStyle(MW.textMuted)
                TextField("Why this goal matters", text: $description)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("TYPE").font(MW.label).tracking(0.6).foregroundStyle(MW.textMuted)
                Picker("", selection: $goalType) {
                    Text("Daily checkbox").tag("boolean")
                    Text("Rating 1-N").tag("scale")
                    Text("Numeric target").tag("numeric")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            // Type-specific fields
            switch goalType {
            case "scale":
                HStack {
                    field("MIN", $minValue, width: 60)
                    field("MAX", $maxValue, width: 60)
                }
            case "numeric":
                HStack {
                    field("TARGET", $targetValue, width: 100)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("UNIT").font(MW.label).tracking(0.6).foregroundStyle(MW.textMuted)
                        TextField("words / push-ups / min", text: $unit)
                            .textFieldStyle(.roundedBorder)
                    }
                }
            default:
                EmptyView()
            }

            Spacer()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button(existing == nil ? "Create" : "Save") {
                    saveAndDismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440, height: 360)
    }

    private func field(_ label: String, _ binding: Binding<String>, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(MW.label).tracking(0.6).foregroundStyle(MW.textMuted)
            TextField("", text: binding)
                .textFieldStyle(.roundedBorder)
                .frame(width: width)
        }
    }

    private func saveAndDismiss() {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return }

        if let existing {
            existing.title = trimmedTitle
            existing.goalDescription = description.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmptyGoal
            existing.goalType = goalType
            existing.targetValue = Double(targetValue.replacingOccurrences(of: ",", with: "."))
            existing.minValue = Double(minValue.replacingOccurrences(of: ",", with: "."))
            existing.maxValue = Double(maxValue.replacingOccurrences(of: ",", with: "."))
            existing.unit = unit.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmptyGoal
            onSave(existing)
        } else {
            let goal = Goal(
                title: trimmedTitle,
                goalType: goalType,
                goalDescription: description.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmptyGoal,
                targetValue: Double(targetValue.replacingOccurrences(of: ",", with: ".")),
                currentValue: 0,
                minValue: Double(minValue.replacingOccurrences(of: ",", with: ".")),
                maxValue: Double(maxValue.replacingOccurrences(of: ",", with: ".")),
                unit: unit.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmptyGoal
            )
            onSave(goal)
        }
        dismiss()
    }
}

private func stringFrom(_ value: Double) -> String {
    if value.rounded() == value { return String(Int(value)) }
    return String(format: "%.1f", value)
}

private extension String {
    var nilIfEmptyGoal: String? { isEmpty ? nil : self }
}
