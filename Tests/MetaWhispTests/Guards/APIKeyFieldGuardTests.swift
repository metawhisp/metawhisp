import XCTest
@testable import MetaWhisp

/// An API key is typed, saved and shown in one place: `APIKeyField`. Before it, four Settings fields each rolled
/// their own: two saved the setting on every keystroke (the first character became the key, the field turned into
/// its masked label, and the label's repeat count went negative under four characters, which traps), two kept a
/// draft, and each wrote its own mask. This scans the SOURCE of the views and the app so no field hand-rolls a key
/// again.
final class APIKeyFieldGuardTests: XCTestCase {
    private var repoRoot: URL {
        // …/Tests/MetaWhispTests/Guards/APIKeyFieldGuardTests.swift → repo root
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private let fieldFile = "Views/Components/APIKeyField.swift"

    /// Every Swift file under `Views/` and `App/` but the field itself, as (repo path, code lines without comments).
    private func scannedCode() throws -> [(name: String, lines: [String])] {
        var result: [(name: String, lines: [String])] = []
        for folder in ["Views", "App"] {
            let walker = try XCTUnwrap(FileManager.default.enumerator(
                at: repoRoot.appendingPathComponent(folder), includingPropertiesForKeys: nil))
            for case let file as URL in walker where file.pathExtension == "swift" {
                let name = file.path.replacingOccurrences(of: repoRoot.path + "/", with: "")
                guard name != fieldFile else { continue }
                let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
                    .map { line in line.range(of: "//").map { String(line[..<$0.lowerBound]) } ?? line }
                result.append((name, lines))
            }
        }
        XCTAssertGreaterThan(result.count, 50, "the guard must read the views — path resolution broke")
        return result
    }

    private func offenders(matching pattern: String) throws -> [String] {
        let regex = try NSRegularExpression(pattern: pattern)
        var found: [String] = []
        for file in try scannedCode() {
            for (index, line) in file.lines.enumerated()
            where regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil {
                found.append("\(file.name):\(index + 1)")
            }
        }
        return found
    }

    /// A mask built by hand: a run of bullets. Only `APIKeyField.masked` draws a stored key.
    func testNoViewMasksAKeyByHand() throws {
        XCTAssertEqual(try offenders(matching: #"repeating: "(\\u\{2022\}|•)""#), [],
                       "a stored key is drawn through APIKeyField.masked")
    }

    /// A key setting written from a text field's binding, i.e. on every keystroke, or a key text field of its own.
    func testNoViewSavesAKeyPerKeystroke() throws {
        XCTAssertEqual(try offenders(matching: #"(groqKey|openaiKey|cerebrasKey|deepgramKey|geminiKey|activeAPIKey) = \$0"#),
                       [], "a key is saved from APIKeyField's draft, on Return or Save")
        XCTAssertEqual(try offenders(matching: #"prompt: Text\(.*API Key"#), [],
                       "a key is typed into APIKeyField")
    }

    /// Each key the settings hold is typed into its own `APIKeyField` in Settings.
    func testEveryKeyHasItsField() throws {
        let settings = try XCTUnwrap(scannedCode().first { $0.name == "Views/Windows/MainSettingsView.swift" })
        for key in ["groqKey", "activeAPIKey", "deepgramKey", "geminiKey"] {
            XCTAssertTrue(settings.lines.contains { $0.contains("APIKeyField(") && $0.contains("key: \\.\(key)") },
                          "no APIKeyField for \(key)")
        }
    }
}
