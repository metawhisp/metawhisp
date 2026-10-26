import Foundation
@testable import MetaWhisp

/// Stands in for a new Google Sheet at level 3 (ITER-074 §12.1). It accepts a
/// paste of tab-separated rows and shows its cells the way Sheets does where
/// it matters: a leading apostrophe makes the rest text and is not shown; a
/// cell starting with "=" becomes a formula, which shows its result — never
/// the text that was pasted. The fixture does not compute results; it shows
/// `formulaResult`.
@MainActor
final class FixtureSheet: SheetDestination {
    enum FixtureSheetError: Error { case unknownSheet }

    static let formulaResult = "(formula result)"

    private(set) var title: String?
    private var address: URL?
    private var cells: [[String]] = []
    private var holdsFormula = false

    /// The Sheet exists the moment it has an address: the receipt goes out
    /// before `create` returns.
    func create(title: String, made: @escaping @MainActor (URL) -> Void) async throws -> URL {
        let address = URL(string: "https://sheets.test/\(UUID().uuidString)")!
        self.title = title
        self.address = address
        made(address)
        return address
    }

    func paste(_ text: String, into sheet: URL) async throws {
        guard sheet == address else { throw FixtureSheetError.unknownSheet }
        cells = text.components(separatedBy: "\n").map { line in
            line.components(separatedBy: "\t").map { cell in
                if cell.hasPrefix("'") { return String(cell.dropFirst()) }
                guard cell.hasPrefix("=") else { return cell }
                holdsFormula = true
                return Self.formulaResult
            }
        }
    }

    func readBack(_ sheet: URL) async throws -> SheetReadBack {
        guard sheet == address else { throw FixtureSheetError.unknownSheet }
        return SheetReadBack(cells: cells, holdsFormula: holdsFormula)
    }
}
