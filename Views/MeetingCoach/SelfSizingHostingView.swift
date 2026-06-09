import AppKit
import SwiftUI

/// `NSHostingView` that reports its SwiftUI content's intrinsic size back to the
/// owner so a borderless panel can be sized exactly to the content.
///
/// Replaces an earlier SwiftUI `GeometryReader` + `PreferenceKey` measurement
/// that emitted `0×0` (NSHostingView stretches its root to the window bounds and
/// the preference fired once with a degenerate size, so the card panel never
/// shrank and its empty region stayed clickable). Measuring on the AppKit side
/// via `intrinsicContentSize` (with `sizingOptions = .intrinsicContentSize`) is
/// reliable and updates as the SwiftUI content grows.
@MainActor
final class SelfSizingHostingView<Content: View>: NSHostingView<Content> {
    /// Called with the content's measured size whenever it changes. Coalesced
    /// to the next main-actor turn so the resize it triggers can't re-enter
    /// `layout()` synchronously.
    var onContentSizeChange: ((CGSize) -> Void)?

    private var lastReportedSize: CGSize = .zero
    private var reportScheduled = false
    private let tolerance: CGFloat = 0.5

    required init(rootView: Content) {
        super.init(rootView: rootView)
        sizingOptions = [.intrinsicContentSize]
    }

    @MainActor required dynamic init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        scheduleSizeReport()
    }

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        scheduleSizeReport()
    }

    /// Measure now and report if it changed. Safe to call directly (e.g. to
    /// force the first measurement after install).
    func reportCurrentSize() {
        let size = measuredContentSize()
        guard isUsable(size), differs(size, from: lastReportedSize) else { return }
        lastReportedSize = size
        onContentSizeChange?(size)
    }

    private func scheduleSizeReport() {
        guard !reportScheduled else { return }
        reportScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.reportScheduled = false
            self.reportCurrentSize()
        }
    }

    private func measuredContentSize() -> CGSize {
        let intrinsic = intrinsicContentSize
        let raw = isUsable(intrinsic) ? intrinsic : fittingSize
        return CGSize(width: ceil(raw.width), height: ceil(raw.height))
    }

    private func isUsable(_ size: CGSize) -> Bool {
        size.width.isFinite && size.height.isFinite &&
        size.width > 0 && size.height > 0 &&
        size.width != NSView.noIntrinsicMetric &&
        size.height != NSView.noIntrinsicMetric
    }

    private func differs(_ lhs: CGSize, from rhs: CGSize) -> Bool {
        abs(lhs.width - rhs.width) > tolerance ||
        abs(lhs.height - rhs.height) > tolerance
    }
}
