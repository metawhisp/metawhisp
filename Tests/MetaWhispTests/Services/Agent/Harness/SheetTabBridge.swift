import Foundation
@testable import MetaWhisp

/// The fixture browser with Google Sheets in it (ITER-076 stage 6): every page but `sheets.new` is the fixture
/// browser's; `sheets.new` opens a tab this bridge plays as the live probe of 2026-10-06 saw Google Sheets — it
/// lands on a new Sheet's editor, or on Google's sign-in, or nowhere in time; its cell editor takes a paste event;
/// its TSV export shows what was pasted as the Sheet shows it (a leading apostrophe hidden, CRLF between rows).
/// Every script run in one of its tabs is kept, with the tab and the moment.
@MainActor
final class SheetTabBridge: BrowserBridge {
    enum Landing { case editor, signIn, nowhere }

    struct Ran {
        let tab: BrowserTab
        let kind: String
        let at: ContinuousClock.Instant
    }

    let inner = WebViewBridge()
    /// Where each new Sheet tab lands, in the order they are opened; the last one repeats.
    var landings: [Landing] = [.editor]
    /// The paste waits until its caller stops, as a call Stop cuts short.
    var pasteHolds = false
    /// Called as a paste comes in, before it is taken.
    var onPaste: (@MainActor () -> Void)?
    /// What the export shows in place of what was pasted, when set.
    var exportShows: String?
    private(set) var ran: [Ran] = []
    private(set) var closed: [(tab: BrowserTab, at: ContinuousClock.Instant)] = []
    /// Every Sheet tab opened, in order.
    private(set) var sheetTabs: [BrowserTab] = []
    /// The Sheet's name, as the last name script set it.
    private(set) var names: [String] = []
    private var pasted: [BrowserTab: String] = [:]
    private var open: Set<BrowserTab> = []

    func openTab(_ url: URL) async throws -> BrowserTab {
        guard url == GoogleSheet.start else { return try await inner.openTab(url) }
        let tab = BrowserTab(windowID: "sheet-window", tabID: "sheet-\(sheetTabs.count + 1)")
        sheetTabs.append(tab)
        open.insert(tab)
        return tab
    }

    func isLoading(_ tab: BrowserTab) async throws -> Bool {
        open.contains(tab) ? false : try await inner.isLoading(tab)
    }

    func closeTab(_ tab: BrowserTab) async throws {
        guard sheetTabs.contains(tab) else { return try await inner.closeTab(tab) }
        guard open.remove(tab) != nil else { throw BrowserBridgeError.tabNotFound }
        closed.append((tab, .now))
    }

    func run(_ javascript: String, in tab: BrowserTab) async throws -> String {
        guard sheetTabs.contains(tab) else { return try await inner.run(javascript, in: tab) }
        guard open.contains(tab) else { throw BrowserBridgeError.tabNotFound }
        if javascript == GoogleSheet.landing {
            ran.append(Ran(tab: tab, kind: "landing", at: .now))
            let number = sheetTabs.firstIndex(of: tab) ?? 0
            switch landings[min(number, landings.count - 1)] {
            case .editor:
                return #"{"host":"docs.google.com","path":"/spreadsheets/d/SHEET-\#(number + 1)/edit","ready":"complete","editor":true}"#
            case .signIn:
                return #"{"host":"accounts.google.com","path":"/v3/signin/identifier","ready":"complete","editor":false}"#
            case .nowhere:
                return #"{"host":"docs.google.com","path":"/spreadsheets/u/0/create","ready":"loading","editor":false}"#
            }
        }
        if let title = Self.literal(after: "field.value = ", in: javascript) {
            ran.append(Ran(tab: tab, kind: "name", at: .now))
            names.append(title)
            return "named"
        }
        if let text = Self.literal(after: "data.setData('text/plain', ", in: javascript) {
            ran.append(Ran(tab: tab, kind: "paste", at: .now))
            onPaste?()
            if pasteHolds { try await Task.sleep(for: .seconds(60)) }
            pasted[tab] = text
            return "pasted"
        }
        ran.append(Ran(tab: tab, kind: "other", at: .now))
        return ""
    }

    func runAwaiting(_ javascript: String, in tab: BrowserTab) async throws -> String {
        guard sheetTabs.contains(tab) else { return try await inner.runAwaiting(javascript, in: tab) }
        guard open.contains(tab) else { throw BrowserBridgeError.tabNotFound }
        guard javascript.contains("/export?format=tsv") else { return try await run(javascript, in: tab) }
        ran.append(Ran(tab: tab, kind: "export", at: .now))
        let shown = exportShows ?? (pasted[tab] ?? "").components(separatedBy: "\n").map { line in
            line.components(separatedBy: "\t").map { $0.hasPrefix("'") ? String($0.dropFirst()) : $0 }
                .joined(separator: "\t")
        }.joined(separator: "\r\n")
        let body = String(decoding: try JSONSerialization.data(withJSONObject: ["status": 200, "body": shown]),
                          as: UTF8.self)
        return body
    }

    /// What was pasted in `tab`, as it was sent.
    func pastedText(in tab: BrowserTab) -> String? { pasted[tab] }

    /// The JavaScript string literal a script holds right after `marker`, decoded.
    private static func literal(after marker: String, in script: String) -> String? {
        guard let start = script.range(of: marker)?.upperBound else { return nil }
        var index = start
        guard index < script.endIndex, script[index] == "\"" else { return nil }
        index = script.index(after: index)
        var escaped = false
        while index < script.endIndex {
            let character = script[index]
            if escaped {
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" {
                let literal = String(script[start...index])
                return try? JSONDecoder().decode(String.self, from: Data(literal.utf8))
            }
            index = script.index(after: index)
        }
        return nil
    }
}
