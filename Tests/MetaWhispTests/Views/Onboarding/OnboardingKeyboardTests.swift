import XCTest
@testable import MetaWhisp

/// D7 / H2 — keyboard and VoiceOver. Return presses the screen's way forward; Tab goes through a screen in reading
/// order — its content, then Back, then the choice; the record button says what it does in each state; and the
/// practice says each change of state once — not every percent of a download, and nothing as the screen appears.
/// The keys themselves are pinned on the source; what they feel like is checked on screen.
final class OnboardingKeyboardTests: XCTestCase {

    private func code(_ file: String) throws -> [String] {
        try OnboardingWindowTests.codeLines(of: "Views/Windows/Onboarding/\(file)")
    }

    // MARK: - Return = primary

    /// One Return per way forward: Get started, Try dictation, Continue, and on the Pro screen Get Pro — or
    /// Continue for a Pro user.
    func testReturnPressesTheWayForwardOnEveryScreen() throws {
        for (file, forward) in [("WelcomeScreen.swift", 1), ("EnableDictationScreen.swift", 1),
                                ("TryVoiceScreen.swift", 1), ("ProScreen.swift", 2)] {
            XCTAssertEqual(try code(file).filter { $0.contains(".keyboardShortcut(.defaultAction)") }.count, forward, file)
        }
        let pro = try code("ProScreen.swift")
        let getPro = try XCTUnwrap(pro.firstIndex { $0.contains("flow.getPro()") })
        XCTAssertTrue(pro[getPro...].prefix(3).contains { $0.contains(".keyboardShortcut(.defaultAction)") },
                      "Return is Get Pro, not Continue with Free")
    }

    /// Space records — on the record button, and on Try again where Try again is a new recording; Esc cancels.
    func testSpaceRecordsAndEscCancels() throws {
        let practice = try code("TryVoiceScreen.swift")
        XCTAssertEqual(practice.filter { $0.contains(".keyboardShortcut(.space, modifiers: [])") }.count, 2)
        XCTAssertEqual(practice.filter { $0.contains(".keyboardShortcut(.cancelAction)") }.count, 1)
    }

    // MARK: - Tab order

    /// The footer is laid out in reading order — Back first, then the choice — so Tab reaches them that way.
    func testTheFooterIsInReadingOrder() throws {
        let page = try code("OnboardingStyle.swift")
        let start = try XCTUnwrap(page.firstIndex { $0.contains("struct OnboardingPage") })
        let body = Array(page[start...])
        let leading = try XCTUnwrap(body.firstIndex { $0.trimmingCharacters(in: .whitespaces).hasPrefix("leading") })
        let center = try XCTUnwrap(body.firstIndex { $0.trimmingCharacters(in: .whitespaces).hasPrefix("center") })
        XCTAssertLessThan(leading, center)
        XCTAssertFalse(body.prefix(center).contains { $0.contains("ZStack") }, "no overlay that reorders them")
    }

    // MARK: - VoiceOver

    /// The record button's label in every state it has.
    func testTheRecordButtonSaysWhatItDoes() throws {
        XCTAssertEqual(TryVoiceScreen.label(.recorder(listening: false, hint: nil)), "Start recording")
        XCTAssertEqual(TryVoiceScreen.label(.recorder(listening: true, hint: nil)), "Listening… tap to stop")
        XCTAssertEqual(TryVoiceScreen.label(.transcribing), "Transcribing…")
        XCTAssertEqual(TryVoiceScreen.label(.preparing(percent: 40)), "Getting dictation ready…")
        XCTAssertTrue(try code("TryVoiceScreen.swift").contains { $0.contains(".accessibilityLabel(label)") },
                      "the button carries it")
    }

    func testEachChangeOfStateIsSaidOnce() {
        let say = TryVoiceScreen.announcement
        XCTAssertEqual(say(.preparing(percent: 40), .recorder(listening: false, hint: "or tap Right ⌘")), "Start recording")
        XCTAssertEqual(say(.recorder(listening: false, hint: nil), .recorder(listening: true, hint: nil)),
                       "Listening… tap to stop")
        XCTAssertEqual(say(.recorder(listening: true, hint: nil), .transcribing), "Transcribing…")
        XCTAssertEqual(say(.transcribing, .result("Send the notes.")), "Your words, ready to use. Send the notes.")
        XCTAssertEqual(say(.transcribing, .noSpeech), "No speech detected. Try again a little closer to the microphone.")
        XCTAssertEqual(say(.recorder(listening: false, hint: nil), .failed("Microphone access is off.")),
                       "Microphone access is off.")
        XCTAssertEqual(say(.recorder(listening: false, hint: nil), .preparing(percent: nil)), "Getting dictation ready…")
        XCTAssertEqual(say(.preparing(percent: 9), .modelProblem(title: "The speech model didn't download.", detail: nil)),
                       "The speech model didn't download.")
    }

    /// A download's every percent is not a change of state; the same state is never said twice.
    func testTheSameStateIsNotSaidAgain() {
        XCTAssertNil(TryVoiceScreen.announcement(.preparing(percent: 40), .preparing(percent: 41)))
        XCTAssertNil(TryVoiceScreen.announcement(.transcribing, .transcribing))
        XCTAssertNil(TryVoiceScreen.announcement(.recorder(listening: false, hint: nil),
                                                 .recorder(listening: false, hint: "or tap Right ⌘")),
                     "the hint changing with Accessibility is not a new state")
    }
}
