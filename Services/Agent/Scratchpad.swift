import Foundation

/// The rows an errand has collected (ITER-074 §4, §6.6, US-9). Cells are
/// canonical from the start, every row keeps the address it came from, and a
/// second row from a site already collected is not added (§4 step 9).
struct Scratchpad: Equatable {
    struct Row: Codable, Equatable {
        let cells: [String]
        let source: URL
    }

    /// Why a row was not added.
    enum Refusal: Equatable { case sameSite, wrongCellCount, notAWebAddress }

    let columns: [String]
    let emptyCell: String
    private(set) var rows: [Row] = []

    init(columns: [String], emptyCell: String) {
        self.columns = columns
        self.emptyCell = emptyCell
    }

    /// Adds a row of canonical cells, or says why not.
    mutating func add(cells: [String], source: URL) -> Refusal? {
        guard let site = Self.site(of: source) else { return .notAWebAddress }
        guard cells.count == columns.count else { return .wrongCellCount }
        guard !rows.contains(where: { Self.site(of: $0.source) == site }) else { return .sameSite }
        rows.append(Row(cells: cells.map { SheetCells.canonical($0, empty: emptyCell) }, source: source))
        return nil
    }

    /// The site a row counts for: the host, lowercased, without "www.". A
    /// subdomain counts as its own site — a known limit while the app has no
    /// public suffix list.
    static func site(of url: URL) -> String? {
        guard DiaScript.isOpenable(url), let host = url.host?.lowercased() else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}
