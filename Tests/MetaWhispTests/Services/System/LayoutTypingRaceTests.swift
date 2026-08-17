import AppKit
import XCTest
@testable import MetaWhisp

/// Release review, 2026-08-16 — the flagship scenario corrupted text.
///
/// To replace a word, the gateway makes it a REAL selection in the target
/// field, then proves it with Cmd-C and replaces it with Cmd-V. That live
/// selection sat in the user's document across ~180 ms of waiting. A 50-70 WPM
/// typist emits a character every 170-240 ms, so when someone typed a PHRASE in
/// the wrong layout — the whole point of the feature — the next character of
/// word two landed while word one was still selected. The target app replaced
/// the selected word with that character, and our paste then went in at the new
/// caret: `ghbdtn rfr` became `rпривет `. Silently: verification failed
/// afterwards, so no toast ever appeared, and undo was split across two steps.
///
/// Nothing aborted it. `handleKeyDown` reset the word buffer but never
/// cancelled an in-flight correction, and `targetIsStillFocused` compares the
/// frontmost pid and focused element — neither of which typing changes.
///
/// The contract pinned here: a correction belongs to the keystroke that
/// scheduled it. Any later key input invalidates it, at every checkpoint
/// including the one immediately before the paste is posted.
@MainActor
final class LayoutTypingRaceTests: XCTestCase {

    private func makeController(
        gateway: TypingRaceGatewaySpy,
        inputSource: TypingRaceInputSourceSpy
    ) -> LayoutSwitchController {
        LayoutSwitchController(textGateway: gateway, inputSourceService: inputSource)
    }

    /// Types `ghbdtn` plus its separator, which schedules a correction.
    private func typeQualifyingWord(into controller: LayoutSwitchController) {
        for character in "ghbdtn " {
            controller.handleKeyDown(text: String(character), flags: [])
        }
    }

    // MARK: - The requirement: a whole phrase, typed without pausing

    func test_phraseTypedWithoutPausing_correctsEveryWord() async throws {
        let gateway = TypingRaceGatewaySpy()
        let inputSource = TypingRaceInputSourceSpy(current: .englishUS)
        let controller = LayoutSwitchController(
            textGateway: gateway,
            inputSourceService: inputSource,
            isKnownWord: { word, language in
                language == .russian && ["привет", "как"].contains(word)
            }
        )

        // ~200 WPM, faster than the founder types. Each word must be corrected
        // before the next one is finished — the whole reason the automatic path
        // types instead of pasting.
        for character in "ghbdtn " {
            controller.handleKeyDown(text: String(character), flags: [])
        }
        try await Task.sleep(for: .milliseconds(60))
        for character in "rfr " {
            controller.handleKeyDown(text: String(character), flags: [])
        }
        try await Task.sleep(for: .milliseconds(60))

        XCTAssertEqual(gateway.automaticRequests.count, 2,
                       "Both words of a phrase must be corrected while the user keeps typing")
        XCTAssertEqual(gateway.automaticRequests.map(\.replacement), ["привет", "как"])
        XCTAssertEqual(inputSource.selectedLayouts, [.russian, .russian])
    }

    // MARK: - The regression

    func test_keystrokeDuringTheScheduleWindow_abortsTheCorrectionEntirely() async throws {
        let gateway = TypingRaceGatewaySpy()
        let inputSource = TypingRaceInputSourceSpy(current: .englishUS)
        let controller = makeController(gateway: gateway, inputSource: inputSource)

        typeQualifyingWord(into: controller)
        // The user keeps typing the next word before the 16 ms dispatch delay
        // has elapsed. This is the ordinary case, not an edge case.
        controller.handleKeyDown(text: "r", flags: [])

        try await Task.sleep(for: .milliseconds(200))

        XCTAssertTrue(gateway.automaticRequests.isEmpty,
                      "A correction must never reach the text gateway once the user has typed on")
        XCTAssertTrue(inputSource.selectedLayouts.isEmpty,
                      "And the input source must not be switched for a correction that never happened")
    }

    func test_lateKeystroke_invalidatesTheCorrectionMidFlight() async throws {
        let gateway = TypingRaceGatewaySpy()
        let inputSource = TypingRaceInputSourceSpy(current: .englishUS)
        let controller = makeController(gateway: gateway, inputSource: inputSource)

        let reachedGateway = expectation(description: "gateway reached")
        gateway.onAutomaticReplacement = { reachedGateway.fulfill() }

        typeQualifyingWord(into: controller)
        await fulfillment(of: [reachedGateway], timeout: 1)

        // The gateway is now mid-transaction, holding a live selection. This is
        // the window in which the old code let the user's own keystroke eat the
        // selected word.
        let currencyBeforeTyping = gateway.capturedIsStillCurrent?()
        XCTAssertEqual(currencyBeforeTyping, true,
                       "Nothing has happened yet — the correction is still the current one")

        controller.handleKeyDown(text: "r", flags: [])

        XCTAssertEqual(gateway.capturedIsStillCurrent?(), false,
                       "Once the user types, every remaining checkpoint — including the one right before the paste — must abort")
    }

    func test_undisturbedTyping_stillCorrects() async throws {
        let gateway = TypingRaceGatewaySpy()
        let inputSource = TypingRaceInputSourceSpy(current: .englishUS)
        let controller = makeController(gateway: gateway, inputSource: inputSource)

        let completed = expectation(description: "correction dispatched")
        gateway.onAutomaticReplacement = { completed.fulfill() }

        typeQualifyingWord(into: controller)

        await fulfillment(of: [completed], timeout: 1)
        XCTAssertEqual(gateway.automaticRequests.count, 1)
        XCTAssertEqual(gateway.automaticRequests.first?.expectedToken, "ghbdtn")
        XCTAssertEqual(gateway.capturedIsStillCurrent?(), true,
                       "A user who pauses after the separator must still get their correction")
        XCTAssertEqual(inputSource.selectedLayouts, [.russian])
    }

    /// A modifier press is not text input and must not throw the correction away
    /// — otherwise reaching for Shift to start the next word would cancel it.
    func test_modifierAlone_doesNotInvalidateTheCorrection() async throws {
        let gateway = TypingRaceGatewaySpy()
        let inputSource = TypingRaceInputSourceSpy(current: .englishUS)
        let controller = makeController(gateway: gateway, inputSource: inputSource)

        let reachedGateway = expectation(description: "gateway reached")
        gateway.onAutomaticReplacement = { reachedGateway.fulfill() }

        typeQualifyingWord(into: controller)
        await fulfillment(of: [reachedGateway], timeout: 1)

        controller.handleFlagsChanged(keyCode: 56, flags: [.shift], timestamp: 1_000)

        XCTAssertEqual(gateway.capturedIsStillCurrent?(), true,
                       "Holding Shift inserts no characters and cannot eat the selection")
    }
}

// MARK: - Spies

@MainActor
private final class TypingRaceGatewaySpy: LayoutTextCorrecting {
    struct AutomaticRequest: Equatable {
        let expectedToken: String
        let replacement: String
    }

    var automaticRequests: [AutomaticRequest] = []
    var onAutomaticReplacement: (() -> Void)?
    /// Held so a test can ask, later, what the gateway would see at its next
    /// checkpoint — that is exactly the question the real gateway asks before
    /// selecting, before copying and before pasting.
    var capturedIsStillCurrent: (@MainActor () -> Bool)?

    func replaceTokenBeforeCaret(
        expectedToken: String,
        trailingText: String,
        replacement: String,
        isStillCurrent: @escaping @MainActor () -> Bool
    ) async -> FocusedTextGateway.ReplacementOutcome {
        capturedIsStillCurrent = isStillCurrent
        automaticRequests.append(
            AutomaticRequest(expectedToken: expectedToken, replacement: replacement)
        )
        onAutomaticReplacement?()
        return .replaced
    }

    func correctSelectedTextOrCurrentLine(
        typedIn source: KeyboardLayout,
        mapper: KeyboardLayoutMapper,
        isStillCurrent: @escaping @MainActor () -> Bool
    ) async -> FocusedTextGateway.ManualCorrectionOutcome {
        capturedIsStillCurrent = isStillCurrent
        return .skipped(.noConvertibleText)
    }
}

@MainActor
private final class TypingRaceInputSourceSpy: LayoutInputSourceManaging {
    private let current: KeyboardLayout
    var selectedLayouts: [KeyboardLayout] = []

    init(current: KeyboardLayout) {
        self.current = current
    }

    func currentLayout() -> KeyboardLayout? { current }

    @discardableResult
    func select(_ layout: KeyboardLayout) -> Bool {
        selectedLayouts.append(layout)
        return true
    }
}
