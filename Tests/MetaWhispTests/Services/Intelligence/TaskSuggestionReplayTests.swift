import SwiftData
import XCTest
@testable import MetaWhisp

/// A live replay, never in the gate (FEAT-0005 §7): the extractor's exact pass — prompt, the Pro server, parser,
/// rules — over conversations of a COPY of a store, as if each were extracted for the first time.
///
/// Runs only with METAWHISP_TASK_REPLAY=1 and:
/// - METAWHISP_REPLAY_STORE — a copy of a store (opened and changed: its task rows are deleted first);
/// - METAWHISP_REPLAY_IDS — a file of `label<TAB>conversation-id` lines;
/// - METAWHISP_REPLAY_OUT — the folder for `replay.jsonl`;
/// - METAWHISP_BENCH_LICENCE — the licence, never printed or written.
@MainActor
final class TaskSuggestionReplayTests: XCTestCase {

    func testReplayConversationsThroughTheProServer() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["METAWHISP_TASK_REPLAY"] == "1",
              let storePath = env["METAWHISP_REPLAY_STORE"], let idsPath = env["METAWHISP_REPLAY_IDS"],
              let out = env["METAWHISP_REPLAY_OUT"],
              let key = env["METAWHISP_BENCH_LICENCE"], !key.isEmpty else {
            throw XCTSkip("live replay: METAWHISP_TASK_REPLAY=1, a store copy, an id list and a licence")
        }
        // The replay deletes the copy's task rows: never a store an app uses (compared as files, not path strings,
        // so another spelling or a hard link of the same file is refused too).
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        func fileID(_ url: URL) -> NSObject? {
            (try? url.resourceValues(forKeys: [.fileResourceIdentifierKey]))?.fileResourceIdentifier as? NSObject
        }
        let target = fileID(URL(fileURLWithPath: storePath))
        let appStores = (try? FileManager.default.contentsOfDirectory(at: support, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "store" }.compactMap(fileID) ?? []
        guard let target, !appStores.contains(target) else {
            return XCTFail("point METAWHISP_REPLAY_STORE at a copy, not at an app's store")
        }
        let schema = Schema(versionedSchema: MetaWhispSchemaV10.self)
        let container = try ModelContainer(for: schema,
                                           configurations: [ModelConfiguration(schema: schema, url: URL(fileURLWithPath: storePath))])
        // First time for every conversation: no earlier task or draft absorbs anything.
        let wipe = ModelContext(container)
        try wipe.delete(model: TaskItem.self)
        try wipe.save()

        let lines = try String(contentsOfFile: idsPath, encoding: .utf8).split(separator: "\n")
        var rows: [String] = []
        let extractor = TaskExtractor()
        let iso = ISO8601DateFormatter()
        for line in lines {
            let cols = line.split(separator: "\t").map(String.init)
            guard cols.count == 2, let id = UUID(uuidString: cols[1]) else { continue }
            let ctx = ModelContext(container)
            let parts = StructuredGenerator.fetchHistoryItems(conversationId: id, in: ctx)
            let now = (parts.last.map { $0.recordedUntil ?? $0.createdAt } ?? Date()).addingTimeInterval(600)
            var record: [String: Any] = ["label": cols[0], "conversation": cols[1]]
            do {
                let pass = try await extractor.suggest(conversationId: id, in: ctx, route: .pro(licenseKey: key),
                                                       now: now) { system, user in
                    try await extractor.callProProxy(system: system, user: user, licenseKey: key)
                }
                switch pass {
                case .nothingToSend:
                    record["result"] = "nothingToSend"
                case .unparseable(let response):
                    record["result"] = "unparseable"
                    record["response"] = String(response.prefix(2_000))
                case .done(let run):
                    record["result"] = "done"
                    record["source"] = run.source == .call ? "call" : "dictation"
                    record["promptChars"] = run.prompt.count
                    record["response"] = String(run.response.prefix(20_000))
                    record["kept"] = run.outcome.kept.map { k -> [String: Any] in
                        ["description": k.candidate.description, "kind": k.kind.rawValue,
                         "assignee": k.candidate.assignee ?? NSNull(),
                         "due": k.candidate.dueAt.map { iso.string(from: $0) } ?? NSNull(),
                         "evidence": k.candidate.evidence ?? NSNull()]
                    }
                    record["dropped"] = run.outcome.dropped.map { d -> [String: Any] in
                        ["description": d.candidate.description, "kind": d.candidate.kind ?? NSNull(),
                         "reason": d.reason.rawValue, "assignee": d.candidate.assignee ?? NSNull(),
                         "evidence": d.candidate.evidence ?? NSNull(),
                         "capture": d.candidate.captureConfidence ?? NSNull(),
                         "ownership": d.candidate.ownershipConfidence ?? NSNull(),
                         "concrete": d.candidate.concreteDeliverable ?? NSNull(),
                         "realWorld": d.candidate.realWorld ?? NSNull()]
                    }
                }
            } catch {
                record["result"] = "error"
                record["error"] = error.localizedDescription
            }
            let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
            rows.append(String(decoding: data, as: UTF8.self))
            try rows.joined(separator: "\n").write(toFile: out + "/replay.jsonl", atomically: true, encoding: .utf8)
        }
    }
}
