import Foundation

/// A cheap summary of what a window looks like, used to answer "did anything
/// actually change?" without running OCR to find out.
///
/// Capture fires on the window title moving, so a new message in an open Slack
/// channel — same app, same title — is never captured at all. Fixing that by
/// re-reading on every tick creates the opposite problem: a blinking caret, a
/// clock in a toolbar or a spinner would re-run Vision and a model call
/// forever.
///
/// The picture is reduced to a grid of block averages. Small moving details
/// disappear into their block; a new line of text, a scroll or a different
/// screen moves enough blocks to show. The spec is explicit about which way to
/// err — prefer missing a change to re-running continuously — so the
/// thresholds are deliberately dull.
struct ScreenContentFingerprint: Equatable, Hashable {

    /// Grid resolution. Coarse enough that a caret vanishes, fine enough that
    /// one new line of text does not.
    static let grid = 8

    /// How far a block's average must move to count as changed at all.
    static let blockDelta = 6

    /// How much of the picture must have moved before it is a different screen.
    static let changedBlockFraction = 0.08

    private let blocks: [Int]
    private let isValid: Bool

    init(pixels: [UInt8], width: Int, height: Int) {
        guard width > 0, height > 0, pixels.count >= width * height else {
            self.blocks = []
            self.isValid = false
            return
        }
        var out = [Int](repeating: 0, count: Self.grid * Self.grid)
        for gy in 0..<Self.grid {
            let y0 = gy * height / Self.grid
            let y1 = max(y0 + 1, (gy + 1) * height / Self.grid)
            for gx in 0..<Self.grid {
                let x0 = gx * width / Self.grid
                let x1 = max(x0 + 1, (gx + 1) * width / Self.grid)
                var sum = 0
                var count = 0
                for y in y0..<min(y1, height) {
                    let row = y * width
                    for x in x0..<min(x1, width) {
                        sum += Int(pixels[row + x])
                        count += 1
                    }
                }
                out[gy * Self.grid + gx] = count > 0 ? sum / count : 0
            }
        }
        self.blocks = out
        self.isValid = true
    }

    /// True when the two pictures are different enough to be worth reading
    /// again. A fingerprint that could not be built compares as changed against
    /// anything but itself — guessing "unchanged" would strand a window that
    /// really did move on.
    func differs(from other: ScreenContentFingerprint) -> Bool {
        guard isValid, other.isValid else { return self != other }
        guard blocks.count == other.blocks.count else { return true }
        var moved = 0
        for i in blocks.indices where abs(blocks[i] - other.blocks[i]) >= Self.blockDelta {
            moved += 1
        }
        return Double(moved) / Double(blocks.count) > Self.changedBlockFraction
    }
}
