import XCTest

/// ITER-076 P5, §5 — the licence notices of the copied sources travel with
/// the app.
///
/// They are a condition of the licences, not a README: the file has to be in
/// the bundle, and the build has to refuse to produce a bundle without it.
final class ThirdPartyNoticesTests: XCTestCase {

    func testScreenTextsHaveTheirSourcesCommitsAndChangeNotice() throws {
        for path in ["THIRD_PARTY_NOTICES.md", "Services/Intelligence/LiveHints/MeetingAnswerPrompts.swift"] {
            let text = try String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8)
            let lines = text.components(separatedBy: .newlines)
            XCTAssertTrue(lines.contains {
                $0.contains("SCREENSHOT_PROMPT") && $0.contains("chat.ts:26-28") && $0.contains("efc31a8")
            }, path)
            XCTAssertTrue(lines.contains {
                $0.contains("Changed SCREENSHOT_PROMPT") && $0.contains("first sentence")
                    && $0.contains("This is the text on the user's current screen.")
            }, path)
            XCTAssertTrue(lines.contains {
                $0.contains("<screen_and_transcript_interaction>") && $0.contains("claudeService.ts:212-220")
                    && $0.contains("692cd17")
            }, path)
        }
    }

    func testTypedAnswerInstructionHasItsSourceAndCommit() throws {
        for path in ["THIRD_PARTY_NOTICES.md", "Services/Intelligence/LiveHints/MeetingAnswerPrompts.swift"] {
            let text = try String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8)
            XCTAssertTrue(text.components(separatedBy: .newlines).contains {
                $0.contains("typed answer instruction") && $0.contains("chat.ts:148") && $0.contains("efc31a8")
            }, path)
        }
    }

    func testEachActionPromptHasItsSourceLinesAndCommitInBothNotices() throws {
        let notices = try String(contentsOf: repoRoot.appendingPathComponent("THIRD_PARTY_NOTICES.md"), encoding: .utf8)
        let prompts = try String(contentsOf: repoRoot.appendingPathComponent("Services/Intelligence/LiveHints/MeetingAnswerPrompts.swift"), encoding: .utf8)
        let header = prompts.components(separatedBy: "enum MeetingAnswerPrompts")[0]
        let sources = [
            ("ACTION_PROMPTS['follow-up']", "claudeService.ts:286-295"),
            ("ACTION_PROMPTS.recap", "claudeService.ts:297-306"),
            ("ACTION_PROMPTS['tell-me-more']", "claudeService.ts:308-318"),
        ]
        for (name, location) in sources {
            for text in [notices, header] {
                XCTAssertTrue(text.components(separatedBy: .newlines).contains {
                    $0.contains(name) && $0.contains(location) && $0.contains("692cd17")
                }, "Missing attribution for \(name)")
            }
        }
    }

    /// build.sh copies the notices into the bundle's Resources, and fails
    /// when the file is not there.
    func testTheBuildCopiesTheNoticesIntoTheBundleAndFailsWithoutThem() throws {
        let script = try String(contentsOf: repoRoot.appendingPathComponent("build.sh"), encoding: .utf8)
        let lines = script.components(separatedBy: .newlines)

        guard let copy = lines.firstIndex(where: {
            $0.contains("cp \"$NOTICES\" \"$RESOURCES/THIRD_PARTY_NOTICES.md\"")
        }) else {
            XCTFail("build.sh does not copy the notices into the bundle's Resources")
            return
        }
        guard let check = lines.firstIndex(where: { $0.contains("if [ ! -f \"$NOTICES\" ]; then") }) else {
            XCTFail("build.sh does not look for the notices")
            return
        }
        XCTAssertLessThan(check, copy, "the file is looked for before it is copied")
        XCTAssertTrue(lines[check...copy].joined(separator: "\n").contains("exit 1"),
                      "the build fails without the notices")
    }

    /// The file itself holds every notice and the licence text it needs.
    ///
    /// The sources are found by where they are used and their licences are
    /// read out of the file: the test does not name them (§5).
    func testTheNoticesHoldTheSourcesOfTheInCallHintsAndTheirLicences() throws {
        let notices = try String(contentsOf: repoRoot.appendingPathComponent("THIRD_PARTY_NOTICES.md"),
                                 encoding: .utf8)
        // Every source is a section of its own.
        let sections = notices.components(separatedBy: "\n## ").dropFirst()
        XCTAssertFalse(sections.isEmpty, "the notices hold no source at all")

        // The sources the in-call hints were copied from are the ones whose
        // notice says where they are used.
        let hintsSources = sections.filter { $0.contains("Services/Intelligence/LiveHints/") }
        XCTAssertEqual(hintsSources.count, 2,
                       "the notices do not hold both sources of the in-call hints")
        for source in hintsSources {
            XCTAssertTrue(source.contains("Source: https://"),
                          "a source of the in-call hints has no origin")
            XCTAssertTrue(source.contains("License"),
                          "a source of the in-call hints has no licence")
        }

        // The licences the copied sources come under.
        XCTAssertTrue(notices.contains("Apache License"), "the Apache text")
        XCTAssertTrue(notices.contains("MIT License"), "the MIT text")
    }

    /// There is no About tab in this app: the notices are opened from the
    /// General tab, from the copy inside the bundle.
    func testTheSettingsOpenTheBundledNotices() throws {
        let view = try String(contentsOf: repoRoot.appendingPathComponent("Views/Windows/MainSettingsView.swift"),
                              encoding: .utf8)
        XCTAssertTrue(view.contains("Open-source notices"), "the link is there")
        XCTAssertTrue(view.contains(#"Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md")"#),
                      "the bundled copy is opened")
    }

    /// …/Tests/MetaWhispTests/Services/System/ThirdPartyNoticesTests.swift →
    /// the repository's root.
    private var repoRoot: URL {
        var url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { break }
            url = parent
        }
        return url
    }
}
