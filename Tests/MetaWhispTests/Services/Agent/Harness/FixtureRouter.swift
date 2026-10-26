import Foundation

/// Maps the made-up addresses agent fixtures use to local HTML files, so a
/// test can "browse" without a network (ITER-074 §12.1).
///
/// - `https://search.test/…` → `search-results.html`
/// - `https://site-<n>.test/…` → `site-<n>.html`
/// - anything else → `not-found.html`
enum FixtureRouter {
    /// `Tests/MetaWhispTests/Fixtures/Agent/pages`, found from this file's path.
    static var pagesDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Harness
            .deletingLastPathComponent()   // Agent
            .deletingLastPathComponent()   // Services
            .deletingLastPathComponent()   // MetaWhispTests
            .appendingPathComponent("Fixtures/Agent/pages")
    }

    /// Resolves an address to the fixture file that plays that site. Hosts are
    /// lowercased first, because `Site-1.Test` and `site-1.test` are one host
    /// to a browser, so one lookup must not split them.
    static func fileName(for url: URL) -> String {
        guard let host = url.host?.lowercased() else { return "not-found.html" }
        if host == "search.test" { return "search-results.html" }
        if let match = host.firstMatch(of: #/^site-(\d+)\.test$/#) {
            return "site-\(match.1).html"
        }
        return "not-found.html"
    }

    /// Reads the routed fixture as UTF-8. A missing file falls back to
    /// `not-found.html`, so an unknown page still renders as a page the agent
    /// can observe instead of crashing the harness.
    static func html(for url: URL) throws -> String {
        let routed = pagesDirectory.appendingPathComponent(fileName(for: url))
        let fallback = pagesDirectory.appendingPathComponent("not-found.html")
        let path = FileManager.default.fileExists(atPath: routed.path) ? routed : fallback
        return try String(contentsOf: path, encoding: .utf8)
    }

    /// A response a server makes, for a browser that takes whole responses
    /// (ITER-076 I-09): its status, headers and body.
    struct Response {
        let status: Int
        let headers: [(name: String, value: String)]
        let body: Data
    }

    /// What a `.test` site answers. Two paths are a server's, on every host:
    /// - `/redirect?to=<address>` — a 302 to that address;
    /// - `/files/<name>?type=<media type>[&attachment=1][&disposition=<value>]`
    ///   — a file of that type, sent as an attachment when asked, or with
    ///   that `Content-Disposition` as it is written.
    /// Anything else is the routed page — with `csp=<policy>`, sent with that
    /// `Content-Security-Policy` of its own (ITER-076 I-10).
    static func response(for url: URL) throws -> Response {
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let value = { (name: String) in query.first { $0.name == name }?.value }
        if url.path == "/redirect", let to = value("to") {
            return Response(status: 302, headers: [("Location", to)], body: Data())
        }
        if url.path.hasPrefix("/files/") {
            var headers = [("Content-Type", value("type") ?? "application/octet-stream")]
            if value("attachment") == "1" {
                headers.append(("Content-Disposition", "attachment; filename=\"\(url.lastPathComponent)\""))
            }
            if let disposition = value("disposition") { headers.append(("Content-Disposition", disposition)) }
            return Response(status: 200, headers: headers, body: Data("file \(url.lastPathComponent)".utf8))
        }
        var headers = [("Content-Type", "text/html; charset=utf-8")]
        if let policy = value("csp") { headers.append(("Content-Security-Policy", policy)) }
        return Response(status: 200, headers: headers, body: Data(try html(for: url).utf8))
    }
}
