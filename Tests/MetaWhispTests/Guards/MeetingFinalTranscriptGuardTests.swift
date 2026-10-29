import XCTest

/// ITER-076 P6 — the saved transcript of a meeting does not come from the
/// live hints.
///
/// The live hints read the streams while the meeting runs; the saved
/// transcript comes from the dual-stream pass over the whole recording, so
/// that every line carries its speaker. The two paths must not drift into
/// each other: a live hint that leaked into the saved transcript would put
/// the user's dictated words into the meeting, and a meeting's own words
/// into the answers.
///
/// The stop path may read what the live hints heard — for its log line, and
/// for nothing else.
final class MeetingFinalTranscriptGuardTests: XCTestCase {

    /// The types the live hints bring into the app.
    private static let liveHintsTypes = [
        "LiveHints",
        "UtteranceTracker",
        "LiveMeetingTranscript",
        "MeetingAnswerService",
        "MeBatcher",
        "SpeechActivity",
        "LiveEngineTranscriber",
        "LiveCall",
    ]

    /// The final transcript path knows nothing about the live hints.
    func testTheFinalTranscriptPathKnowsNothingAboutTheLiveHints() throws {
        let source = try String(contentsOf: Self.appDelegate, encoding: .utf8)

        for function in ["transcribeMeetingDualStream", "persistMeetingTranscript"] {
            let body = try Self.body(of: function, in: source)
            XCTAssertFalse(body.isEmpty, "\(function) was not found in AppDelegate")
            for type in Self.liveHintsTypes {
                XCTAssertFalse(body.contains(type),
                               "\(function) reaches into the live hints (\(type))")
            }
        }
    }

    /// The stop path reads what the live hints heard — for its log line, and
    /// for nothing else.
    func testTheStopPathUsesTheFinalizeOnlyForItsLogLine() throws {
        let source = try String(contentsOf: Self.appDelegate, encoding: .utf8)
        let body = try Self.body(of: "stopMeetingRecording", in: source)

        guard let call = body.range(of: "liveMeetingAdvisor.finalize()") else {
            XCTFail("the stop path does not finalize the live hints")
            return
        }
        // The name the result is bound to.
        let before = String(body[body.startIndex ..< call.lowerBound])
        guard let bound = before.split(whereSeparator: { $0 == " " || $0 == "=" || $0 == "\n" }).last else {
            XCTFail("the result of the finalize call has no name")
            return
        }
        let name = String(bound)

        var isBinding = true
        for line in body.split(separator: "\n") where line.contains(name) {
            if isBinding {
                // The line that binds the result.
                isBinding = false
                continue
            }
            // A line that only names the result again — unwrapping it — is
            // not a use of it.
            let binds = line.contains("= \(name)") || line.contains("=\(name)")
            XCTAssertTrue(line.contains("NSLog") || binds,
                          "the live hints' transcript is used outside a log line: \(line.trimmingCharacters(in: .whitespaces))")
        }
        XCTAssertFalse(isBinding, "the result of the finalize call was never bound")
    }

    /// The application delegate.
    private static var appDelegate: URL {
        repoRoot.appendingPathComponent("App/AppDelegate.swift")
    }

    /// …/Tests/MetaWhispTests/Guards/MeetingFinalTranscriptGuardTests.swift →
    /// the repository's root.
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// The body of a function, braces counted outside the strings and the
    /// comments.
    private static func body(of function: String, in source: String) throws -> String {
        guard let signature = source.range(of: "func \(function)") else {
            throw XCTSkip("the function \(function) is gone — update this guard")
        }
        let characters = Array(source)
        var index = source.distance(from: source.startIndex, to: signature.upperBound)
        while index < characters.endIndex, characters[index] != "{" {
            index += 1
        }
        guard index < characters.endIndex else {
            throw XCTSkip("the function \(function) has no body")
        }

        var depth = 0
        var inString = false
        var escaped = false
        var inLineComment = false
        var inBlockComment = false
        var body: [Character] = []

        while index < characters.endIndex {
            let character = characters[index]
            let next = index + 1 < characters.endIndex ? characters[index + 1] : " "

            if inLineComment {
                if character == "\n" { inLineComment = false }
                index += 1
                continue
            }
            if inBlockComment {
                if character == "*", next == "/" {
                    inBlockComment = false
                    index += 2
                    continue
                }
                index += 1
                continue
            }
            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
                index += 1
                continue
            }
            if character == "/", next == "/" {
                inLineComment = true
                index += 2
                continue
            }
            if character == "/", next == "*" {
                inBlockComment = true
                index += 2
                continue
            }
            if character == "\"" {
                inString = true
                index += 1
                continue
            }
            if character == "{" { depth += 1 }
            if character == "}" {
                depth -= 1
                if depth == 0 { return String(body) }
            }
            if depth >= 1 { body.append(character) }
            index += 1
        }
        throw XCTSkip("the function \(function) has no body")
    }
}
