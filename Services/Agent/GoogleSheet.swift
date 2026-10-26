import Foundation

/// A new Google Sheet in the user's own Chrome (ITER-076 stage 6, № 163, 26, 170-172): made in a background tab of
/// the errand's own — `sheets.new`, in the Google account that Chrome is signed in to — named after the user's own
/// words, pasted into and read back there, and closed with that tab. How was found by the live probe of 2026-10-06
/// in a signed-in test profile: the paste is a paste event a script gives the Sheet's cell editor — no key, no
/// clipboard, nothing outside this tab; the read-back is the Sheet's own TSV export, fetched inside the page —
/// opened in the tab, it would be a download the tab refuses. It never clicks a share dialog or "Allow access":
/// every cell it pastes is text (`SheetCells.escaped`), never a formula.
@MainActor
final class GoogleSheet: SheetDestination {
    enum Failure: Error, Equatable {
        /// No Sheet's editor came in time, nor a page that is the user's part.
        case notMade
        /// The Sheet's editor did not take the paste.
        case notPasted
        /// The Sheet's export could not be read.
        case unread
        /// Not the Sheet this destination made.
        case unknownSheet
    }

    /// Google's own address for a new Sheet: it lands on the Sheet's editor (the probe: in 2.3 s).
    nonisolated static let start = URL(string: "https://sheets.new")!
    /// How long a new Sheet may take to show its editor (the probe: 4.6 s).
    nonisolated static let editorLimit: Duration = .seconds(20)
    private static let poll: Duration = .milliseconds(250)

    private let bridge: any BrowserBridge
    private let editorLimit: Duration
    private var tab: BrowserTab?
    private var address: URL?

    init(bridge: any BrowserBridge, editorLimit: Duration = GoogleSheet.editorLimit) {
        self.bridge = bridge
        self.editorLimit = editorLimit
    }

    /// Opens `sheets.new` in a new tab and waits for the new Sheet's editor: its address is the receipt, given as
    /// soon as it is known, and the Sheet is named `title` after. Google's sign-in or consent page there is the
    /// user's part, said with its tab (`SheetWall`). Asked again — after the user's part — it begins anew in a new
    /// tab, the one before closed.
    func create(title: String, made: @escaping @MainActor (URL) -> Void) async throws -> URL {
        await close()
        let tab = try await bridge.openTab(Self.start)
        self.tab = tab
        let deadline = ContinuousClock.now + editorLimit
        while ContinuousClock.now < deadline {
            try await Task.sleep(for: Self.poll)
            let reply: String
            do {
                reply = try await bridge.run(Self.landing, in: tab)
            } catch let error where error is CancellationError || AgentRun.isLost(error) {
                throw error
            } catch {
                continue
            }
            guard let landing = try? JSONDecoder().decode(Landing.self, from: Data(reply.utf8)),
                  landing.ready == "complete" else { continue }
            if let kind = Self.usersPart(at: landing.host) {
                throw SheetWall(handover: ErrandHandover(kind: kind, host: landing.host), tab: tab)
            }
            guard landing.editor, let base = Self.base(host: landing.host, path: landing.path),
                  let address = URL(string: "https://docs.google.com" + base + "/edit") else { continue }
            self.address = address
            made(address)
            try Task.checkCancellation()
            _ = try? await bridge.run(Self.named(title), in: tab)
            return address
        }
        throw Failure.notMade
    }

    /// Gives the Sheet's cell editor `text` as a paste — at the active cell, A1 on a new Sheet: a tab between
    /// cells, a line break between rows.
    func paste(_ text: String, into sheet: URL) async throws {
        guard let tab, sheet == address else { throw Failure.unknownSheet }
        try Task.checkCancellation()
        guard try await bridge.run(Self.pasted(text), in: tab) == "pasted" else { throw Failure.notPasted }
    }

    /// The Sheet's first tab as its TSV export shows it: a line a row, a tab between cells, nothing quoted (the
    /// probe). The export shows what a formula computes, never the formula: one is caught by the cells' equality.
    func readBack(_ sheet: URL) async throws -> SheetReadBack {
        guard let tab, sheet == address else { throw Failure.unknownSheet }
        let reply = try await bridge.runAwaiting(Self.export(sheet.deletingLastPathComponent().path), in: tab)
        guard let export = try? JSONDecoder().decode(Export.self, from: Data(reply.utf8)), export.status == 200 else {
            throw Failure.unread
        }
        let lines = export.body.isEmpty ? [] : export.body.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
        return SheetReadBack(cells: lines.map { $0.components(separatedBy: "\t") }, holdsFormula: false)
    }

    func close() async {
        guard let tab else { return }
        self.tab = nil
        try? await bridge.closeTab(tab)
    }

    // MARK: - In the page

    private struct Landing: Decodable {
        let host: String
        let path: String
        let ready: String
        let editor: Bool
    }

    private struct Export: Decodable {
        let status: Int
        let body: String
    }

    /// Where the tab is, and whether a Sheet's editor stands there whole: its name field and its cell editor.
    static let landing = """
    JSON.stringify({ host: location.host, path: location.pathname, ready: document.readyState,
      editor: !!document.querySelector('#waffle-rich-text-editor') && !!document.querySelector('.docs-title-input') })
    """

    /// The Sheet named as a person's typing ends: its name field's value, then `input`, `change` and the field
    /// left — no key (the probe).
    static func named(_ title: String) -> String {
        """
        (() => {
          const field = document.querySelector('.docs-title-input');
          if (!field) return 'no field';
          field.focus();
          field.value = \(literal(title));
          field.dispatchEvent(new Event('input', { bubbles: true }));
          field.dispatchEvent(new Event('change', { bubbles: true }));
          field.blur();
          return 'named';
        })()
        """
    }

    /// `text` given to the Sheet's cell editor as a paste of plain text: what the probe saw Sheets take, from the
    /// agent's own world, with the editor focused by the script — a paste sent to the page's body it ignored.
    static func pasted(_ text: String) -> String {
        """
        (() => {
          const editor = document.querySelector('#waffle-rich-text-editor');
          if (!editor) return 'no editor';
          editor.focus();
          const data = new DataTransfer();
          data.setData('text/plain', \(literal(text)));
          const event = new ClipboardEvent('paste', { clipboardData: data, bubbles: true, cancelable: true });
          editor.dispatchEvent(event);
          return event.defaultPrevented ? 'pasted' : 'not taken';
        })()
        """
    }

    /// The Sheet's TSV export, fetched inside the page: its status and its text.
    static func export(_ base: String) -> String {
        """
        fetch(\(literal(base + "/export?format=tsv&gid=0")), { credentials: 'same-origin', cache: 'no-store' })
          .then(async (answer) => JSON.stringify({ status: answer.status, body: await answer.text() }))
          .catch(() => JSON.stringify({ status: 0, body: '' }))
        """
    }

    /// The Sheet's own path, `/spreadsheets/d/<id>`, from where the tab landed: only on docs.google.com, with an id
    /// of the letters, digits, `-` and `_` Google's ids are made of.
    static func base(host: String, path: String) -> String? {
        let parts = path.split(separator: "/")
        guard host == "docs.google.com", parts.count >= 3, parts[0] == "spreadsheets", parts[1] == "d",
              parts[2].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
        else { return nil }
        return "/spreadsheets/d/" + parts[2]
    }

    /// The page on the way that is the user's part: Google's sign-in, or its consent page.
    private static func usersPart(at host: String) -> ErrandHandover.Kind? {
        switch host {
        case "accounts.google.com": .signIn
        case "consent.google.com": .cookies
        default: nil
        }
    }

    /// `text` as a JavaScript string literal.
    private static func literal(_ text: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        return String(decoding: (try? encoder.encode(text)) ?? Data("\"\"".utf8), as: UTF8.self)
    }
}
