import AppKit

/// The panel operations the field needs, replaceable without a window server.
@MainActor
protocol MeetingCoachPanelOrdering: AnyObject {
    func endEditing(for object: Any?)
    func orderOut(_ sender: Any?)
    func orderFrontRegardless()
}

extension NSPanel: MeetingCoachPanelOrdering {}

/// Relinquishes the keyboard while keeping the card visible on the same Space.
@MainActor
enum MeetingCoachQuestionFocus {
    static func giveUp(panel: any MeetingCoachPanelOrdering,
                       restoreShadow: () -> Void = {}) {
        panel.endEditing(for: nil)
        panel.orderOut(nil)
        panel.orderFrontRegardless()
        restoreShadow()
    }
}

/// Key status is available only when a control explicitly needs it.
final class MeetingCoachPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    static func make() -> MeetingCoachPanel {
        let panel = MeetingCoachPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 120),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true)
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = MWWindowBehavior.overlay
        return panel
    }
}
