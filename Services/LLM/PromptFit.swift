import Foundation

/// Fitting a prompt into a provider's limit, counted the way the Pro proxy
/// counts it: UTF-16 code units (JavaScript `String.length`), not Characters.
/// An emoji is one Character and two units; a Character carrying many
/// combining marks can be thousands of units. A cut measured in Characters can
/// therefore still be refused (`Prompt too long`), and a refused extraction
/// finds nothing at all.
///
/// Pure and single-pass: every walk below is linear and ends; nothing loops
/// until it fits.
enum PromptFit {

    static let omissionMarker = "\n[…transcript middle omitted…]\n"

    /// `header + "\n" + transcript` when that fits in `unitLimit` units — the
    /// exact text the extractors always built. Otherwise the transcript keeps
    /// its beginning and its end (where later decisions and cancellations
    /// are) in the room the header leaves. A header that leaves no room for
    /// the marker is not a case the callers can produce (they bound their
    /// headers); it gets the whole prompt cut from the head, so the result is
    /// still within the limit.
    static func fit(header: String, transcript: String, unitLimit: Int) -> String {
        let whole = header + "\n" + transcript
        guard whole.utf16.count > unitLimit else { return whole }
        let room = unitLimit - header.utf16.count - 1
        guard room >= omissionMarker.utf16.count + 2 else { return prefix(whole, units: unitLimit) }
        return header + "\n" + headAndTail(transcript, unitLimit: room)
    }

    /// The beginning and the end of `text` around the omission marker, within
    /// `unitLimit` units. The head takes up to two thirds of the room; the
    /// tail gets everything the head did not use, so one oversized Character
    /// at the start never costs the ending. Characters are never split.
    static func headAndTail(_ text: String, unitLimit: Int) -> String {
        guard text.utf16.count > unitLimit else { return text }
        let room = unitLimit - omissionMarker.utf16.count
        guard room > 0 else { return prefix(text, units: unitLimit) }
        let head = prefix(text, units: room * 2 / 3)
        let tail = suffix(text, units: room - head.utf16.count)
        return head + omissionMarker + tail
    }

    /// The longest run of whole Characters from the start within `units`.
    static func prefix(_ text: String, units: Int) -> String {
        var used = 0
        var end = text.startIndex
        for index in text.indices {
            let cost = text[index].utf16.count
            if used + cost > units { break }
            used += cost
            end = text.index(after: index)
        }
        return String(text[..<end])
    }

    /// The longest run of whole Characters from the end within `units`.
    static func suffix(_ text: String, units: Int) -> String {
        var used = 0
        var start = text.endIndex
        while start > text.startIndex {
            let previous = text.index(before: start)
            let cost = text[previous].utf16.count
            if used + cost > units { break }
            used += cost
            start = previous
        }
        return String(text[start...])
    }
}
