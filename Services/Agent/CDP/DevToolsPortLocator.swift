import Foundation

/// A browser's DevTools endpoint on this Mac (ITER-076 3.1).
struct DevToolsEndpoint: Equatable, Sendable {
    let browser: String
    let port: Int
    /// The browser-level socket's path, e.g. `/devtools/browser/<id>`.
    let path: String

    /// Always the loopback address and the file's own path: Chrome 147+ turns
    /// off `/json/*` discovery on the default profile, so the socket is found
    /// from the file alone (browser-harness `daemon.py`, MIT © Browser Use).
    var webSocketURL: URL {
        URL(string: "ws://127.0.0.1:\(port)\(path)")!
    }
}

/// Finds the DevTools port a Chromium browser writes to its profile folder when
/// "Allow remote debugging for this browser instance" is on at
/// `chrome://inspect/#remote-debugging` (ITER-076 3.1). Ported from
/// browser-harness (`daemon.py` lines 38-50 and 243-342, MIT © Browser Use):
/// the same profile folders, in the same order; the first that answers wins.
enum DevToolsPortLocator {
    /// Profile folders under `~/Library/Application Support`, in
    /// browser-harness's order.
    static let profiles: [(browser: String, folder: String)] = [
        ("Google Chrome", "Google/Chrome"),
        ("Google Chrome Canary", "Google/Chrome Canary"),
        ("Comet", "Comet"),
        ("Arc", "Arc/User Data"),
        ("Dia", "Dia/User Data"),
        ("Microsoft Edge", "Microsoft Edge"),
        ("Microsoft Edge Beta", "Microsoft Edge Beta"),
        ("Microsoft Edge Dev", "Microsoft Edge Dev"),
        ("Microsoft Edge Canary", "Microsoft Edge Canary"),
        ("Brave", "BraveSoftware/Brave-Browser"),
        ("Brave Origin", "BraveSoftware/Brave-Origin"),
    ]

    /// The port and path a `DevToolsActivePort` file holds: the port on the
    /// first line, the browser socket's path on the second. Anything else —
    /// a port out of range, a full URL, another path — is refused, so the
    /// socket is only ever a browser endpoint on the loopback address.
    static func parse(activePort contents: String) -> (port: Int, path: String)? {
        let lines = contents.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.count >= 2, let port = Int(lines[0]), (1...65_535).contains(port) else { return nil }
        let path = lines[1]
        let prefix = "/devtools/browser/"
        guard path.hasPrefix(prefix), path.count > prefix.count,
              path.unicodeScalars.allSatisfy({ CharacterSet.urlPathAllowed.contains($0) }) else { return nil }
        return (port, path)
    }

    /// Google Chrome's profile folder alone: the agent's browser either way
    /// (ITER-076 stage 8b, 8.8) — the others come back each with its live check.
    static let googleChrome = [profiles[0]]

    /// Every browser of `profiles` whose profile holds a readable port file,
    /// in order.
    static func endpoints(applicationSupport: URL,
                          profiles: [(browser: String, folder: String)] = DevToolsPortLocator.profiles)
        -> [DevToolsEndpoint] {
        profiles.compactMap { profile in
            let file = applicationSupport.appendingPathComponent(profile.folder, isDirectory: true)
                .appendingPathComponent("DevToolsActivePort")
            guard let text = try? String(contentsOf: file, encoding: .utf8),
                  let parsed = parse(activePort: text) else { return nil }
            return DevToolsEndpoint(browser: profile.browser, port: parsed.port, path: parsed.path)
        }
    }

    /// The user's own Application Support folder.
    static var userApplicationSupport: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    }
}
