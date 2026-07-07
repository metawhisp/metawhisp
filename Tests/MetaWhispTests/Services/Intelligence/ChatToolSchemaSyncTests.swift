import SwiftData
import XCTest
@testable import MetaWhisp

/// ITER-051 F1.10 — guard: every tool advertised to the LLM via
/// `ChatToolExecutor.toolSchemas` must actually be HANDLED — either as a
/// read-only auto-exec tool or by `validate()`'s mutation switch. The
/// search tools were advertised but fell into `.unknownTool` on the text
/// transport («I tried to do that but: Unknown tool»); this pins the
/// contract so schema/handler drift fails the build.
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
        for schema in ChatToolExecutor.toolSchemas {
            guard let fn = schema["function"] as? [String: Any],
                  let name = fn["name"] as? String else {
                XCTFail("schema without function.name"); continue
            }
            if ChatToolExecutor.isReadOnly(name) { continue }

            let call = ChatToolExecutor.ToolCall(id: nil, tool: name, args: dummyArgs(for: schema))
            if case .failure(let err) = executor.validate(call),
               case .unknownTool = err {
                XCTFail("tool '\(name)' is advertised in toolSchemas but validate() doesn't know it")
            }
        }
    }

    func testReadOnlySetMatchesSchemas() {
        let schemaNames = Set(ChatToolExecutor.toolSchemas.compactMap {
            ($0["function"] as? [String: Any])?["name"] as? String
        })
        for tool in ChatToolExecutor.readOnlyTools {
            XCTAssertTrue(schemaNames.contains(tool),
                          "read-only tool '\(tool)' is executable but not advertised in toolSchemas")
        }
    }
}
