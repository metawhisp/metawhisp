import AppKit
import SwiftUI

/// The tabs stay above the scrolling exchange, including on a capped panel.
struct MeetingCoachHeaderView: View {
    static let height: CGFloat = 44
    @ObservedObject var state: MeetingCoachState
    var snapshot: MeetingCoachRenderSnapshot? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var reduceMotionOverride: Bool? = nil

    private var halted: Bool { snapshot?.isHalted ?? state.isHalted }
    private var tab: MeetingCoachState.Tab { snapshot?.selectedTab ?? state.selectedTab }
    private var busy: Bool { snapshot.map { $0.busyRequest != nil } ?? (state.busyRequest != nil) }

    var body: some View {
        HStack {
            MeetingCoachTabs(selectedTab: halted ? .answers : tab,
                             isEnabled: !halted, onSelect: state.selectTab)
                .fixedSize()
            Spacer(minLength: 0)
            if busy {
                MeetingCoachBusyIndicator(reduceMotion: reduceMotionOverride ?? reduceMotion)
                    .frame(width: 80, height: 3)
                    .accessibilityLabel("Generating answer")
            }
        }
        .padding(.horizontal, 16)
        .frame(height: Self.height)
        .focusable(false)
    }
}

private struct MeetingCoachBusyIndicator: NSViewRepresentable {
    let reduceMotion: Bool

    func makeNSView(context: Context) -> MeetingCoachProgressView { MeetingCoachProgressView() }
    func updateNSView(_ view: MeetingCoachProgressView, context: Context) {
        view.setReducedMotion(reduceMotion)
    }
}

/// A fixed-size layer animation never invalidates the answer's measured height.
final class MeetingCoachProgressView: NSView {
    private let shimmer = CAGradientLayer()
    private var reducedMotion: Bool?

    init() {
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier("meeting-busy-indicator")
        wantsLayer = true
        layer?.cornerRadius = 1.5
        layer?.masksToBounds = true
        shimmer.colors = [NSColor.secondaryLabelColor.withAlphaComponent(0.12).cgColor,
                          NSColor.secondaryLabelColor.cgColor,
                          NSColor.secondaryLabelColor.withAlphaComponent(0.12).cgColor]
        shimmer.startPoint = CGPoint(x: 0, y: 0.5)
        shimmer.endPoint = CGPoint(x: 1, y: 0.5)
        shimmer.locations = [0, 0.5, 1]
        layer?.addSublayer(shimmer)
        setAccessibilityLabel("Generating answer")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shimmer.frame = bounds
        CATransaction.commit()
    }

    func setReducedMotion(_ reduced: Bool) {
        guard reducedMotion != reduced else { return }
        reducedMotion = reduced
        shimmer.removeAnimation(forKey: "busy-shimmer")
        guard !reduced else { return }
        let animation = CABasicAnimation(keyPath: "locations")
        animation.fromValue = [-1, -0.5, 0]
        animation.toValue = [1, 1.5, 2]
        animation.duration = 1.2
        animation.repeatCount = .infinity
        shimmer.add(animation, forKey: "busy-shimmer")
    }
}

private struct MeetingCoachTabs: NSViewRepresentable {
    let selectedTab: MeetingCoachState.Tab
    let isEnabled: Bool
    let onSelect: (MeetingCoachState.Tab) -> Void

    func makeNSView(context: Context) -> MeetingCoachNativeTabs {
        let control = MeetingCoachNativeTabs(frame: .zero)
        control.segmentCount = 2
        control.setLabel("Answers", forSegment: 0)
        control.setLabel("Transcript", forSegment: 1)
        control.trackingMode = .selectOne
        control.segmentStyle = .rounded
        control.controlSize = .small
        control.font = .systemFont(ofSize: 11.5, weight: .medium)
        control.focusRingType = .none
        control.setAccessibilityLabel("Meeting panel tabs")
        control.target = control
        control.action = #selector(MeetingCoachNativeTabs.selectionChanged)
        return control
    }

    func updateNSView(_ control: MeetingCoachNativeTabs, context: Context) {
        control.renderedSelection = selectedTab == .answers ? 0 : 1
        control.selectedSegment = control.renderedSelection
        control.isEnabled = isEnabled
        control.onSelect = onSelect
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MeetingCoachNativeTabs,
                     context: Context) -> CGSize? {
        nsView.intrinsicContentSize
    }
}

/// Native select-one semantics without making the floating panel key.
private final class MeetingCoachNativeTabs: NSSegmentedControl {
    var onSelect: ((MeetingCoachState.Tab) -> Void)?
    var renderedSelection = 0
    override var acceptsFirstResponder: Bool { false }
    override var needsPanelToBecomeKey: Bool { false }

    @objc func selectionChanged() {
        guard isEnabled else { return }
        let requested: MeetingCoachState.Tab = selectedSegment == 1 ? .transcript : .answers
        selectedSegment = renderedSelection
        onSelect?(requested)
    }
}
