import Foundation

/// AUD-032 — pure helpers that keep Rating/scale goal bounds safe.
///
/// A Rating goal drives `Slider(value:, in: lo...hi)`. `lo...hi` builds a
/// `ClosedRange` whose initializer **traps the whole process** when `lo > hi`,
/// and `Slider` misbehaves on empty or non-finite ranges. So the range must
/// never be built straight from raw `Goal.minValue`/`maxValue`: an inverted or
/// NaN bound (which the editor used to accept) crashed the Goals screen on
/// render.
///
/// `safeScaleRange` is the render-side guard (protects already-saved bad data);
/// `normalizedBounds` is the owner-side fix applied before persisting, so stored
/// bounds are always finite and strictly ascending.
enum GoalBounds {

    private static let defaultLow: Double = 1
    private static let defaultHigh: Double = 10

    /// A valid, non-empty, ascending closed range for a scale `Slider`. Never
    /// traps: non-finite bounds fall back to defaults, the pair is ordered, and
    /// an equal pair is widened by one so `lo < hi` always holds.
    static func safeScaleRange(min: Double?, max: Double?) -> ClosedRange<Double> {
        let lo = finiteOr(min, defaultLow)
        let hi = finiteOr(max, defaultHigh)
        let low = Swift.min(lo, hi)
        let high = Swift.max(lo, hi)
        return low < high ? low...high : low...(low + 1)
    }

    /// Normalize editor-entered bounds before persisting: replace non-finite
    /// values, order them ascending, and guarantee `min < max`. Returns the pair
    /// untouched when either side is nil (non-scale goals carry no bounds).
    static func normalizedBounds(min: Double?, max: Double?) -> (min: Double?, max: Double?) {
        guard let rawLo = min, let rawHi = max else { return (min, max) }
        let lo = finiteOr(rawLo, defaultLow)
        let hi = finiteOr(rawHi, defaultHigh)
        let low = Swift.min(lo, hi)
        var high = Swift.max(lo, hi)
        if low == high { high = low + 1 }
        return (low, high)
    }

    private static func finiteOr(_ value: Double?, _ fallback: Double) -> Double {
        guard let v = value, v.isFinite else { return fallback }
        return v
    }
}
