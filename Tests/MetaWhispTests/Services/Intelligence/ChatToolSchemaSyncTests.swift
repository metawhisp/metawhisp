import SwiftData
import XCTest
@testable import MetaWhisp

/// ITER-051 F1.10 — guard: every tool advertised to the LLM via
/// `ChatToolExecutor.toolSchemas` must actually be HANDLED — either as a
/// read-only auto-exec tool or by `validate()`'s mutation switch. The
/// search tools were advertised but fell into `.unknownTool` on the text
/// transport («I tried to do that but: Unknown tool»); this pins the
/// contract so schema/handler drift fails the build. Both offers are pinned:
/// with the browser agent, and without it — the Ultra switch off (U1).
@MainActor
final class ChatToolSchemaSyncTests: XCTestCase {

    private func makeExecutor() throws -> ChatToolExecutor {
        let schema = Schema([
            HistoryItem.self, ScreenContext.self, AdviceItem.self, UserMemory.self,
            TaskItem.self, ChatMessage.self, Conversation.self, ScreenObservation.self,
            IndexedFile.self, DailySummary.self, Goal.self, ProjectAlias.self,
            AuditLog.self, PatternDigest.self,
        ])
        let cfg = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [cfg])
        let executor = ChatToolExecutor()
        executor.configure(modelContainer: container)
        return executor
    }

    /// Plausible dummy args per declared parameter so validate() reaches its
    /// tool-name switch instead of failing on missing keys.
    private func dummyArgs(for schema: [String: Any]) -> [String: String] {
        guard let fn = schema["function"] as? [String: Any],
              let params = fn["parameters"] as? [String: Any],
              let props = params["properties"] as? [String: Any] else { return [:] }
        var args: [String: String] = [:]
        for key in props.keys {
            switch key {
            case "id": args[key] = UUID().uuidString
            case "delta", "limit": args[key] = "1"
            default: args[key] = "test value"
            }
        }
        return args
    }

    func testEveryAdvertisedToolIsHandled() throws {
        let executor = try makeExecutor()
        for canRunErrands in [true, false] {
            for schema in ChatToolExecutor.toolSchemas(canRunErrands: canRunErrands) {
                guard let fn = schema["function"] as? [String: Any],
                      let name = fn["name"] as? String else {
                    XCTFail("schema without function.name"); continue
                }
                // Read-only tools and tools that start at once are run by the
                // chat loops themselves, never through the confirm bubble.
                if ChatToolExecutor.loopStep(for: name) != .needsConfirm { continue }

                let call = ChatToolExecutor.ToolCall(id: nil, tool: name, args: dummyArgs(for: schema))
                if case .failure(let err) = executor.validate(call),
                   case .unknownTool = err {
                    XCTFail("tool '\(name)' is advertised in toolSchemas(canRunErrands: \(canRunErrands)) but validate() doesn't know it")
                }
            }
        }
    }

    /// A tool that starts at once is advertised to the answering loops while
    /// the agent can run, never without it, and never to the follow-up after a
    /// confirm, which would make it a bubble. Without the agent every other tool
    /// is offered as with it.
    func testToolsThatStartAtOnceAreAdvertisedButNeverInTheFollowUp() {
        let names = { (schemas: [[String: Any]]) in
            Set(schemas.compactMap { ($0["function"] as? [String: Any])?["name"] as? String })
        }
        for tool in ChatToolExecutor.startsAtOnceTools {
            XCTAssertTrue(names(ChatToolExecutor.toolSchemas(canRunErrands: true)).contains(tool), tool)
            XCTAssertFalse(names(ChatToolExecutor.toolSchemas(canRunErrands: false)).contains(tool), tool)
            XCTAssertFalse(names(ChatToolExecutor.followUpToolSchemas).contains(tool), tool)
        }
        let withoutTheAgent = names(ChatToolExecutor.toolSchemas(canRunErrands: true))
            .subtracting(ChatToolExecutor.startsAtOnceTools)
        XCTAssertEqual(names(ChatToolExecutor.followUpToolSchemas), withoutTheAgent)
        XCTAssertEqual(names(ChatToolExecutor.toolSchemas(canRunErrands: false)), withoutTheAgent)
    }

    /// Every advertised tool is read in the drift format `<name>{…}</name>`
    /// and stripped from what the user sees — both lists come from the
    /// advertised tools, so a new tool cannot be left out (review of B2). A
    /// tool that starts at once is read only when its envelope is the whole
    /// answer (Codex round 2, P1-1); every other tool also after a sentence.
    func testEveryAdvertisedToolIsReadAndStrippedInTheTagFormat() {
        for canRunErrands in [true, false] {
            for schema in ChatToolExecutor.toolSchemas(canRunErrands: canRunErrands) {
                guard let name = (schema["function"] as? [String: Any])?["name"] as? String else { continue }
                let envelope = "<\(name)>{\"query\":\"x\"}</\(name)>"
                XCTAssertEqual(ChatToolExecutor.parseToolCall(from: envelope)?.tool, name, name)
                XCTAssertEqual(ChatToolExecutor.parseToolCall(from: "```json\n\(envelope)\n```")?.tool, name, name)
                let text = "Sure. \(envelope)"
                let startsAtOnce = ChatToolExecutor.startsAtOnceTools.contains(name)
                XCTAssertEqual(ChatToolExecutor.parseToolCall(from: text)?.tool, startsAtOnce ? nil : name, name)
                XCTAssertEqual(ChatService.stripToolCallXML(text), "Sure.", name)
            }
        }
    }

    func testReadOnlySetMatchesSchemas() {
        for canRunErrands in [true, false] {
            let schemaNames = Set(ChatToolExecutor.toolSchemas(canRunErrands: canRunErrands).compactMap {
                ($0["function"] as? [String: Any])?["name"] as? String
            })
            for tool in ChatToolExecutor.readOnlyTools {
                XCTAssertTrue(schemaNames.contains(tool),
                              "read-only tool '\(tool)' is executable but not advertised in toolSchemas(canRunErrands: \(canRunErrands))")
            }
        }
    }
}
