import Foundation

/// AppleScript sources for Dia (ITER-074 §5 `DiaBridge`). Pure: every value
/// that reaches a script — a URL, an id, a line of JavaScript — passes through
/// `quoted(_:)`, so nothing a page or a model produces can break out of its
/// string literal and become a command.
enum DiaScript {
    static let bundleID = "company.thebrowser.dia"
    /// Chrome shares Dia's scripting terms — windows, tabs, `execute …
    /// javascript` — so the same scripts drive it; only the addressed app
    /// changes (the probe on Chrome, 2026-09-25).
    static let chromeBundleID = "com.google.Chrome"
    static let defaultTimeoutSeconds = 5

    /// Escapes `text` into a double-quoted AppleScript string literal. The
    /// backslash is doubled first — otherwise it would corrupt every escape
    /// written after it — then the quote and the control characters, so no
    /// id, URL or page text can break out of the literal (ITER-074 §5).
    static func quoted(_ text: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
        return "\"\(escaped)\""
    }

    /// Spec §6.2 — `javascript:`, `data:`, `file:`, `mailto:` and every other
    /// scheme are never opened; only plain http(s) pages with a real host are,
    /// and never one on the user's own machine or network (ITER-076 I-09,
    /// owner decision D7): `isPrivate(host:)`.
    static func isOpenable(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return false }
        guard let host = url.host, !host.isEmpty else { return false }
        return !isPrivate(host: host)
    }

    /// A host the agent never opens (ITER-076 I-09): `localhost` and
    /// `*.localhost`, `*.local`, the names reserved for private networks that
    /// public DNS never answers — `home.arpa` and below it (RFC 8375, a home
    /// network), `*.internal` (ICANN, 2024), and `*.home`, `*.corp` and
    /// `*.mail`, which ICANN resolved never to give to anyone (2018), a home
    /// router's name among them (Claude review c7 of I-09, #9) — a name with
    /// no dot (an intranet name), and an address that is unspecified, loopback, private
    /// (RFC 1918), link-local, carrier-grade NAT (100.64/10) or unique-local
    /// IPv6 — an IPv4-mapped IPv6 address as the IPv4 address it maps. A host
    /// that ends in a number is read as a browser reads it (the URL Standard's
    /// IPv4 parser: hex, octal, decimal, fewer than four parts, a trailing
    /// dot), and one that is no valid address counts as private: a browser
    /// opens no such page. `host` as `URL.host` gives it — percent escapes
    /// undone, IPv6 without its brackets — or an address as the Mac's
    /// resolver writes it. A name alone does not say where it leads: a public
    /// name the user's own resolver answers with a private address (DNS
    /// rebinding; `*.lan`, `fritz.box`, a work name a VPN answers) is not
    /// seen here, and the agent's tab refuses each document whose host's
    /// addresses this reads as private (`ChromeBridge`, ITER-076 stage 9e).
    /// Known limits even so: an answer that changes between that lookup and
    /// Chrome's own (rebinding proper), and a page's own scripts calling a
    /// private address — no document: Chrome's own private-network rules.
    static func isPrivate(host: String) -> Bool {
        var name = host.lowercased()
        if name.hasPrefix("["), name.hasSuffix("]") { name = String(name.dropFirst().dropLast()) }
        if name.contains(":") { return ipv6IsPrivate(name) }
        if name.hasSuffix(".") { name.removeLast() }
        if name.isEmpty { return true }
        let parts = name.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        // The URL Standard's "ends in a number": an IPv4 address, or no host.
        if let last = parts.last, !last.isEmpty,
           last.allSatisfy({ $0.isASCII && $0.isNumber }) || ipv4Number(last) != nil {
            guard let address = ipv4(parts) else { return true }
            return ipv4IsPrivate(address)
        }
        if name == "localhost" || name.hasSuffix(".localhost") || name.hasSuffix(".local") { return true }
        if name == "home.arpa" || name.hasSuffix(".home.arpa") { return true }
        if name.hasSuffix(".internal") { return true }
        if let last = parts.last, Self.neverDelegated.contains(last) { return true }
        return !name.contains(".")
    }

    /// The top-level names ICANN resolved never to give to anyone (2018):
    /// only the user's own resolver answers them.
    private static let neverDelegated: Set<String> = ["home", "corp", "mail"]

    /// One part of an IPv4 address as the URL Standard's IPv4 number parser
    /// reads it: `0x` hex, a leading `0` octal, otherwise decimal.
    private static func ipv4Number(_ part: String) -> UInt64? {
        var digits = Substring(part)
        var radix = 10
        if digits.count >= 2, digits.hasPrefix("0x") {
            digits = digits.dropFirst(2)
            radix = 16
        } else if digits.count >= 2, digits.hasPrefix("0") {
            digits = digits.dropFirst()
            radix = 8
        }
        if digits.isEmpty { return 0 }
        guard digits.allSatisfy(\.isASCII), digits.count <= 20 else { return nil }
        return UInt64(digits, radix: radix)
    }

    /// The URL Standard's IPv4 parser: at most four parts, each but the last
    /// below 256, the last filling the bytes left.
    private static func ipv4(_ parts: [String]) -> UInt32? {
        guard (1...4).contains(parts.count) else { return nil }
        let numbers = parts.map(ipv4Number)
        guard numbers.allSatisfy({ $0 != nil }) else { return nil }
        let values = numbers.compactMap { $0 }
        guard values.dropLast().allSatisfy({ $0 <= 255 }),
              values[values.count - 1] < (UInt64(1) << (8 * UInt64(5 - values.count))) else { return nil }
        var address = values[values.count - 1]
        for (index, value) in values.dropLast().enumerated() { address += value << (8 * UInt64(3 - index)) }
        return UInt32(address)
    }

    private static func ipv4IsPrivate(_ address: UInt32) -> Bool {
        let first = address >> 24, second = (address >> 16) & 0xFF
        return first == 0                                   // unspecified, "this network"
            || first == 127                                 // loopback
            || first == 10                                  // RFC 1918
            || (first == 172 && (16...31).contains(second)) // RFC 1918
            || (first == 192 && second == 168)              // RFC 1918
            || (first == 169 && second == 254)              // link-local
            || (first == 100 && (64...127).contains(second)) // carrier-grade NAT
    }

    /// An IPv6 address, zone and all; one the system cannot read is no page.
    private static func ipv6IsPrivate(_ text: String) -> Bool {
        let literal = String(text.prefix { $0 != "%" })
        var bytes = in6_addr()
        guard inet_pton(AF_INET6, literal, &bytes) == 1 else { return true }
        let b = withUnsafeBytes(of: bytes) { Array($0) }
        if b.allSatisfy({ $0 == 0 }) { return true }                         // ::
        if b.prefix(15).allSatisfy({ $0 == 0 }) && b[15] == 1 { return true } // ::1
        if b[0] & 0xFE == 0xFC { return true }                                // fc00::/7
        if b[0] == 0xFE && b[1] & 0xC0 == 0x80 { return true }                // fe80::/10
        if b.prefix(10).allSatisfy({ $0 == 0 }) && b[10] == 0xFF && b[11] == 0xFF {
            return ipv4IsPrivate(b[12...].reduce(0) { $0 << 8 | UInt32($1) }) // ::ffff:a.b.c.d
        }
        return false
    }

    /// Wraps body lines into the app-addressed, timeout-guarded envelope every
    /// script uses. `with timeout` bounds each Apple Event the block sends,
    /// not the whole script, so a body with N commands may wait up to N × the
    /// timeout; callers that need a total budget cut `timeoutSeconds`
    /// themselves (ITER-074 §5, AppleScript Language Guide).
    private static func wrap(_ body: [String], timeoutSeconds: Int, bundleID: String) -> String {
        let lines = [
            "tell application id \(quoted(bundleID))",
            "    with timeout of \(timeoutSeconds) seconds",
        ] + body.map { "        \($0)" } + [
            "    end timeout",
            "end tell",
        ]
        return lines.joined(separator: "\n")
    }

    /// Returns the ids of the front window and its active tab, joined by a
    /// newline, to tell whether driving Dia stole the user's current tab
    /// (ITER-074 §13).
    static func frontActiveTab(timeoutSeconds: Int = defaultTimeoutSeconds,
                               bundleID: String = DiaScript.bundleID) -> String {
        wrap([
            "set w to front window",
            "return (id of w) & linefeed & (id of active tab of w)",
        ], timeoutSeconds: timeoutSeconds, bundleID: bundleID)
    }

    /// Opens a new tab at the end of the front window's tabs and returns its
    /// ids. If Dia creates the tab but its ids cannot be read, the script
    /// closes the tab itself before reporting the error, so no tab is left
    /// behind (I-0.1 review). Non-web URLs are refused here — not by the
    /// caller — so no other script builder can slip a dangerous scheme through
    /// (spec §6.2).
    static func openTab(url: URL,
                        timeoutSeconds: Int = defaultTimeoutSeconds,
                        bundleID: String = DiaScript.bundleID) -> String? {
        guard isOpenable(url) else { return nil }
        return wrap([
            "set w to front window",
            "set t to make new tab at end of tabs of w with properties {URL:\(quoted(url.absoluteString))}",
            "try",
            "    return (id of w) & linefeed & (id of t)",
            "on error errorMessage number errorNumber",
            "    close t",
            "    error errorMessage number errorNumber",
            "end try",
        ], timeoutSeconds: timeoutSeconds, bundleID: bundleID)
    }

    /// Returns whether the tab is still loading, as text, so a caller can poll
    /// it from AppleScript without parsing Apple Events (ITER-074 §13).
    static func isLoading(windowID: String, tabID: String,
                          timeoutSeconds: Int = defaultTimeoutSeconds,
                          bundleID: String = DiaScript.bundleID) -> String {
        wrap([
            "return (loading of tab id \(quoted(tabID)) of window id \(quoted(windowID))) as text",
        ], timeoutSeconds: timeoutSeconds, bundleID: bundleID)
    }

    /// Runs `javascript` inside the tab and returns its result as text. The
    /// app writes every script it runs; no model writes JavaScript (spec
    /// §6.1–§6.2). The script and the ids are quoted, so no value can leave
    /// its string literal.
    static func execute(windowID: String, tabID: String, javascript: String,
                        timeoutSeconds: Int = defaultTimeoutSeconds,
                        bundleID: String = DiaScript.bundleID) -> String {
        wrap([
            "return execute tab id \(quoted(tabID)) of window id \(quoted(windowID)) javascript \(quoted(javascript))",
        ], timeoutSeconds: timeoutSeconds, bundleID: bundleID)
    }

    /// Closes the tab so an errand leaves no debris in the user's browser
    /// (ITER-074 §13).
    static func closeTab(windowID: String, tabID: String,
                         timeoutSeconds: Int = defaultTimeoutSeconds,
                         bundleID: String = DiaScript.bundleID) -> String {
        wrap([
            "close tab id \(quoted(tabID)) of window id \(quoted(windowID))",
        ], timeoutSeconds: timeoutSeconds, bundleID: bundleID)
    }

    /// Splits a `<window id>\n<tab id>` result into its two trimmed parts and
    /// refuses anything else, because a malformed result must not be passed on
    /// as if it were a usable tab specifier (ITER-074 §13).
    static func parseIDs(_ result: String) -> (windowID: String, tabID: String)? {
        let parts = result.components(separatedBy: "\n")
        guard parts.count == 2 else { return nil }
        let windowID = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let tabID = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !windowID.isEmpty, !tabID.isEmpty else { return nil }
        return (windowID, tabID)
    }
}
