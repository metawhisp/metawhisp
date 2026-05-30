import XCTest
@testable import MetaWhisp

/// ITER-042 (cheap hypothesis) — MetaChat mixed people across companies and
/// invented relationships ("X added Y") even though it already receives each
/// screen snippet's app + window title. The fix under test here is a HARD rule
/// in `ChatService.systemPrompt`: bind people to the window-title workspace,
/// never merge across workspaces, never invent names/links, the user is not a
/// colleague. These tests pin that the rule text is actually present.
@MainActor
final class ChatServicePeopleRulesTests: XCTestCase {

    func test_systemPrompt_anchorsPeopleToWindowTitleWorkspace() {
        let p = ChatService.systemPrompt.lowercased()
        XCTAssertTrue(p.contains("workspace"), "must introduce the workspace concept")
        XCTAssertTrue(p.contains("window title"), "window title is the workspace anchor")
    }

    func test_systemPrompt_forbidsCrossWorkspaceMerge() {
        let p = ChatService.systemPrompt.lowercased()
        // never merge people from different workspaces into one group
        XCTAssertTrue(p.contains("different workspace"))
        XCTAssertTrue(p.contains("never merge") || p.contains("do not merge")
                   || p.contains("never combine") || p.contains("do not combine"))
    }

    func test_systemPrompt_forbidsInventingPeopleLinks() {
        let p = ChatService.systemPrompt.lowercased()
        XCTAssertTrue(p.contains("never invent"))
        XCTAssertTrue(p.contains("between two people") || p.contains("relationship"))
    }

    func test_systemPrompt_unclearCompanyStaysUnclear() {
        let p = ChatService.systemPrompt.lowercased()
        XCTAssertTrue(p.contains("company unclear") || p.contains("workspace is not clear")
                   || p.contains("not clear from the window"))
    }

    func test_systemPrompt_userIsNotAColleague() {
        let p = ChatService.systemPrompt.lowercased()
        XCTAssertTrue(p.contains("not a colleague") || p.contains("not an employee"))
    }
}
