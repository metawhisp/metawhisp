import XCTest
@testable import MetaWhisp

/// Exercises the live owner's stage ordering without ScreenCaptureKit, OCR, or windows.
@MainActor
final class ScreenContextCaptureCancellationTests: XCTestCase {
    func testSessionStopDuringEnumerationSkipsScreenshotAndOCR() async {
        await assertCancellationDuringEnumeration(stopSession: true)
    }

    func testAnswerStopDuringEnumerationSkipsScreenshotAndOCR() async {
        // Balance halt stops this same answer owner and its capture task.
        await assertCancellationDuringEnumeration(stopSession: false)
    }

    private func assertCancellationDuringEnumeration(stopSession: Bool) async {
        var stages: [String] = []
        let active = await ScreenContextService.runCapturePipeline(
            isCancelled: { false },
            enumerate: { stages.append("enumerate"); return 1 },
            prepare: { stages.append("prepare"); return $0 },
            screenshot: { stages.append("screenshot"); return $0 },
            recognize: { _ in stages.append("OCR"); return "Screen text" })
        XCTAssertEqual(stages, ["enumerate", "prepare", "screenshot", "OCR"])
        XCTAssertEqual(active?.text, "Screen text")

        let token = LiveHintsStopToken()
        let gate = RequestGate()
        var prepared = 0
        var screenshots = 0
        var recognitions = 0
        let harness = makeAnswerHarness(stopToken: token, screenEnabled: { true }, captureScreen: {
            let result = await ScreenContextService.runCapturePipeline(
                isCancelled: { Task.isCancelled },
                enumerate: { await gate.wait(); return 1 },
                prepare: { prepared += 1; return $0 },
                screenshot: { screenshots += 1; return $0 },
                recognize: { _ in recognitions += 1; return "Screen text" })
            return result?.text
        })
        let capture = harness.service.requestScreen()
        await harness.waitUntil { gate.waiterCount == 1 }
        XCTAssertEqual(gate.waiterCount, 1)
        if stopSession { token.stop() } else { harness.service.stop() }
        gate.open()
        await capture?.value

        XCTAssertEqual(prepared, 0, "cancelled enumeration must not prepare a capture")
        XCTAssertEqual(screenshots, 0, "capture started after its owner stopped")
        XCTAssertEqual(recognitions, 0, "OCR started after its owner stopped")
        XCTAssertEqual(harness.requestCount, 0)
        harness.service.stop()
    }

    func testCancellationAfterPreparationSkipsScreenshotAndOCR() async {
        let token = LiveHintsStopToken()
        var screenshots = 0
        var recognitions = 0
        let result = await ScreenContextService.runCapturePipeline(
            isCancelled: { token.isCancelled },
            enumerate: { 1 },
            prepare: { token.stop(); return $0 },
            screenshot: { screenshots += 1; return $0 },
            recognize: { _ in recognitions += 1; return "Screen text" })
        XCTAssertNil(result)
        XCTAssertEqual(screenshots, 0)
        XCTAssertEqual(recognitions, 0)
    }

    func testCancellationDuringScreenshotSkipsOCR() async {
        let token = LiveHintsStopToken()
        let gate = RequestGate()
        let entered = expectation(description: "screenshot started")
        var recognitions = 0
        let capture = Task { @MainActor in
            await ScreenContextService.runCapturePipeline(
                isCancelled: { token.isCancelled },
                enumerate: { 1 },
                prepare: { $0 },
                screenshot: { shot in entered.fulfill(); await gate.wait(); return shot },
                recognize: { _ in recognitions += 1; return "Screen text" })
        }
        await fulfillment(of: [entered], timeout: 2)
        token.stop()
        gate.open()
        let result = await capture.value
        XCTAssertNil(result)
        XCTAssertEqual(recognitions, 0)
    }

    func testCancelledCaptureNeverEnumerates() async {
        var enumerations = 0
        let result = await ScreenContextService.runCapturePipeline(
            isCancelled: { true },
            enumerate: { enumerations += 1; return 1 },
            prepare: { $0 },
            screenshot: { $0 },
            recognize: { _ in "Screen text" })
        XCTAssertNil(result)
        XCTAssertEqual(enumerations, 0)
    }
}
