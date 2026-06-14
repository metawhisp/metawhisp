import SwiftData
import SwiftUI

/// Weekly Insights — top-level tab listing every stored `PatternDigest`, newest
/// first. Each row shows ISO week number + analysed date range + a single
/// summary sentence, and expands on tap to reveal the full breakdown (themes /
/// people / stuck loops / cross-context insights) for that week.
///
/// Replaces the dead "Insights tab" the old Settings copy / weekly notification
/// pointed at (that tab was removed when Tasks was promoted out of Insights).
struct WeeklyInsightsView: View {
    @Query(sort: \PatternDigest.weekStartDate, order: .reverse)
    private var digests: [PatternDigest]

    /// Currently expanded week (nil = all collapsed). Single-open so the list
    /// stays scannable.
    @State private var expandedID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle().fill(MW.border).frame(height: MW.hairline)

            if digests.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(digests) { digest in
                            weekRow(digest)
                        }
                    }
                    .padding(16)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("WEEKLY INSIGHTS")
                .font(MW.monoLg)
                .foregroundStyle(MW.textPrimary)
                .tracking(2)
            Spacer()
            if !digests.isEmpty {
                Text("\(digests.count) \(digests.count == 1 ? "week" : "weeks")")
                    .font(MW.monoSm)
                    .foregroundStyle(MW.textMuted)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Week row (tap to expand)

    private func weekRow(_ digest: PatternDigest) -> some View {
        let isExpanded = expandedID == digest.id
        let expandable = !digest.isEmpty

        return VStack(alignment: .leading, spacing: 0) {
            Button {
                guard expandable else { return }
                withAnimation(.easeInOut(duration: 0.15)) {
                    expandedID = isExpanded ? nil : digest.id
                }
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text("Week \(WeeklyInsightFormatter.weekNumber(for: digest.weekStartDate))")
                            .font(MW.dataMedium)
                            .foregroundStyle(MW.textPrimary)
                        Text(WeeklyInsightFormatter.dateRange(weekStart: digest.weekStartDate,
                                                              windowDays: digest.windowDays))
                            .font(MW.monoSm)
                            .foregroundStyle(MW.textMuted)
                        Spacer()
                        if expandable {
                            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(MW.textMuted)
                        } else {
                            Text("QUIET")
                                .font(MW.label).tracking(0.6)
                                .foregroundStyle(MW.textDim)
                        }
                    }
                    Text(WeeklyInsightFormatter.summaryLine(
                        isEmpty: digest.isEmpty,
                        insights: digest.insights,
                        themes: digest.themes,
                        conversationsAnalyzed: digest.conversationsAnalyzed
                    ))
                    .font(MW.mono)
                    .foregroundStyle(digest.isEmpty ? MW.textMuted : MW.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!expandable)

            if isExpanded {
                detail(digest).padding(.top, 12)
            }
        }
        .padding(12)
        .mwCard(radius: MW.rSmall, elevation: .flat)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(MW.border, lineWidth: MW.hairline)
        )
    }

    // MARK: - Expanded detail

    @ViewBuilder
    private func detail(_ digest: PatternDigest) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Rectangle().fill(MW.border).frame(height: MW.hairline)

            if !digest.themes.isEmpty {
                bulletSection("THEMES", digest.themes, marker: "•", markerColor: MW.textMuted)
            }
            if !digest.people.isEmpty {
                peopleSection(digest.people)
            }
            if !digest.stuckLoops.isEmpty {
                bulletSection("STUCK LOOPS", digest.stuckLoops, marker: "•", markerColor: MW.processing)
            }
            if !digest.insights.isEmpty {
                bulletSection("CROSS-CONTEXT INSIGHTS", digest.insights, marker: "→", markerColor: MW.idle)
            }

            Text("Based on \(digest.conversationsAnalyzed) conversation\(digest.conversationsAnalyzed == 1 ? "" : "s")")
                .font(MW.monoSm)
                .foregroundStyle(MW.textDim)
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(MW.label).tracking(1.2)
            .foregroundStyle(MW.textDim)
    }

    private func bulletSection(_ label: String, _ items: [String], marker: String, markerColor: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel(label)
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .top, spacing: 8) {
                    Text(marker)
                        .font(MW.mono)
                        .foregroundStyle(markerColor)
                    Text(item)
                        .font(MW.mono)
                        .foregroundStyle(MW.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func peopleSection(_ people: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("RECURRING PEOPLE")
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 80), spacing: 6, alignment: .leading)],
                alignment: .leading,
                spacing: 6
            ) {
                ForEach(Array(people.enumerated()), id: \.offset) { _, name in
                    Text(name)
                        .font(MW.monoSm)
                        .foregroundStyle(MW.textSecondary)
                        .padding(.horizontal, 9).padding(.vertical, 3)
                        .background(MW.elevated)
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(MW.border, lineWidth: MW.hairline)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                }
            }
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "lightbulb")
                .font(.system(size: 32))
                .foregroundStyle(MW.textMuted)
            Text("No weekly insights yet")
                .font(MW.monoLg)
                .foregroundStyle(MW.textSecondary)
            Text("Every Sunday MetaWhisp recaps your week's conversations — recurring themes, people, and stuck loops. Requires Pro.")
                .font(MW.mono)
                .foregroundStyle(MW.textMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
