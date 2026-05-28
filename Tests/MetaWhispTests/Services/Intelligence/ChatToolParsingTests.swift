import XCTest
@testable import MetaWhisp

/// Corner-case coverage for the MetaChat tool-call parsing + empty-response
/// handling. Pure functions, zero tests before 2026-05-28.
///
/// User reported "метачат вообще какая-то хуета" (2026-05-28). Chat history
/// showed empty AI bubbles for "что нового" and "удали все задачи". These
/// tests pin: the empty-response fallback, the XML stripper, and the legacy
/// `<tool_call>` / drift-format parsers.
@MainActor
final class ChatToolParsingTests: XCTestCase {

    // MARK: - emptyResponseFallback (fixes empty-bubble bug)

    func test_emptyFallback_cyrillicInput_returnsRussian() {
        let out = ChatService.emptyResponseFallback(for: "что нового")
        XCTAssertTrue(out.contains("Не уверен"), "Cyrillic input → Russian fallback")
    }

    func test_emptyFallback_latinInput_returnsEnglish() {
        let out = ChatService.emptyResponseFallback(for: "what's up")
        XCTAssertTrue(out.lowercased().contains("not sure"), "Latin input → English fallback")
    }

    func test_emptyFallback_bulkDeleteRequest_returnsNonEmpty() {
        // The exact production case that produced an empty bubble.
        let out = ChatService.emptyResponseFallback(for: "удали все эти старые задачи")
        XCTAssertFalse(out.isEmpty)
        XCTAssertTrue(out.contains("Не уверен"))
    }

    func test_emptyFallback_emptyInput_stillNonEmpty() {
        let out = ChatService.emptyResponseFallback(for: "")
        XCTAssertFalse(out.isEmpty, "Even empty input must yield a non-empty bubble")
    }

    func test_emptyFallback_mixedScript_prefersCyrillic() {
        // "open Slack чат" — has Cyrillic → RU branch.
        let out = ChatService.emptyResponseFallback(for: "open Slack чат")
        XCTAssertTrue(out.contains("Не уверен"))
    }

    // MARK: - stripToolCallXML

    func test_stripXML_canonicalToolCall_removed() {
        let input = "Done.<tool_call>{\"tool\":\"addTask\",\"args\":{}}</tool_call>"
        let out = ChatService.stripToolCallXML(input)
        XCTAssertFalse(out.contains("tool_call"))
        XCTAssertTrue(out.contains("Done."))
    }

    func test_stripXML_driftFormat_removed() {
        let input = "Sure.<addTask>{\"description\":\"x\"}</addTask>"
        let out = ChatService.stripToolCallXML(input)
        XCTAssertFalse(out.contains("addTask"))
        XCTAssertTrue(out.contains("Sure."))
    }

    func test_stripXML_plainText_unchanged() {
        let input = "Just a normal answer with no tools."
        XCTAssertEqual(ChatService.stripToolCallXML(input), input)
    }

    func test_stripXML_emptyString() {
        XCTAssertEqual(ChatService.stripToolCallXML(""), "")
    }

    // MARK: - parseToolCall (legacy regex path)

    func test_parseToolCall_canonical() {
        let text = "<tool_call>{\"tool\":\"addTask\",\"args\":{\"description\":\"Ship release\"}}</tool_call>"
        let call = ChatToolExecutor.parseToolCall(from: text)
        XCTAssertEqual(call?.tool, "addTask")
        XCTAssertEqual(call?.args["description"], "Ship release")
    }

    func test_parseToolCall_driftFormat() {
        let text = "<addTask>{\"description\":\"Fix bug\"}</addTask>"
        let call = ChatToolExecutor.parseToolCall(from: text)
        XCTAssertEqual(call?.tool, "addTask")
        XCTAssertEqual(call?.args["description"], "Fix bug")
    }

    func test_parseToolCall_plainText_returnsNil() {
        XCTAssertNil(ChatToolExecutor.parseToolCall(from: "Just chatting, no tools here."))
    }

    func test_parseToolCall_malformedJSON_returnsNil() {
        let text = "<tool_call>{not valid json}</tool_call>"
        XCTAssertNil(ChatToolExecutor.parseToolCall(from: text))
    }

    func test_parseToolCall_numericArgsCoercedToString() {
        let text = "<tool_call>{\"tool\":\"updateGoalProgress\",\"args\":{\"id\":\"abc\",\"delta\":5}}</tool_call>"
        let call = ChatToolExecutor.parseToolCall(from: text)
        XCTAssertEqual(call?.tool, "updateGoalProgress")
        XCTAssertEqual(call?.args["delta"], "5", "numeric arg coerced to string")
    }

    func test_parseToolCall_codeFencesStripped() {
        let text = "<tool_call>```json\n{\"tool\":\"addMemory\",\"args\":{\"content\":\"x\"}}\n```</tool_call>"
        let call = ChatToolExecutor.parseToolCall(from: text)
        XCTAssertEqual(call?.tool, "addMemory")
    }

    // MARK: - parseNativeToolCall (Groq function-calling path)

    func test_parseNativeToolCall_valid() {
        let toolCalls: [[String: Any]] = [[
            "id": "call_123",
            "type": "function",
            "function": [
                "name": "completeTask",
                "arguments": "{\"id\":\"deadbeef\"}",
            ],
        ]]
        let call = ChatToolExecutor.parseNativeToolCall(from: toolCalls)
        XCTAssertEqual(call?.tool, "completeTask")
        XCTAssertEqual(call?.id, "call_123")
        XCTAssertEqual(call?.args["id"], "deadbeef")
    }

    func test_parseNativeToolCall_nilInput_returnsNil() {
        XCTAssertNil(ChatToolExecutor.parseNativeToolCall(from: nil))
    }

    func test_parseNativeToolCall_emptyArray_returnsNil() {
        XCTAssertNil(ChatToolExecutor.parseNativeToolCall(from: []))
    }
}
