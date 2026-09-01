import Foundation

/// Whether the menu bar offers the day recap, and what the row says.
///
/// The recap is the strongest thing this app produces and it lived in a
/// Dashboard tab plus a banner that fires once a day. A menu-bar app is looked
/// at in the menu bar; the recap was not there at all, so reaching it required
/// already knowing it existed.
///
/// Pure, because "is this worth a row" is a product decision and deserves to be
/// arguable without a running app.
enum DayRecapStrip {

    /// Today and yesterday. The recap for a day is written at the end of it, so
    /// the morning after is when a person most wants the one before — cutting at
    /// midnight would hide it exactly when it is most useful.
    static let maxAgeInDays = 1

    static func shouldShow(recapDate: Date?,
                           now: Date,
                           calendar: Calendar = .current) -> Bool {
        guard let recapDate else { return false }
        // A stamp in the future is a clock that moved, not a recap from
        // tomorrow. Hiding the newest thing there is would be the worse answer.
        guard recapDate <= now else { return true }
        guard let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: recapDate),
            to: calendar.startOfDay(for: now)).day
        else { return false }
        return days <= maxAgeInDays
    }

    /// What the recap is worth opening for. A bare title could be an empty day;
    /// the counts are the promise it keeps.
    static func subtitle(decided: Int, learned: Int) -> String {
        var parts: [String] = []
        if decided > 0 { parts.append("\(decided) decided") }
        if learned > 0 { parts.append("\(learned) learned") }
        return parts.joined(separator: " · ")
    }
}
