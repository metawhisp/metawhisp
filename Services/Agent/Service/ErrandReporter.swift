import Foundation

/// A failed errand reaches the owner (ITER-076 I-06b). When an errand ends
/// failed, unavailable or stuck, `AgentService` hands its saved record here,
/// and one report of it goes to the Pro server's `POST /api/pro/errand-report`
/// through the agent's Pro client (`ProLLMClient.report`).
///
/// A report holds what the record holds by kinds and numbers alone: the
/// errand's id, its ending and failure, how many older events the record
/// dropped, the app's version, and each event's kind and fields. It never
/// holds the goal, a row, the Sheet, a hand-over's host, a target's
/// fingerprint (a hash of its name, link and context), a page's words or what
/// was typed — the record keeps none of the last two, and the rest are left
/// out here. Every text is one of its field's `values`, every number in its
/// type's bounds — the wire contract the Pro server holds too — and one that
/// is not is left out of its event (Codex review of I-06b, P1-1).
///
/// Every report is kept on disk first, then sent: one that cannot go now waits
/// — the file owner-only (0600, its folder 0700), at most `maxWaiting`, none
/// older than `maxAge` — and goes with the next report or the next errand's
/// start. Without Pro nothing is sent: the client asks nothing of the server
/// without a Pro license. A report the server refuses as it is (400, 413)
/// would fail again, and is let go.
@MainActor
final class ErrandReporter {
    /// One report waiting to go: its errand, when it was kept, and its body as it will be sent.
    struct Waiting: Codable, Equatable {
        let errandID: UUID
        let queuedAt: Date
        let body: Data
    }

    static let maxWaiting = 20
    /// Seven days, in seconds.
    static let maxAge: TimeInterval = 7 * 86_400
    /// Each number type's bounds, as the server takes them (`ERRAND_NUMBER_TYPES`).
    private static let bounds: [String: ClosedRange<Double>] = [
        "count": 0...1e9, "usd": 0...1e3, "fraction": 0...1, "seconds": 0...1e6,
    ]

    /// The report's wire contract (Codex review of I-06b, P1-1): what each text
    /// field may hold, from the enums the app reports from. The Pro server
    /// holds the same lists (`ERRAND_REPORT_CONTRACT` in the worker's
    /// index.js), and the literal in `ErrandReportTests` pins the two: a value
    /// is added on both sides or the tests fail. "none" is a step without an
    /// action and "other" a role the agent does not act on, as `ErrandRecord`
    /// keeps them.
    static let values: [String: [String]] = [
        "plan_result": ErrandRecord.Event.Plan.allCases.map(\.rawValue),
        "purpose": ProLLMClient.Request.Purpose.allCases.map(\.rawValue),
        "operation": AgentOperation.allCases.map(\.rawValue) + ["none"],
        "role": CandidateBuilder.actionableRoles.sorted() + ["other"],
        "outcome": ErrandRecord.Outcome.allCases.map(\.rawValue),
        "engine": [JevDecisionEngine.engineName],
        "page_miss": ErrandRecord.Event.PageMiss.allCases.map(\.rawValue),
        "reply": ErrandRecord.Event.Answer.allCases.map(\.rawValue),
        "handover": ErrandHandover.Kind.allCases.map(\.rawValue),
        "ending": ErrandRecord.Ending.allCases.map(\.rawValue),
        "failure": ErrandRecord.Failure.allCases.map(\.rawValue),
        "not_run": ErrandOutcome.NotRun.allCases.map(\.rawValue),
        "reported_ending": AgentService.reportedEndings.map(\.rawValue).sorted(),
        "dialog": PageDialog.allCases.map(\.rawValue),
    ]

    /// Writes the queue — `nil` removes its file — and throws when it could not. Tests make it fail.
    typealias Persist = (_ queue: Data?, _ file: URL) throws -> Void
    static let onDisk: Persist = { data, file in
        if let data {
            try data.write(to: file, options: .atomic)
        } else if FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
        }
    }

    private let client: ProLLMClient
    private let persist: Persist
    private let file: URL
    private let appVersion: String
    private let now: () -> Date
    /// The flush that runs, if one does: every call waits on it.
    private var flush: Task<Void, Never>?
    private var again = false

    /// `directory`: for tests; `Agent/Reports` in the app's support folder
    /// otherwise. `appVersion`: the app's own unless a test says.
    init(client: ProLLMClient = ProLLMClient(), directory: URL? = nil,
         appVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0",
         now: @escaping () -> Date = Date.init, persist: @escaping Persist = ErrandReporter.onDisk) {
        self.client = client
        self.persist = persist
        file = (directory ?? AppIdentity.current.supportDirectory
            .appendingPathComponent("Agent/Reports", isDirectory: true))
            .appendingPathComponent("queue.json")
        self.appVersion = appVersion
        self.now = now
    }

    /// What waits, oldest first: at most `maxWaiting`, none older than `maxAge`.
    var waiting: [Waiting] { fresh(stored) }

    /// The queue as the file holds it.
    private var stored: [Waiting] {
        guard let data = try? Data(contentsOf: file),
              let kept = try? JSONDecoder().decode([Waiting].self, from: data) else { return [] }
        return kept
    }

    /// Keeps `record`'s report on disk — in place of one of the same errand —
    /// then sends what waits. A record that has not ended has nothing to report.
    func report(_ record: ErrandRecord) {
        guard record.ending != nil,
              let body = try? JSONEncoder().encode(Self.report(of: record, appVersion: appVersion)) else { return }
        keep(waiting.filter { $0.errandID != record.errandID } + [Waiting(errandID: record.errandID, queuedAt: now(), body: body)])
        Task { await sendWaiting() }
    }

    /// Sends what waits, oldest first, until one cannot go now: the rest waits
    /// with it. One round at a time — a call while one runs makes it go round
    /// once more — so no report goes twice at once. Every call returns once a
    /// round begun after it has ended, so a caller that awaits it knows what
    /// waited then has gone, or still waits for a reason a round met. The
    /// queue is read again before each report, so one cleared meanwhile is
    /// never sent. Reports past `maxAge` leave the disk first, not only the
    /// list read from it (Codex P2-2). A report sent that the queue cannot let
    /// go of — the disk is full — ends the flush: sent again at once, it would
    /// go again and again (Codex P2-1); it waits for a later flush.
    func sendWaiting() async {
        again = true
        let running = flush ?? Task { await rounds() }
        flush = running
        await running.value
    }

    /// The flush: rounds until no call asked for another since the last one began.
    private func rounds() async {
        defer { flush = nil }
        while again {
            again = false
            let kept = stored
            if waiting != kept, !keep(kept) { return }
            while let report = waiting.first {
                let delivery = await client.report(report.body)
                if delivery == .later { break }
                guard keep(waiting.filter { $0.errandID != report.errandID }) else { return }
            }
        }
    }

    /// Lets every waiting report go, and its file with it: MetaChat's history
    /// is cleared, and nothing of the agent stays on disk (owner decision,
    /// I-03). `AgentService.deleteAllRecords` is the one caller.
    func clearWaiting() {
        try? persist(nil, file)
    }

    /// The report of `record`, as the server takes it.
    static func report(of record: ErrandRecord, appVersion: String) -> CDPValue {
        .object([
            "errand_id": .string(record.errandID.uuidString),
            "ending": record.ending.map { .string($0.rawValue) } ?? .null,
            "failure_kind": record.failure.map { .string($0.rawValue) } ?? .null,
            "events": .array(record.events.compactMap(fields(of:))),
            "dropped_events": .number(Double(record.droppedEvents)),
            "app_version": .string(appVersion),
        ])
    }

    /// An event as a report carries it: its kind, then its fields — each text
    /// one of its list's `values`, each number in its type's bounds, or left
    /// out. A hand-over's host and a step's fingerprint stay on the Mac; so do
    /// a read's event and Jev's own numbers on a step (ITER-076 stage 4a)
    /// until the server's contract holds them: it refuses a report with a
    /// kind or a field it does not know, whole. Nil: not reported.
    static func fields(of event: ErrandRecord.Event) -> CDPValue? {
        var out: [String: CDPValue] = [:]
        func listed(_ name: String, _ value: String?, in list: String) {
            if let value, values[list]?.contains(value) == true { out[name] = .string(value) }
        }
        func number(_ name: String, _ value: Double?, _ type: String) {
            if let value, value.isFinite, bounds[type]?.contains(value) == true { out[name] = .number(value) }
        }
        switch event {
        case .plan(let result, let milliseconds, let cost):
            out["kind"] = .string("plan")
            listed("result", result.rawValue, in: "plan_result")
            number("ms", Double(milliseconds), "count")
            number("usd", cost, "usd")
        case .step(let step):
            out["kind"] = .string("step")
            listed("op", step.operation, in: "operation")
            listed("role", step.targetRole, in: "role")
            listed("outcome", step.outcome.rawValue, in: "outcome")
            number("confidence", step.confidence, "fraction")
            listed("engine", step.engine, in: "engine")
            number("ms", Double(step.milliseconds), "count")
            number("usd", step.costUSD, "usd")
        case .pageMiss(let miss):
            out["kind"] = .string("page")
            listed("miss", miss.rawValue, in: "page_miss")
        case .serviceWait(let seconds, let answered):
            out["kind"] = .string("wait")
            number("s", seconds, "seconds")
            out["answered"] = answered.map(CDPValue.bool) ?? .null
        case .question(let operation, let role):
            out["kind"] = .string("question")
            listed("op", operation, in: "operation")
            listed("role", role, in: "role")
        case .answer(let reply):
            out["kind"] = .string("answer")
            listed("reply", reply.rawValue, in: "reply")
        case .handover(let handover, _):
            out["kind"] = .string("handover")
            listed("handover", handover.rawValue, in: "handover")
        case .continued:
            out["kind"] = .string("continued")
        case .ending(let ending, let failure, let notRun, let rows):
            out["kind"] = .string("ending")
            listed("ending", ending.rawValue, in: "ending")
            listed("failure", failure?.rawValue, in: "failure")
            listed("not_run", notRun?.rawValue, in: "not_run")
            number("rows", Double(rows), "count")
        case .model(let purpose, let result, let milliseconds, let cost):
            out["kind"] = .string("model")
            listed("purpose", purpose.rawValue, in: "purpose")
            listed("result", result.rawValue, in: "plan_result")
            number("ms", Double(milliseconds), "count")
            number("usd", cost, "usd")
        case .takenBack:
            out["kind"] = .string("taken_back")
        case .dialog(let kind, let accepted):
            out["kind"] = .string("dialog")
            listed("dialog", kind.rawValue, in: "dialog")
            out["accepted"] = .bool(accepted)
        case .downloadRefused:
            out["kind"] = .string("download_refused")
        case .addressRefused:
            out["kind"] = .string("address_refused")
        case .read:
            return nil
        }
        return .object(out)
    }

    /// The newest `maxWaiting` of `kept` that are not past `maxAge`.
    private func fresh(_ kept: [Waiting]) -> [Waiting] {
        let cutoff = now().addingTimeInterval(-Self.maxAge)
        return Array(kept.filter { $0.queuedAt >= cutoff }.suffix(Self.maxWaiting))
    }

    /// Writes what waits, owner-only, and removes the file when nothing does.
    /// False when that could not be done — logged by its error code — so a
    /// caller that lets a report go knows it is still on disk.
    @discardableResult
    private func keep(_ reports: [Waiting]) -> Bool {
        let folder = file.deletingLastPathComponent()
        let left = fresh(reports)
        do {
            guard !left.isEmpty else {
                try persist(nil, file)
                return true
            }
            let fm = FileManager.default
            if !fm.fileExists(atPath: folder.path) {
                try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            } else {
                try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
            }
            try persist(JSONEncoder().encode(left), file)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            return true
        } catch {
            NSLog("[ErrandReporter] reports not kept — error %d", (error as NSError).code)
            return false
        }
    }
}
