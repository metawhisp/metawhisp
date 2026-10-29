import SwiftUI

struct MeetingCoachCapsuleView: View {
    @ObservedObject var presentation: MeetingCoachPresentation
    @ObservedObject var state: MeetingCoachState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var snapshot: MeetingCoachRenderSnapshot? = nil
    var wave: MeetingCoachWaveModel?
    var recordingStartedAt: () -> Date? = { nil }
    var onStop: () -> Void = {}
    var onHide: () -> Void = {}
    /// Allows offscreen accessibility checks without changing system preferences.
    var reduceMotionOverride: Bool? = nil

    private var expanded: Bool { snapshot?.isExpanded ?? presentation.isExpanded }

    var body: some View {
        HStack(spacing: expanded ? 8 : 10) {
            Circle().fill(Color.red).frame(width: 7, height: 7)
            HStack(spacing: 4) {
                MeetingCoachElapsedView(recordingStartedAt: recordingStartedAt)
                if (snapshot?.hasUnseenAnswer ?? state.hasUnseenAnswer) {
                    Circle().fill(MW.textSecondary).frame(width: 4, height: 4)
                        .accessibilityLabel("Unseen answer")
                }
            }
            .fixedSize()
            Rectangle().fill(MW.border).frame(width: 0.5, height: 16)
            Group {
                if expanded {
                    HStack(spacing: 8) {
                        if !(snapshot?.isStopping ?? state.isStopping) {
                            MeetingCoachButton(title: (snapshot?.panelHidden ?? state.panelHidden) ? "Show" : "Hide", action: onHide)
                        }
                        MeetingCoachButton(title: (snapshot?.isStopping ?? state.isStopping) ? "Stopping…" : "Stop",
                                           isEnabled: !(snapshot?.isStopping ?? state.isStopping), isStop: true, action: onStop)
                            .padded(horizontal: 5, vertical: 3)
                            .background(Color.red.opacity(0.12), in: Capsule())
                    }
                    .transition(.opacity)
                } else {
                    HStack(spacing: 10) {
                        if let wave { MeetingCoachWaveView(model: wave) }
                        MeetingCoachSpeakerView(model: state.speakerModel)
                    }
                    .transition(.opacity)
                }
            }
            .animation(snapshot != nil || (reduceMotionOverride ?? reduceMotion) ? .easeOut(duration: 0.18) : nil,
                       value: expanded)
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(MW.textPrimary)
        .padding(.horizontal, 12)
        .frame(width: expanded ? 208 : 168, height: 34)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(MW.border, lineWidth: 0.5))
        .overlay(alignment: .top) {
            Capsule().fill(.white.opacity(0.25)).frame(width: expanded ? 174 : 134, height: 0.5)
                .padding(.top, 0.5)
        }
    }

    static func elapsed(startedAt: Date?, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(startedAt ?? now)))
        return "\(seconds / 60):\(String(format: "%02d", seconds % 60))"
    }
}

private struct MeetingCoachElapsedView: View {
    let recordingStartedAt: () -> Date?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            Text(MeetingCoachCapsuleView.elapsed(startedAt: recordingStartedAt(), now: timeline.date))
                .monospacedDigit().lineLimit(1)
        }
    }
}

private struct MeetingCoachSpeakerView: View {
    @ObservedObject var model: MeetingCoachSpeakerModel

    var body: some View {
        if let label = model.speaker.label {
            Text(label).foregroundStyle(MW.textSecondary).lineLimit(1).fixedSize()
        }
    }
}

private struct MeetingCoachWaveView: View {
    @ObservedObject var model: MeetingCoachWaveModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(model.bars.enumerated()), id: \.offset) { _, height in
                Capsule().fill(MW.textSecondary).frame(width: 2, height: reduceMotion ? 2 : height)
            }
        }
        .frame(width: model.bars.isEmpty ? 0 : 22, height: 14)
        .animation(reduceMotion ? nil : .linear(duration: 0.05), value: model.bars)
        .accessibilityHidden(true)
    }
}
