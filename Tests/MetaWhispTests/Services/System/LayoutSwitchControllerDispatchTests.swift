import AppKit
import XCTest
@testable import MetaWhisp

@MainActor
final class LayoutSwitchControllerDispatchTests: XCTestCase {
    func test_automaticCorrectionDispatchesToGatewayAndSwitchesSourceOnlyAfterSuccess() async throws {
        let gateway = LayoutTextGatewaySpy(
            automaticOutcome: .replaced,
            manualOutcome: .skipped(.noConvertibleText)
        )
        let inputSource = LayoutInputSourceSpy(current: .englishUS)
        let controller = LayoutSwitchController(
            textGateway: gateway,
            inputSourceService: inputSource
        )
        let completed = expectation(description: "automatic correction dispatched")
        gateway.onAutomaticReplacement = { completed.fulfill() }

        for character in "ghbdtn " {
            controller.handleKeyDown(text: String(character), flags: [])
        }

        await fulfillment(of: [completed], timeout: 1)
        XCTAssertEqual(gateway.automaticRequests.count, 1)
        XCTAssertEqual(gateway.automaticRequests.first?.expectedToken, "ghbdtn")
        XCTAssertEqual(gateway.automaticRequests.first?.replacement, "привет")
        XCTAssertEqual(inputSource.selectedLayouts, [.russian])
    }

    func test_automaticCorrectionUsesProductionPhysicalKeycodes() async throws {
        let gateway = LayoutTextGatewaySpy(
            automaticOutcome: .replaced,
            manualOutcome: .skipped(.noConvertibleText)
        )
        let inputSource = LayoutInputSourceSpy(current: .englishUS)
        let controller = LayoutSwitchController(
            textGateway: gateway,
            inputSourceService: inputSource,
            isKnownWord: { word, language in
                word == "привет" && language == .russian
            }
        )
        let completed = expectation(description: "physical keycode correction dispatched")
        gateway.onAutomaticReplacement = { completed.fulfill() }
        let strokes: [(String, UInt16)] = [
            ("g", 5), ("h", 4), ("b", 11), ("d", 2), ("t", 17), ("n", 45),
            (" ", 49)
        ]

        for (text, keyCode) in strokes {
            controller.handleKeyDown(text: text, keyCode: keyCode, flags: [])
        }

        await fulfillment(of: [completed], timeout: 1)
        XCTAssertEqual(gateway.automaticRequests.first?.expectedToken, "ghbdtn")
        XCTAssertEqual(gateway.automaticRequests.first?.replacement, "привет")
    }

    func test_keycodeTextMismatchResetsTheAutomaticBuffer() async throws {
        let gateway = LayoutTextGatewaySpy(
            automaticOutcome: .replaced,
            manualOutcome: .skipped(.noConvertibleText)
        )
        let controller = LayoutSwitchController(
            textGateway: gateway,
            inputSourceService: LayoutInputSourceSpy(current: .englishUS),
            isKnownWord: { word, language in
                word == "привет" && language == .russian
            }
        )
        let strokes: [(String, UInt16)] = [
            ("g", 0), // keyCode 0 is `a`, so this observed pair is inconsistent.
            ("h", 4), ("b", 11), ("d", 2), ("t", 17), ("n", 45), (" ", 49)
        ]

        for (text, keyCode) in strokes {
            controller.handleKeyDown(text: text, keyCode: keyCode, flags: [])
        }
        try await Task.sleep(for: .milliseconds(80))

        XCTAssertTrue(gateway.automaticRequests.isEmpty)
    }

    func test_doubleShiftDispatchesToGatewayAndSwitchesSourceOnlyAfterSuccess() async throws {
        let gateway = LayoutTextGatewaySpy(
            automaticOutcome: .skipped(.noConvertibleText),
            manualOutcome: .corrected(
                LayoutCorrection(replacement: "привет", targetLayout: .russian)
            )
        )
        let inputSource = LayoutInputSourceSpy(current: .englishUS)
        let controller = LayoutSwitchController(
            textGateway: gateway,
            inputSourceService: inputSource
        )
        let completed = expectation(description: "manual correction dispatched")
        gateway.onManualReplacement = { completed.fulfill() }

        controller.handleFlagsChanged(keyCode: 56, flags: [.shift], timestamp: 100)
        controller.handleFlagsChanged(keyCode: 56, flags: [], timestamp: 110)
        controller.handleFlagsChanged(keyCode: 56, flags: [.shift], timestamp: 200)
        controller.handleFlagsChanged(keyCode: 56, flags: [], timestamp: 210)

        await fulfillment(of: [completed], timeout: 1)
        XCTAssertEqual(gateway.manualRequests, [.englishUS])
        XCTAssertEqual(inputSource.selectedLayouts, [.russian])
    }

    func test_shiftUsedForCapitalThenOneTapDoesNotDispatchManualCorrection() async throws {
        let gateway = LayoutTextGatewaySpy(
            automaticOutcome: .skipped(.noConvertibleText),
            manualOutcome: .corrected(
                LayoutCorrection(replacement: "привет", targetLayout: .russian)
            )
        )
        let inputSource = LayoutInputSourceSpy(current: .englishUS)
        let controller = LayoutSwitchController(
            textGateway: gateway,
            inputSourceService: inputSource
        )

        controller.handleFlagsChanged(keyCode: 56, flags: [.shift], timestamp: 100)
        controller.handleKeyDown(text: "A", flags: [.shift])
        controller.handleFlagsChanged(keyCode: 56, flags: [], timestamp: 110)
        controller.handleFlagsChanged(keyCode: 56, flags: [.shift], timestamp: 200)
        controller.handleFlagsChanged(keyCode: 56, flags: [], timestamp: 210)
        await Task.yield()

        XCTAssertEqual(gateway.manualRequests, [])
        XCTAssertEqual(inputSource.selectedLayouts, [])
    }

    func test_shiftCommandChordThenOneTapDoesNotDispatchManualCorrection() async throws {
        let gateway = LayoutTextGatewaySpy(
            automaticOutcome: .skipped(.noConvertibleText),
            manualOutcome: .corrected(
                LayoutCorrection(replacement: "привет", targetLayout: .russian)
            )
        )
        let inputSource = LayoutInputSourceSpy(current: .englishUS)
        let controller = LayoutSwitchController(
            textGateway: gateway,
            inputSourceService: inputSource
        )

        controller.handleFlagsChanged(keyCode: 56, flags: [.shift], timestamp: 100)
        controller.handleFlagsChanged(keyCode: 55, flags: [.shift, .command], timestamp: 105)
        controller.handleFlagsChanged(keyCode: 55, flags: [.shift], timestamp: 106)
        controller.handleFlagsChanged(keyCode: 56, flags: [], timestamp: 110)
        controller.handleFlagsChanged(keyCode: 56, flags: [.shift], timestamp: 200)
        controller.handleFlagsChanged(keyCode: 56, flags: [], timestamp: 210)
        await Task.yield()

        XCTAssertEqual(gateway.manualRequests, [])
        XCTAssertEqual(inputSource.selectedLayouts, [])
    }

    func test_fourRapidShiftTapsRunOnlyOneManualReplacementAtATime() async throws {
        let gateway = LayoutTextGatewaySpy(
            automaticOutcome: .skipped(.noConvertibleText),
            manualOutcome: .corrected(
                LayoutCorrection(replacement: "привет", targetLayout: .russian)
            ),
            manualDelayMilliseconds: 100
        )
        let controller = LayoutSwitchController(
            textGateway: gateway,
            inputSourceService: LayoutInputSourceSpy(current: .englishUS)
        )

        for timestamp in [100, 200, 300, 400] as [UInt64] {
            controller.handleFlagsChanged(keyCode: 56, flags: [.shift], timestamp: timestamp)
            controller.handleFlagsChanged(keyCode: 56, flags: [], timestamp: timestamp + 10)
        }
        try await Task.sleep(for: .milliseconds(20))

        XCTAssertEqual(gateway.manualRequests.count, 1)
    }

    func test_doubleShiftCancelsAutomaticCorrectionThatHasNotStarted() async throws {
        let gateway = LayoutTextGatewaySpy(
            automaticOutcome: .replaced,
            manualOutcome: .corrected(
                LayoutCorrection(replacement: "привет", targetLayout: .russian)
            )
        )
        let controller = LayoutSwitchController(
            textGateway: gateway,
            inputSourceService: LayoutInputSourceSpy(current: .englishUS)
        )

        for character in "ghbdtn " {
            controller.handleKeyDown(text: String(character), flags: [])
        }
        controller.handleFlagsChanged(keyCode: 56, flags: [.shift], timestamp: 100)
        controller.handleFlagsChanged(keyCode: 56, flags: [], timestamp: 110)
        controller.handleFlagsChanged(keyCode: 56, flags: [.shift], timestamp: 200)
        controller.handleFlagsChanged(keyCode: 56, flags: [], timestamp: 210)
        try await Task.sleep(for: .milliseconds(80))

        XCTAssertEqual(gateway.manualRequests.count, 1)
        XCTAssertEqual(gateway.automaticRequests.count, 0)
    }

    func test_controllerObservationIsRequestedWhenOnlyDoubleShiftIsEnabled() {
        XCTAssertTrue(
            LayoutSwitchController.shouldObserveInput(
                featureEnabled: true,
                automaticEnabled: false,
                doubleShiftEnabled: true
            )
        )
        XCTAssertFalse(
            LayoutSwitchController.shouldObserveInput(
                featureEnabled: true,
                automaticEnabled: false,
                doubleShiftEnabled: false
            )
        )
    }

    func test_captureSafetyFailurePreventsBufferingLexiconAndAutomaticDispatch() async throws {
        let gateway = LayoutTextGatewaySpy(
            automaticOutcome: .replaced,
            manualOutcome: .skipped(.noConvertibleText)
        )
        var lexiconLookupCount = 0
        let controller = LayoutSwitchController(
            textGateway: gateway,
            inputSourceService: LayoutInputSourceSpy(current: .englishUS),
            isKnownWord: { _, _ in
                lexiconLookupCount += 1
                return true
            },
            permitsInputCapture: { false }
        )

        for character in "ghbdtn " {
            controller.handleKeyDown(text: String(character), flags: [])
        }
        try await Task.sleep(for: .milliseconds(40))

        XCTAssertEqual(lexiconLookupCount, 0)
        XCTAssertTrue(gateway.automaticRequests.isEmpty)
    }

    func test_captureSafetyFailurePreventsDoubleShiftDispatch() async {
        let gateway = LayoutTextGatewaySpy(
            automaticOutcome: .skipped(.noConvertibleText),
            manualOutcome: .corrected(
                LayoutCorrection(replacement: "привет", targetLayout: .russian)
            )
        )
        let controller = LayoutSwitchController(
            textGateway: gateway,
            inputSourceService: LayoutInputSourceSpy(current: .englishUS),
            permitsInputCapture: { false }
        )

        controller.handleFlagsChanged(keyCode: 56, flags: [.shift], timestamp: 100)
        controller.handleFlagsChanged(keyCode: 56, flags: [], timestamp: 110)
        controller.handleFlagsChanged(keyCode: 56, flags: [.shift], timestamp: 200)
        controller.handleFlagsChanged(keyCode: 56, flags: [], timestamp: 210)
        await Task.yield()

        XCTAssertTrue(gateway.manualRequests.isEmpty)
    }

    func test_focusChangeDiscardsBufferedWordBeforeSeparator() async throws {
        let gateway = LayoutTextGatewaySpy(
            automaticOutcome: .replaced,
            manualOutcome: .skipped(.noConvertibleText)
        )
        var context = LayoutInputContextIdentity(
            processIdentifier: 10,
            focusedElementHash: 100
        )
        let controller = LayoutSwitchController(
            textGateway: gateway,
            inputSourceService: LayoutInputSourceSpy(current: .englishUS),
            isKnownWord: { word, language in
                word == "привет" && language == .russian
            },
            inputContextIdentity: { context }
        )

        for character in "ghbdtn" {
            controller.handleKeyDown(text: String(character), flags: [])
        }
        context = LayoutInputContextIdentity(
            processIdentifier: 10,
            focusedElementHash: 200
        )
        controller.handleKeyDown(text: " ", flags: [])
        try await Task.sleep(for: .milliseconds(40))

        XCTAssertTrue(gateway.automaticRequests.isEmpty)
    }

    func test_focusChangeBreaksDoubleShiftGesture() async {
        let gateway = LayoutTextGatewaySpy(
            automaticOutcome: .skipped(.noConvertibleText),
            manualOutcome: .corrected(
                LayoutCorrection(replacement: "привет", targetLayout: .russian)
            )
        )
        var context = LayoutInputContextIdentity(
            processIdentifier: 10,
            focusedElementHash: 100
        )
        let controller = LayoutSwitchController(
            textGateway: gateway,
            inputSourceService: LayoutInputSourceSpy(current: .englishUS),
            inputContextIdentity: { context }
        )

        controller.handleFlagsChanged(keyCode: 56, flags: [.shift], timestamp: 100)
        controller.handleFlagsChanged(keyCode: 56, flags: [], timestamp: 110)
        context = LayoutInputContextIdentity(
            processIdentifier: 10,
            focusedElementHash: 200
        )
        controller.handleFlagsChanged(keyCode: 56, flags: [.shift], timestamp: 200)
        controller.handleFlagsChanged(keyCode: 56, flags: [], timestamp: 210)
        await Task.yield()

        XCTAssertTrue(gateway.manualRequests.isEmpty)
    }

    func test_failedAutomaticReplacementDoesNotSwitchInputSource() async throws {
        let gateway = LayoutTextGatewaySpy(
            automaticOutcome: .skipped(.mutationFailed),
            manualOutcome: .skipped(.noConvertibleText)
        )
        let inputSource = LayoutInputSourceSpy(current: .englishUS)
        let controller = LayoutSwitchController(
            textGateway: gateway,
            inputSourceService: inputSource
        )
        let completed = expectation(description: "failed automatic correction dispatched")
        gateway.onAutomaticReplacement = { completed.fulfill() }

        for character in "ghbdtn " {
            controller.handleKeyDown(text: String(character), flags: [])
        }

        await fulfillment(of: [completed], timeout: 1)
        XCTAssertEqual(inputSource.selectedLayouts, [])
    }

    func test_automaticCorrectionRetriesOnceWhenEditorHasNotCommittedSeparator() async throws {
        let gateway = LayoutTextGatewaySpy(
            automaticOutcomes: [.skipped(.staleTarget), .replaced],
            manualOutcome: .skipped(.noConvertibleText)
        )
        let inputSource = LayoutInputSourceSpy(current: .englishUS)
        let controller = LayoutSwitchController(
            textGateway: gateway,
            inputSourceService: inputSource
        )
        let completed = expectation(description: "automatic correction retries after stale target")
        gateway.onAutomaticReplacement = {
            guard gateway.automaticRequests.count == 2 else { return }
            completed.fulfill()
        }

        for character in "ghbdtn " {
            controller.handleKeyDown(text: String(character), flags: [])
        }

        await fulfillment(of: [completed], timeout: 1)
        XCTAssertEqual(inputSource.selectedLayouts, [.russian])
    }

    func test_automaticCorrectionUsesSystemLexiconBeyondBootstrapFixtures() async throws {
        let gateway = LayoutTextGatewaySpy(
            automaticOutcome: .replaced,
            manualOutcome: .skipped(.noConvertibleText)
        )
        let inputSource = LayoutInputSourceSpy(current: .englishUS)
        let controller = LayoutSwitchController(
            textGateway: gateway,
            inputSourceService: inputSource,
            isKnownWord: { word, language in
                word == "машина" && language == .russian
            }
        )
        let completed = expectation(description: "automatic correction dispatches a non-bootstrap word")
        gateway.onAutomaticReplacement = { completed.fulfill() }

        for character in "vfibyf " {
            controller.handleKeyDown(text: String(character), flags: [])
        }

        await fulfillment(of: [completed], timeout: 1)
        XCTAssertEqual(gateway.automaticRequests.first?.replacement, "машина")
        XCTAssertEqual(inputSource.selectedLayouts, [.russian])
    }
}

@MainActor
private final class LayoutTextGatewaySpy: LayoutTextCorrecting {
    struct AutomaticRequest: Equatable {
        let expectedToken: String
        let trailingText: String
        let replacement: String
    }

    var automaticRequests: [AutomaticRequest] = []
    var manualRequests: [KeyboardLayout] = []
    var onAutomaticReplacement: (() -> Void)?
    var onManualReplacement: (() -> Void)?

    private var automaticOutcomes: [FocusedTextGateway.ReplacementOutcome]
    private let manualOutcome: FocusedTextGateway.ManualCorrectionOutcome
    private let manualDelayMilliseconds: Int

    init(
        automaticOutcome: FocusedTextGateway.ReplacementOutcome,
        manualOutcome: FocusedTextGateway.ManualCorrectionOutcome,
        manualDelayMilliseconds: Int = 0
    ) {
        automaticOutcomes = [automaticOutcome]
        self.manualOutcome = manualOutcome
        self.manualDelayMilliseconds = manualDelayMilliseconds
    }

    init(
        automaticOutcomes: [FocusedTextGateway.ReplacementOutcome],
        manualOutcome: FocusedTextGateway.ManualCorrectionOutcome
    ) {
        self.automaticOutcomes = automaticOutcomes
        self.manualOutcome = manualOutcome
        self.manualDelayMilliseconds = 0
    }

    func replaceTokenBeforeCaret(
        expectedToken: String,
        trailingText: String,
        replacement: String,
        isStillCurrent: @escaping @MainActor () -> Bool
    ) async -> FocusedTextGateway.ReplacementOutcome {
        automaticRequests.append(
            AutomaticRequest(
                expectedToken: expectedToken,
                trailingText: trailingText,
                replacement: replacement
            )
        )
        onAutomaticReplacement?()
        return automaticOutcomes.count > 1
            ? automaticOutcomes.removeFirst()
            : automaticOutcomes[0]
    }

    func correctSelectedTextOrCurrentLine(
        typedIn source: KeyboardLayout,
        mapper: KeyboardLayoutMapper,
        isStillCurrent: @escaping @MainActor () -> Bool
    ) async -> FocusedTextGateway.ManualCorrectionOutcome {
        manualRequests.append(source)
        if manualDelayMilliseconds > 0 {
            try? await Task.sleep(for: .milliseconds(manualDelayMilliseconds))
        }
        onManualReplacement?()
        return manualOutcome
    }
}

@MainActor
private final class LayoutInputSourceSpy: LayoutInputSourceManaging {
    private let current: KeyboardLayout?
    var selectedLayouts: [KeyboardLayout] = []

    init(current: KeyboardLayout?) {
        self.current = current
    }

    func currentLayout() -> KeyboardLayout? {
        current
    }

    @discardableResult
    func select(_ layout: KeyboardLayout) -> Bool {
        selectedLayouts.append(layout)
        return true
    }
}
