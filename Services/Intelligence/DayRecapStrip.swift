import Foundation

/// Which day the Dashboard opens on when it shows the recap.
///
/// A menu-bar row that offered the recap lived here too. It was never asked
/// for, and it kept an unread recap on screen for days — the owner's word on
/// 2026-09-04: the recap belongs in the Dashboard, not in the menu bar.
///
/// Pure, because it is a product decision and deserves to be arguable without
/// a running app.
enum DayRecapStrip {

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
