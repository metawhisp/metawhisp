import AppKit
import Combine
import XCTest
@testable import MetaWhisp

/// ITER-076 stage 8b — the disclosure before the first errand (8.2, № 151) and Settings → Agent (8.3, 8.7, № 153):
/// the words the owner approved on 2026-10-06, byte for byte (`research/batch-8b.json`, 8b-01…33); one panel, centred,
/// on every Space, that never takes the keyboard and has no default button — Return or Space never Allows — and that
/// shows MetaWhisp's own window's line only in that way.
@MainActor
final class AgentDisclosureTests: XCTestCase {

    // MARK: - The words

    func testTheDisclosureSaysTheApprovedWords() {
        XCTAssertEqual(AgentDisclosure.header, "Before the first errand")                           // 8b-01
        XCTAssertEqual(AgentDisclosure.title, "What the agent sends and where")                     // 8b-02
        XCTAssertEqual(AgentDisclosure.ownWindow, "Errands run in MetaWhisp's own Chrome window, so the agent never sees your browser's tabs, history or sign-ins. When a site asks you to sign in, you do it there.")  // 8b-32
        XCTAssertEqual(AgentDisclosure.rows.map(\.title), [
            "To Jev, through MetaWhisp's Pro server",                                               // 8b-03
            "To an AI model, through MetaWhisp's Pro server",                                       // 8b-05
            "Never leaves your Mac",                                                                // 8b-07
            "To MetaWhisp, when an errand fails or gets stuck",                                     // 8b-09
        ])
        XCTAssertEqual(AgentDisclosure.rows.map(\.body), [
            "Your request and the page: its address, text, controls and the values of ordinary fields. Jev decides every step.",  // 8b-04
            "Your request and the pages: their address, text and the values of ordinary fields. It plans the errand, writes what to type, reads the pages and checks the result.",  // 8b-06
            "The values of password, one-time code and card fields.",                               // 8b-08
            "A report of the failure, in kinds and numbers only. Never your request, page text or what was typed.",  // 8b-10
        ])
        XCTAssertEqual([AgentDisclosure.allow, AgentDisclosure.notNow], ["Allow", "Not now"])      // 8b-11
        XCTAssertEqual(AgentDisclosure.footer, "You can turn the agent off any time in Settings → Agent.")  // 8b-12
    }

    func testSettingsAgentSaysTheApprovedWords() {
        XCTAssertEqual(AgentSetup.tab, "Agent")                                                     // 8b-23
        XCTAssertEqual(MainSettingsView.SettingsTab.allCases.map(\.rawValue),
                       ["General", "Dictation", "Meetings", "Second Brain", "Integrations", "Agent"], "a 6th tab (8.3)")
        XCTAssertEqual(AgentSetup.browserAgent, "Browser agent")                                   // 8b-24
        XCTAssertEqual(AgentSetup.needsPro, "The browser agent needs Pro.")                        // 8b-25
        XCTAssertEqual(AgentSetup.example, "• Find 10 jokes online")                               // 8b-26
        XCTAssertEqual(AgentSetup.useYourOwnChrome, "Use your own Chrome")                         // 8b-33
        XCTAssertEqual(AgentSetup.oneTimeSetup, "A one-time setup in Chrome. MetaWhisp never clicks Allow for you.")  // 8b-17
        XCTAssertEqual([AgentSetup.openAddress, AgentSetup.address, AgentSetup.copyAddress],
                       ["Open this address in Chrome", "chrome://inspect/#remote-debugging", "Copy address"])  // 8b-18
        XCTAssertEqual(AgentSetup.tick, "Tick “Allow remote debugging for this browser instance”.")  // 8b-19
        XCTAssertEqual(AgentSetup.clickAllow, "Click Allow when Chrome asks.")                     // 8b-20
    }

    /// Copy address writes the address to the clipboard on the click alone (A4): a pasteboard of the test's own.
    func testCopyAddressWritesTheAddressOnTheClickAlone() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("mw-agent-setup-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("the user's own", forType: .string)
        _ = AgentSetup.address
        XCTAssertEqual(pasteboard.string(forType: .string), "the user's own", "nothing but the click writes")
        AgentSetup.copyAddress(to: pasteboard)
        XCTAssertEqual(pasteboard.string(forType: .string), "chrome://inspect/#remote-debugging")
    }

    // MARK: - The panel

    func testThePanelShowsWhileAnErrandWaitsNeverTakesTheKeyboardAndHasNoDefaultButton() throws {
        let disclosure = PassthroughSubject<AgentBrowser?, Never>()
        var said: [String] = []
        let controller = AgentDisclosureController(disclosure: disclosure.eraseToAnyPublisher(),
                                                   allow: { said.append("allow") }, notNow: { said.append("not now") })
        XCTAssertNil(controller.panel, "nothing until an errand waits")

        disclosure.send(.ownWindow)
        let panel = try XCTUnwrap(controller.panel)
        defer { disclosure.send(nil) }
        XCTAssertTrue(panel.isVisible)
        XCTAssertEqual(panel.collectionBehavior, MWWindowBehavior.overlay, "on every Space, a full-screen one included")
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel), "a click does not activate MetaWhisp")
        XCTAssertFalse(panel.canBecomeKey, "the user's window keeps the keyboard")
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertNil(panel.defaultButtonCell, "no default button")
        let view = try XCTUnwrap(controller.view)
        XCTAssertEqual(view.allowButton.keyEquivalent, "", "Return never Allows")
        XCTAssertEqual(view.notNowButton.keyEquivalent, "")
        XCTAssertTrue(view.allowButton.refusesFirstResponder, "Space never presses it")
        XCTAssertTrue(view.notNowButton.refusesFirstResponder)
        XCTAssertEqual(view.shownLines, ["BEFORE THE FIRST ERRAND", AgentDisclosure.title, AgentDisclosure.ownWindow]
                       + AgentDisclosure.rows.flatMap { [$0.title, $0.body] }
                       + [AgentDisclosure.allow, AgentDisclosure.notNow, AgentDisclosure.footer])
        if let screen = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame {
            XCTAssertEqual(panel.frame.midX, screen.midX, accuracy: 1, "centred on the active screen")
            XCTAssertEqual(panel.frame.midY, screen.midY, accuracy: 1)
        }

        view.allowButton.performClick(nil)
        view.notNowButton.performClick(nil)
        XCTAssertEqual(said, ["allow", "not now"], "each answer goes to the errand service")
        XCTAssertFalse(panel.isKeyWindow)

        disclosure.send(nil)
        XCTAssertFalse(panel.isVisible, "the service closed it")

        // The user's own Chrome: no line about MetaWhisp's window.
        disclosure.send(.usersChrome)
        let users = try XCTUnwrap(controller.view)
        XCTAssertFalse(users.shownLines.contains(AgentDisclosure.ownWindow))
        XCTAssertEqual(users.shownLines.count, 2 + 8 + 3)
    }
}
