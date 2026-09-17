import AppKit
import Foundation

/// Which applications are browsers.
///
/// Call detection used to carry a hardcoded list of seven bundle ids. Dia
/// (`company.thebrowser.dia`) was not on it — Arc, from the same makers, was —
/// so a Google Meet call held in Dia produced no call signal at all and only a
/// calendar event could start a recording (owner's report, 2026-09-17).
///
/// Adding one line would have fixed that call and left the next browser
/// missing. macOS already knows which applications open web pages, so that is
/// what answers the question; the known names stay as a floor for the case
/// where LaunchServices answers nothing.
enum BrowserIdentity {

    /// Browsers that count regardless of what the system reports.
    static let known: Set<String> = [
        "com.google.Chrome",
        "com.apple.Safari",
        "company.thebrowser.Browser",     // Arc
        "company.thebrowser.dia",         // Dia
        "org.mozilla.firefox",
        "com.microsoft.edgemac",
        "com.brave.Browser",
        "com.operasoftware.Opera",
    ]

    static func isBrowser(bundleID: String, systemHandlers: Set<String>) -> Bool {
        known.contains(bundleID) || systemHandlers.contains(bundleID)
    }

    /// The live answer, memoised per bundle id: the tick loop asks about the
    /// frontmost application every second, and LaunchServices is consulted
    /// only the first time an application is seen.
    @MainActor
    static func isBrowser(_ bundleID: String) -> Bool {
        guard !bundleID.isEmpty else { return false }
        if let cached = verdicts[bundleID] { return cached }
        let verdict = isBrowser(bundleID: bundleID, systemHandlers: webHandlers())
        verdicts[bundleID] = verdict
        return verdict
    }

    @MainActor private static var verdicts: [String: Bool] = [:]
    @MainActor private static var handlers: Set<String>?

    /// Every application macOS would offer to open a web page with.
    @MainActor
    private static func webHandlers() -> Set<String> {
        if let handlers { return handlers }
        guard let url = URL(string: "https://example.com") else { return [] }
        let found = Set(NSWorkspace.shared.urlsForApplications(toOpen: url)
            .compactMap { Bundle(url: $0)?.bundleIdentifier })
        handlers = found
        NSLog("[BrowserIdentity] %d applications open web pages", found.count)
        return found
    }
}
