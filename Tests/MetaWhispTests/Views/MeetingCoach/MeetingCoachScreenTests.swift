import XCTest
@testable import MetaWhisp

/// State and native controls are exercised without creating a window.
@MainActor
final class MeetingCoachScreenTests: XCTestCase {
    func testScreenIsHiddenWhileTheSettingIsOffAndImmediatelyAfterItTurnsOff() {
        let settings = AppSettings.shared
        let original = settings.screenContextEnabled
        defer { settings.screenContextEnabled = original }
        let state = MeetingCoachState()
        state.arm()
        let view = MeetingCoachView(state: state)

        settings.screenContextEnabled = false
        XCTAssertFalse(view.showsScreenButton)
        settings.screenContextEnabled = true
        XCTAssertTrue(view.showsScreenButton)
        settings.screenContextEnabled = false
        XCTAssertFalse(view.showsScreenButton)
    }

    func testScreenPressUsesItsDedicatedSynchronousEntryPointOnlyWhileArmed() {
        let state = MeetingCoachState()
        var screens = 0
        var actions = 0
        state.onScreen = { screens += 1 }
        state.onAction = { _ in actions += 1 }
        state.screenPressed()
        XCTAssertEqual(screens, 0)
        state.arm()
        state.screenPressed()
        XCTAssertEqual(screens, 1)
        XCTAssertEqual(actions, 0)
        state.disarm()
        state.screenPressed()
        XCTAssertEqual(screens, 1)
    }

    func testScreenButtonRefusesFocus() {
        let button = MeetingCoachButton.makeButton(title: "Screen", action: {})
        XCTAssertTrue(button.refusesFirstResponder)
        XCTAssertFalse(button.acceptsFirstResponder)
        XCTAssertFalse(button.needsPanelToBecomeKey)
    }

    func testScreenVisibilityObservesTheSettingWithoutAnUltraGate() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let source = try String(contentsOf: root.appendingPathComponent("Views/MeetingCoach/MeetingCoachView.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("@AppStorage(\"screenContextEnabled\")"))
        XCTAssertTrue(source.contains("if showsScreenButton"))
        XCTAssertTrue(source.contains("MeetingCoachButton(title: \"Screen\", action: state.screenPressed)"))
        XCTAssertFalse(source.contains("UltraFeatures"))
    }

    func testLiveScreenCaptureIsWiredFromTheExistingServiceToTheRequestEntry() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        func source(_ path: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        }
        let app = try source("App/AppDelegate.swift")
        XCTAssertTrue(app.contains("captureScreen: { [weak self] in await self?.screenContext.captureNow(isCancelled: { Task.isCancelled })?.ocrText }"))
        let advisor = try source("Services/Intelligence/LiveMeetingAdvisor.swift")
        XCTAssertTrue(advisor.contains("screenEnabled: { settings.screenContextEnabled }"))
        XCTAssertTrue(advisor.contains("captureScreen: captureScreen"))
        let session = try source("Services/Intelligence/LiveHints/LiveHintsSession.swift")
        XCTAssertTrue(session.contains("screenEnabled: environment.screenEnabled"))
        XCTAssertTrue(session.contains("captureScreen: environment.captureScreen"))
        XCTAssertTrue(session.contains("environment.state.onScreen ="))
        XCTAssertTrue(session.contains("self.answerService?.requestScreen()"))
    }
}
