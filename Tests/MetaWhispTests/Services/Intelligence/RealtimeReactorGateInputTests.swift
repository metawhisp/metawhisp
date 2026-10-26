import XCTest
@testable import MetaWhisp

/// 2026-10-20 — the task reactor's gate was given the model's whole prompt,
/// which carries "USER-REJECTED TASKS (… do NOT extract similar)": a
/// do-not-repeat list, the same input that made the proactive and advice
/// gates read old items as live ones. The gate now judges the screen alone.
/// The model keeps the list, and the reactor's duplicate check after the
/// model already covers tasks dismissed in the last 30 days.
@MainActor
final class RealtimeReactorGateInputTests: XCTestCase {

    private let dismissed = "Send the invoice to Sam"

    /// The model's prompt still names what the user dismissed; the prompt
    /// built for the gate does not.
    func testTheGatePromptCarriesTheScreenAndNoDismissedTasks() {
        let model = RealtimeScreenReactor.buildPrompt(
            appName: "Mail", windowTitle: "Inbox - Alex", ocr: "Lunch on Friday?",
            rejectedExamples: [dismissed])
        XCTAssertTrue(model.contains("USER-REJECTED TASKS"))
        XCTAssertTrue(model.contains(dismissed))

        let gate = RealtimeScreenReactor.buildPrompt(
            appName: "Mail", windowTitle: "Inbox - Alex", ocr: "Lunch on Friday?")
        XCTAssertFalse(gate.contains("USER-REJECTED"), "no do-not-repeat list")
        XCTAssertTrue(gate.contains("Inbox - Alex"))
        XCTAssertTrue(gate.contains("Lunch on Friday?"))
    }

    /// The wiring, read off the source: the gate is handed the screen-only
    /// prompt, the model the full one.
    func testReactHandsTheGateTheScreenOnlyPrompt() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../../Services/Intelligence/RealtimeScreenReactor.swift").standardized
        let source = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(source.contains(
            "let gateContext = Self.buildPrompt(appName: context.appName, windowTitle: context.windowTitle, ocr: context.ocrText)"))
        XCTAssertTrue(source.contains("context: gateContext,"), "the gate reads it")
        XCTAssertFalse(source.contains("context: prompt,"), "not the model's prompt")
    }
}
