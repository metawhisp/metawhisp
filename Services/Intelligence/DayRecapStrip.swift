import Foundation

/// The rules for how the day recap is offered: whether the menu bar shows it,
/// what the row says, and which day the Dashboard opens on.
///
/// The recap is the strongest thing this app produces and it lived in a
/// Dashboard tab plus a banner that fires once a day. A menu-bar app is looked
/// at in the menu bar; the recap was not there at all, so reaching it required
/// already knowing it existed.
///
/// Pure, because every one of these is a product decision and deserves to be
/// arguable without a running app.
enum DayRecapStrip {

    /// Today and yesterday. The recap for a day is written at the end of it, so
    /// the morning after is when a person most wants the one before — cutting at
    /// midnight would hide it exactly when it is most useful.
    static let maxAgeInDays = 1

    /// A recap nobody has opened stays offered past that, because one missed
    /// generation used to leave the menu bar empty the next morning while an
    /// unread recap sat in the store. Bounded: a row that never goes away
    /// stops being read. Two releases — it was opened, or a week passed.
    static let unreadMaxAgeInDays = 7

    static func shouldShow(recapDate: Date?,
                           isRead: Bool,
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
        if days <= maxAgeInDays { return true }
        return !isRead && days <= unreadMaxAgeInDays
    }

    /// What the recap is worth opening for. A bare title could be an empty day;
    /// the counts are the promise it keeps.
    static func subtitle(decided: Int, learned: Int) -> String {
        var parts: [String] = []
        if decided > 0 { parts.append("\(decided) decided") }
        if learned > 0 { parts.append("\(learned) learned") }
        return parts.joined(separator: " · ")
    }

    /// The day the Dashboard card stands on before the user touches ‹ ›.
    ///
    /// Today's recap does not exist until the scheduled hour, so for most of
    /// the day "today" was an empty placeholder — and the menu-bar row and the
    /// card that announce a recap both opened onto it. The card now stands on
    /// the newest recap there is, which is the one those two advertised.
    static func anchorDay(newestRecapDate: Date?,
                          now: Date,
                          calendar: Calendar = .current) -> Date {
        let today = calendar.startOfDay(for: now)
        guard let newestRecapDate else { return today }
        let newest = calendar.startOfDay(for: newestRecapDate)
        return newest < today ? newest : today
    }
}
