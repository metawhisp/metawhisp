import SwiftData
import XCTest
@testable import MetaWhisp

/// ITER-076 B1 — every finished errand is kept: its record and its outcome, in
/// a JSON file of its own. A file that cannot be written is reported, never
/// thrown at the errand. B2c (Codex round 2, P1-3): the folder and the files
/// are owner-only, capped at 100 and 30 days, and `deleteAll()` clears every
/// one so `ChatService.clearHistory` empties the user's disk.
@MainActor
final class ErrandRecordStoreTests: XCTestCase {

    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("mw-errand-records-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func record(rows: Int) -> ErrandRecord {
        var record = ErrandRecord(errandID: UUID(), goal: "Collect three sites into a sheet")
        record.append(AgentAction(operation: .scroll, target: nil, destination: nil, payload: nil, isPlannedSearch: false),
                      outcome: .acted, confidence: 0.9, engine: "scripted", milliseconds: 12, costUSD: nil)
        record.rows = (1...rows).map { Scratchpad.Row(cells: ["Site \($0)"], source: URL(string: "https://site-\($0).test/")!) }
        record.ending = .done
        return record
    }

    private func permissions(at url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? Int
    }

    func testAFinishedErrandIsSavedWholeInAFileOfItsOwn() throws {
        let store = ErrandRecordStore(directory: folder)
        let origin = ErrandOrigin.chat(messageID: UUID())
        let first = record(rows: 2)
        let outcome = ErrandOutcome(ending: .done, answer: nil, sources: first.rows.map(\.source), sheet: nil, rows: 2)
        XCTAssertTrue(store.save(id: first.errandID, origin: origin, record: first, outcome: outcome))
        let second = record(rows: 1)
        XCTAssertTrue(store.save(id: second.errandID, origin: .voice(questionID: UUID()), record: second,
                                 outcome: ErrandOutcome(ending: .done, answer: nil, sources: [], sheet: nil, rows: 1)))

        let file = store.fileURL(for: first.errandID)
        XCTAssertEqual(file, folder.appendingPathComponent("\(first.errandID.uuidString).json"))
        let saved = try JSONDecoder().decode(ErrandRecordStore.Saved.self, from: Data(contentsOf: file))
        XCTAssertEqual(saved, ErrandRecordStore.Saved(version: 1, origin: origin, record: first, outcome: outcome))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).count, 2, "one file per errand")
    }

    func testAFileThatCannotBeWrittenIsReportedNotThrown() throws {
        // A plain file where the folder should be: nothing can be written under it.
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let blocked = folder.appendingPathComponent("not-a-folder")
        try Data("x".utf8).write(to: blocked)
        let store = ErrandRecordStore(directory: blocked)
        let errand = record(rows: 1)
        XCTAssertFalse(store.save(id: errand.errandID, origin: .chat(messageID: UUID()), record: errand,
                                  outcome: ErrandOutcome(ending: .done, answer: nil, sources: [], sheet: nil, rows: 1)))
    }

    /// The file is named by the id it is given, whatever the record carries.
    func testARecordIsFiledUnderTheIDItIsGiven() throws {
        let store = ErrandRecordStore(directory: folder)
        let id = UUID()
        let errand = record(rows: 1)
        XCTAssertTrue(store.save(id: id, origin: .chat(messageID: UUID()), record: errand,
                                 outcome: ErrandOutcome(ending: .done, answer: nil, sources: [], sheet: nil, rows: 1)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.fileURL(for: id).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL(for: errand.errandID).path))
    }

    /// ITER-074 §5: one file per errand under the app's own folder, in `Agent/`.
    func testErrandsAreKeptInTheAppsAgentFolder() {
        XCTAssertEqual(ErrandRecordStore().directory,
                       AppIdentity.current.supportDirectory.appendingPathComponent("Agent", isDirectory: true))
    }

    // MARK: - Codex round 2, P1-3: permissions, prune, deleteAll.

    /// Every record lives in an owner-only folder and is itself owner-only —
    /// nothing else on the Mac can read what the user asked MetaChat to do.
    func testSaveMakesTheFolderAndFilesOwnerOnly() throws {
        let store = ErrandRecordStore(directory: folder)
        let errand = record(rows: 1)
        XCTAssertTrue(store.save(id: errand.errandID, origin: .chat(messageID: UUID()), record: errand,
                                 outcome: ErrandOutcome(ending: .done, answer: nil, sources: [], sheet: nil, rows: 1)))
        XCTAssertEqual(permissions(at: folder), 0o700, "Agent folder owner-only (rwx------)")
        XCTAssertEqual(permissions(at: store.fileURL(for: errand.errandID)), 0o600, "record file owner-only (rw-------)")
    }

    /// Even a folder that already exists has its permissions re-asserted on
    /// every save — a pre-existing/beta/user-created directory may have been
    /// chmod 0755 in the past.
    func testSaveReassertsOwnerOnlyPermissionsOnAPreExistingFolder() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
        let store = ErrandRecordStore(directory: folder)
        let errand = record(rows: 1)
        XCTAssertTrue(store.save(id: errand.errandID, origin: .chat(messageID: UUID()), record: errand,
                                 outcome: ErrandOutcome(ending: .done, answer: nil, sources: [], sheet: nil, rows: 1)))
        XCTAssertEqual(permissions(at: folder), 0o700, "Agent folder permissions re-applied")
    }

    /// At most `ErrandRecordStore.maxRecords` are kept. Saving one more drops
    /// the oldest beyond the cap.
    func testSavePrunesTheOldestBeyondTheCap() throws {
        let store = ErrandRecordStore(directory: folder)
        let limit = ErrandRecordStore.maxRecords
        // Save `limit + 5` records with widely-spaced modification times so
        // the oldest five are unambiguous.
        let base = Date().addingTimeInterval(-Double(limit + 5) * 60)
        for index in 0..<(limit + 5) {
            let errand = record(rows: 1)
            XCTAssertTrue(store.save(id: errand.errandID, origin: .chat(messageID: UUID()), record: errand,
                                     outcome: ErrandOutcome(ending: .done, answer: nil, sources: [],
                                                            sheet: nil, rows: 1)))
            let url = store.fileURL(for: errand.errandID)
            let mtime = base.addingTimeInterval(Double(index) * 60)
            try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
        }
        let remaining = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0.hasSuffix(".json") }
        XCTAssertEqual(remaining.count, limit, "capped at the limit after each save")
    }

    /// A record older than 30 days is deleted on the next save (its
    /// modification date, not the current save).
    func testSavePrunesRecordsOlderThan30Days() throws {
        let store = ErrandRecordStore(directory: folder)
        let oldID = UUID()
        let stale = record(rows: 1)
        XCTAssertTrue(store.save(id: oldID, origin: .chat(messageID: UUID()), record: stale,
                                 outcome: ErrandOutcome(ending: .done, answer: nil, sources: [], sheet: nil, rows: 1)))
        // Backdate it past the 30-day retention window.
        let oldURL = store.fileURL(for: oldID)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-31 * 86_400)],
            ofItemAtPath: oldURL.path)

        let newer = record(rows: 1)
        XCTAssertTrue(store.save(id: newer.errandID, origin: .chat(messageID: UUID()), record: newer,
                                 outcome: ErrandOutcome(ending: .done, answer: nil, sources: [], sheet: nil, rows: 1)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldURL.path),
                       "older than 30 days is removed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.fileURL(for: newer.errandID).path),
                      "the just-saved one is kept")
    }

    /// `deleteAll` removes every record (owner action: clear MetaChat history).
    func testDeleteAllRemovesEveryRecord() throws {
        let store = ErrandRecordStore(directory: folder)
        for _ in 0..<3 {
            let errand = record(rows: 1)
            XCTAssertTrue(store.save(id: errand.errandID, origin: .chat(messageID: UUID()), record: errand,
                                     outcome: ErrandOutcome(ending: .done, answer: nil, sources: [],
                                                            sheet: nil, rows: 1)))
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0.hasSuffix(".json") }.count, 3)

        store.deleteAll()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0.hasSuffix(".json") }.count, 0)
    }

    /// `AgentService` exposes the action that clears every record, so callers
    /// (notably `ChatService.clearHistory`) reach the SAME store the service
    /// writes to — no second store for the app (work order I-03).
    func testAgentServiceExposesADeleteAllRecordsAction() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("mw-agent-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ErrandRecordStore(directory: folder)
        let link = FakeErrandLink()
        let service = AgentService(link: link, keepAwake: KeepAwake(), store: store, settings: .allowedForTests)
        let errand = record(rows: 1)
        XCTAssertTrue(store.save(id: errand.errandID, origin: .chat(messageID: UUID()), record: errand,
                                 outcome: ErrandOutcome(ending: .done, answer: nil, sources: [], sheet: nil, rows: 1)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.fileURL(for: errand.errandID).path))

        service.deleteAllRecords()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0.hasSuffix(".json") }.count, 0,
                       "the service cleared the same store it writes to")
    }

    /// `ChatService.clearHistory` calls the errand store delete too — the
    /// "clear MetaChat history" button leaves no errand files behind. The
    /// default hook reaches `AgentService.shared.deleteAllRecords()`; tests
    /// substitute a counter to verify the call without touching the singleton.
    func testClearMetaChatHistoryAlsoClearsEveryErrandRecord() throws {
        let schema = Schema([
            HistoryItem.self, ScreenContext.self, AdviceItem.self, UserMemory.self,
            TaskItem.self, ChatMessage.self, Conversation.self, ScreenObservation.self,
            IndexedFile.self, DailySummary.self, Goal.self, ProjectAlias.self,
            AuditLog.self, PatternDigest.self,
        ])
        let container = try ModelContainer(for: schema,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let chat = ChatService()
        chat.configure(modelContainer: container)
        var calls = 0
        chat.clearErrandRecords = { calls += 1 }
        chat.clearHistory()
        XCTAssertGreaterThanOrEqual(calls, 1,
            "clearHistory fires the errand-store clear hook")
    }

    /// ITER-076 I-05, review round 2: what was kept of an errand is read
    /// back by its id — nothing for an errand never kept.
    func testAKeptErrandIsReadBackByItsID() throws {
        let store = ErrandRecordStore(directory: folder)
        let id = UUID()
        let origin = ErrandOrigin.chat(messageID: UUID())
        let outcome = ErrandOutcome(ending: .stopped, answer: nil, sources: [], sheet: nil, rows: 2)
        XCTAssertTrue(store.save(id: id, origin: origin, record: record(rows: 2), outcome: outcome))
        let loaded = try XCTUnwrap(store.load(id: id))
        XCTAssertEqual(loaded.origin, origin)
        XCTAssertEqual(loaded.outcome, outcome)
        XCTAssertEqual(loaded.record.rows.count, 2)
        XCTAssertNil(store.load(id: UUID()))
    }
}
