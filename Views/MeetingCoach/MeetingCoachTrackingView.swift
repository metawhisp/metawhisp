import AppKit

/// Each surface observes only its own bounds; the gap belongs to no window.
final class MeetingCoachTrackingView: NSView {
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?
    override var acceptsFirstResponder: Bool { false }
    override var needsPanelToBecomeKey: Bool { false }
    private struct Geometry: Equatable {
        let bounds: NSRect
        let windowFrame: NSRect?
        let windowID: ObjectIdentifier?
    }
    private var trackingGeometry: Geometry?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        let geometry = Geometry(bounds: bounds, windowFrame: window?.frame,
                                windowID: window.map(ObjectIdentifier.init))
        guard trackingAreas.isEmpty || trackingGeometry != geometry else { return }
        trackingGeometry = geometry
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { onEnter?() }
    override func mouseExited(with event: NSEvent) { onExit?() }
}

final class MeetingCoachScrollView: NSScrollView {
    override var acceptsFirstResponder: Bool { false }
    override var needsPanelToBecomeKey: Bool { false }

    override func setFrameSize(_ newSize: NSSize) {
        guard newSize != frame.size else { return }
        guard let document = documentView else {
            super.setFrameSize(newSize)
            return
        }
        let distance = document.isFlipped ? documentVisibleRect.minY - document.bounds.minY
            : document.bounds.maxY - documentVisibleRect.maxY
        super.setFrameSize(newSize)
        let y = document.isFlipped ? document.bounds.minY + distance
            : document.bounds.maxY - contentView.bounds.height - distance
        let target = contentView.constrainBoundsRect(NSRect(origin: NSPoint(x: 0, y: y), size: contentView.bounds.size)).origin
        if target != contentView.bounds.origin {
            contentView.scroll(to: target)
            reflectScrolledClipView(contentView)
        }
    }
}
