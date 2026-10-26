import XCTest
@testable import MetaWhisp

/// ITER-076 I-06b — a failed errand reaches the owner: when an errand ends failed, unavailable or stuck, the
/// service sends one report of it, built from its saved record, through the agent's Pro client to
/// `POST /api/pro/errand-report`. The report is kinds and numbers: never the goal, a hand-over's host, a page's
/// words, a label, what was typed, a row, a Sheet or a target's fingerprint. A report that cannot go waits on
/// disk — owner-only, at most 20, at most 7 days — and goes with the next report or the next errand's start.
/// Without Pro nothing is sent.
@MainActor
final class ErrandReportTests: XCTestCase {
    // What the user typed, read or visited: none of it may leave the Mac in a report.
    private let goal = "Book a table at Chez Sam for Friday"
    private let host = "private-bank.example"
    private let label = "Private draft for Sam"
    private let typed = "hunter2-typed-value"
    private let sheet = URL(string: "https://docs.google.com/spreadsheets/d/SHEET-ID-777")!

    /// The server as the test runs it: what was sent, and how it answers. The client calls it from its own tasks.
    private final class Wire: @unchecked Sendable {
        private let lock = NSLock()
        private var sent: [URLRequest] = []
        private var answer = 200
        private var down = false
        private var hasPro = true
        private var lagging = false

        var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return sent }
        var status: Int {
            get { lock.lock(); defer { lock.unlock() }; return answer }
            set { lock.lock(); answer = newValue; lock.unlock() }
        }
        /// No network: every request throws.
        var offline: Bool {
            get { lock.lock(); defer { lock.unlock() }; return down }
            set { lock.lock(); down = newValue; lock.unlock() }
        }
        var pro: Bool {
            get { lock.lock(); defer { lock.unlock() }; return hasPro }
            set { lock.lock(); hasPro = newValue; lock.unlock() }
        }
        /// Every answer takes a while: a request stays in flight.
        var slow: Bool {
            get { lock.lock(); defer { lock.unlock() }; return lagging }
            set { lock.lock(); lagging = newValue; lock.unlock() }
        }
        /// The license as the client reads it: a Pro user's, or none.
        var license: String? { pro ? "LICENSE-1" : nil }

        private var holding = false
        private var held: [CheckedContinuation<Void, Never>] = []
        /// Every request stays in flight until `release()`.
        func hold() { lock.lock(); holding = true; lock.unlock() }
        func release() {
            lock.lock()
            let waiting = held
            held = []
            holding = false
            lock.unlock()
            waiting.forEach { $0.resume() }
        }

        func respond(_ request: URLRequest) async throws -> (Data, URLResponse) {
            lock.lock()
            sent.append(request)
            let (status, offline, slow, holds) = (answer, down, lagging, holding)
            lock.unlock()
            if holds {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    lock.lock()
                    if holding {
                        held.append(continuation)
                        lock.unlock()
                    } else {
                        lock.unlock()
                        continuation.resume()
                    }
                }
            }
            if slow { try await Task.sleep(for: .milliseconds(150)) }
            if offline { throw URLError(.notConnectedToInternet) }
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (Data(#"{"ok":true}"#.utf8), response)
        }
    }

    /// A switch a test flips while the reporter runs.
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var on: Bool {
            get { lock.lock(); defer { lock.unlock() }; return value }
            set { lock.lock(); value = newValue; lock.unlock() }
        }
    }

    private func reporter(_ wire: Wire, folder: URL, now: @escaping () -> Date = Date.init) -> ErrandReporter {
        ErrandReporter(client: ProLLMClient(licenseKey: { wire.license }, send: { try await wire.respond($0) }, log: { _ in }),
                       directory: folder, appVersion: "1.3.37", now: now)
    }

    private func body(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
    }

    private func text(_ request: URLRequest) -> String {
        String(decoding: request.httpBody ?? Data(), as: UTF8.self)
    }

    private func element(_ role: String) -> ObservedElement {
        ObservedElement(index: 3, role: role, name: label, text: label, href: "https://\(host)/account", inputType: "text",
                        heading: label, region: .main, inViewport: true, context: label, formAction: "https://\(host)/pay",
                        formMethod: "post", formSubmitLabel: label, options: [label], checked: nil)
    }

    /// A run's record as I-06a keeps it: a plan, a typed value, a question and its answer, a page miss, a
    /// hand-over on a host, an unanswered wait, two rows and a Sheet.
    private func live(_ run: FakeErrandRunner) {
        run.record.note(.plan(.ok, milliseconds: 12, costUSD: 0.02))
        run.record.append(AgentAction(operation: .type, target: element("textbox"), destination: nil, payload: typed,
                                      isPlannedSearch: false),
                          outcome: .acted, confidence: 0.91, engine: "jev", milliseconds: 120, costUSD: 0.002)
        run.record.note(.question(about: AgentAction(operation: .click, target: element("button"), destination: nil,
                                                     payload: nil, isPlannedSearch: false)))
        run.record.note(.answer(.yes))
        run.record.note(.pageMiss(.settle))
        run.record.note(.handover(.signIn, host: host))
        run.record.note(.serviceWait(seconds: 2, answered: nil))
        run.collect(2)
        run.record.sheet = sheet
    }

    /// The events `live` notes, and the ending the service adds, as the report carries them.
    private let liveEvents: [[String: Any]] = [
        ["kind": "plan", "result": "ok", "ms": 12, "usd": 0.02],
        ["kind": "step", "op": "type", "role": "textbox", "outcome": "acted", "confidence": 0.91, "engine": "jev",
         "ms": 120, "usd": 0.002],
        ["kind": "question", "op": "click", "role": "button"],
        ["kind": "answer", "reply": "yes"],
        ["kind": "page", "miss": "settle"],
        ["kind": "handover", "handover": "signIn"],
        ["kind": "wait", "s": 2, "answered": NSNull()],
        ["kind": "ending", "ending": "failed", "failure": "bridgeLost", "rows": 2],
    ]

    private func failed(_ rows: Int = 2) -> ErrandOutcome {
        ErrandOutcome(ending: .failed, answer: nil, sources: [], sheet: nil, rows: rows, failure: .bridgeLost)
    }

    /// Ends one errand of `service` as `outcome`, after `live` when asked.
    private func runOne(_ h: AgentServiceHarness, _ service: AgentService, _ outcome: ErrandOutcome,
                        live noting: Bool = false) async throws -> UUID {
        let id = try XCTUnwrap(service.start(goal: goal, origin: .chat(messageID: UUID())).id)
        let found = await h.runner(for: id)
        let run = try XCTUnwrap(found)
        if noting { live(run) }
        run.finish(outcome)
        await h.until({ !service.errandRunning }, "the errand's end")
        return id
    }

    // MARK: - One report per failed errand, from its saved record

    func testAFailedErrandIsReportedOnceFromItsSavedRecordThroughTheProClient() async throws {
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        let wire = Wire()
        h.link.connect()
        let service = h.makeService(reporter: reporter(wire, folder: h.folder.appendingPathComponent("Reports")))
        let id = try await runOne(h, service, failed(), live: true)
        await h.until({ wire.requests.count == 1 }, "the report")

        let request = try XCTUnwrap(wire.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.metawhisp.com/api/pro/errand-report")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer LICENSE-1")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let sent = try body(request)
        XCTAssertEqual(Set(sent.keys), ["errand_id", "ending", "failure_kind", "events", "dropped_events", "app_version"])
        XCTAssertEqual(sent["errand_id"] as? String, id.uuidString)
        XCTAssertEqual(sent["ending"] as? String, "failed")
        XCTAssertEqual(sent["failure_kind"] as? String, "bridgeLost")
        XCTAssertEqual(sent["dropped_events"] as? Int, 0)
        XCTAssertEqual(sent["app_version"] as? String, "1.3.37")
        let events = try XCTUnwrap(sent["events"] as? [[String: Any]])
        XCTAssertEqual(events as NSArray, liveEvents as NSArray, "each event's kind and fields, in order")
        XCTAssertEqual(events.count, h.saved(id)?.record.events.count, "every event the saved record holds")

        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(wire.requests.count, 1, "once")
    }

    func testUnavailableAndStuckAreReportedAndNoOtherEndingIs() async throws {
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        let wire = Wire()
        h.link.connect()
        let service = h.makeService(reporter: reporter(wire, folder: h.folder.appendingPathComponent("Reports")))
        for ending in [ErrandRecord.Ending.done, .needsUser, .noPro, .dailyLimit, .ceiling] {
            _ = try await runOne(h, service, ErrandOutcome(ending: ending, answer: nil, sources: [], sheet: nil, rows: 0))
        }
        let stopped = try XCTUnwrap(service.start(goal: goal, origin: .chat(messageID: UUID())).id)
        _ = await h.runner(for: stopped)
        service.stop(stopped)
        for ending in [ErrandRecord.Ending.unavailable, .stuck] {
            _ = try await runOne(h, service, ErrandOutcome(ending: ending, answer: nil, sources: [], sheet: nil, rows: 0,
                                                           failure: ending == .unavailable ? .engineUnavailable : nil))
        }
        await h.until({ wire.requests.count >= 2 }, "the reports")
        try await Task.sleep(for: .milliseconds(100))
        let sent = try wire.requests.map { try body($0) }
        XCTAssertEqual(sent.map { $0["ending"] as? String }, ["unavailable", "stuck"], "those two alone, in order")
        XCTAssertEqual(sent.map { $0["failure_kind"] as? String }, ["engineUnavailable", nil])
        XCTAssertTrue(sent.last?["failure_kind"] is NSNull, "a stuck errand has no failure kind")
    }

    /// ITER-076 stage 8a, № 19 — the browser never let the errand in: remote debugging off, Chrome not running, the
    /// Allow declined. That is a new user's setup, not a failure: the errand ends with why, as an errand that never
    /// ran ends, and no report goes to MetaWhisp. A failed errand after it is still reported, alone.
    func testAnErrandTheBrowserDidNotLetInIsNotReported() async throws {
        let cases: [(ChromeLink.State, ErrandOutcome.NotRun)] = [(.remoteDebuggingOff, .remoteDebuggingOff),
                                                                 (.notRunning, .browserNotRunning),
                                                                 (.notAllowed, .notAllowed),
                                                                 // Stage 8b, № 158: no Google Chrome, either way.
                                                                 (.notInstalled, .browserNotInstalled)]
        for (state, reason) in cases {
            let h = AgentServiceHarness()
            defer { h.cleanUp() }
            let wire = Wire()
            wire.offline = true
            let reports = reporter(wire, folder: h.folder.appendingPathComponent("Reports"))
            let service = h.makeService(reporter: reports)
            let id = try XCTUnwrap(service.start(goal: goal, origin: .chat(messageID: UUID())).id)
            await h.until({ h.link.waiting == 1 }, "the errand asking for the browser")
            h.link.fail(state)
            await h.until({ !service.errandRunning }, "the errand's end")
            XCTAssertEqual(h.saved(id)?.outcome, ErrandOutcome(ending: .stopped, answer: nil, sources: [], sheet: nil,
                                                               rows: 0, notRun: reason), "\(state)")
            XCTAssertEqual(h.saved(id)?.record.events, [.ending(.stopped, failure: nil, notRun: reason, rows: 0)],
                           "\(state)")
            XCTAssertTrue(reports.waiting.isEmpty, "\(state): no report")

            h.link.connect()
            let failedID = try await runOne(h, service, failed())
            XCTAssertEqual(reports.waiting.map(\.errandID), [failedID], "\(state): the failure after it, alone")
        }
    }

    /// ITER-076 stage 8b, № 15 — MetaWhisp's own Chrome did not open its port in time, did not answer, or refused the
    /// connection: no one was asked to set anything up, so it is the app's own failure. The errand ends failed with
    /// `browserDidNotStart` — MetaChat's approved "The errand failed." (8b-35) — and one report goes.
    func testMetaWhispsOwnChromeThatDidNotStartIsReportedAsItsOwnFailure() async throws {
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        let wire = Wire()
        let reports = reporter(wire, folder: h.folder.appendingPathComponent("Reports"))
        let service = h.makeService(reporter: reports)
        let id = try XCTUnwrap(service.start(goal: goal, origin: .chat(messageID: UUID())).id)
        await h.until({ h.link.waiting == 1 }, "the errand asking for the browser")
        h.link.fail(.didNotStart)
        await h.until({ !service.errandRunning }, "the errand's end")
        let failed = ErrandOutcome(ending: .failed, answer: nil, sources: [], sheet: nil, rows: 0,
                                   failure: .browserDidNotStart)
        XCTAssertEqual(h.saved(id)?.outcome, failed)
        XCTAssertEqual(h.saved(id)?.record.events, [.ending(.failed, failure: .browserDidNotStart, notRun: nil, rows: 0)])
        XCTAssertEqual(ChatService.errandEndingLine(failed), "The errand failed.")
        XCTAssertEqual(h.events(of: id).last, .finished(failed))
        await h.until({ wire.requests.count == 1 }, "its report")
        let sent = try body(XCTUnwrap(wire.requests.first))
        XCTAssertEqual(sent["errand_id"] as? String, id.uuidString)
        XCTAssertEqual(sent["ending"] as? String, "failed")
        XCTAssertEqual(sent["failure_kind"] as? String, "browserDidNotStart")
    }

    // MARK: - Nothing the user typed, read or visited

    func testNothingTheUserTypedReadOrVisitedIsInTheReportOrItsQueue() async throws {
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        let wire = Wire()
        wire.offline = true
        h.link.connect()
        let folder = h.folder.appendingPathComponent("Reports")
        let service = h.makeService(reporter: reporter(wire, folder: folder))
        let id = try await runOne(h, service, failed(), live: true)
        await h.until({ wire.requests.count == 1 }, "the try that could not go")
        let fingerprint = element("textbox").fingerprint
        let queued = try String(contentsOf: folder.appendingPathComponent("queue.json"), encoding: .utf8)
        wire.offline = false
        _ = service.start(goal: "Another errand", origin: .chat(messageID: UUID()))
        await h.until({ wire.requests.count == 2 }, "the waiting report, sent at the next start")
        let sent = text(wire.requests[1])
        XCTAssertTrue(sent.contains(id.uuidString), "the report itself went")
        for secret in [goal, "Chez Sam", host, label, typed, fingerprint, "site-1.test", "Site 1", sheet.absoluteString,
                       "SHEET-ID-777", "private-bank"] {
            XCTAssertFalse(sent.contains(secret), "the report holds \(secret)")
            XCTAssertFalse(queued.contains(secret), "the queue on disk holds \(secret)")
        }
    }

    /// A text field that is not a plain kind — a sentence, an address, a host — is left out of the report, so
    /// nothing a page or a user wrote can ride in one.
    func testATextFieldThatIsNotAKindIsLeftOut() throws {
        var record = ErrandRecord(errandID: UUID(), goal: goal)
        record.append(AgentAction(operation: .click, target: nil, destination: nil, payload: nil, isPlannedSearch: false),
                      outcome: .acted, confidence: nil, engine: "\(label) at \(host)", milliseconds: 5, costUSD: nil)
        record.note(.question(operation: "open https://\(host)/", targetRole: "\(label)"))
        record.end(.failed, failure: .openFailed)
        let report = ErrandReporter.report(of: record, appVersion: "1.3.37")
        let text = try report.encoded()
        XCTAssertFalse(text.contains(host) || text.contains(label) || text.contains("Private"), text)
        XCTAssertEqual(report["events"]?.array?.prefix(2), [
            .object(["kind": .string("step"), "op": .string("click"), "outcome": .string("acted"), "ms": .number(5)]),
            .object(["kind": .string("question")]),
        ])
    }

    // MARK: - Codex review of I-06b

    /// P1-1 — the report's wire contract, pinned against the Pro server. The worker's test/failures.mjs holds this
    /// same literal and checks it against the worker's schema (`ERRAND_REPORT_CONTRACT` in index.js); this test
    /// checks it against the lists the app builds from its enums, and every event kind's fields against the
    /// report of a record holding each kind with all its fields. A value is added on both sides, or neither passes.
    private static let contractValues: [String: [String]] = [
        "plan_result": ["ok", "failed", "timedOut", "ceiling", "stopped"],
        "purpose": ["plan", "subgoal", "field_text", "read", "verify", "recover"],
        "operation": ["open", "click", "type", "select", "scroll", "wait", "back", "done", "stuck", "more", "none"],
        "role": ["button", "menuitem", "menuitemcheckbox", "menuitemradio", "tab", "option", "checkbox", "radio", "switch",
                 "treeitem", "textbox", "searchbox", "spinbutton", "combobox", "listbox", "link", "other"],
        "outcome": ["acted", "gone", "ambiguous", "unsupported", "reconsidered", "confirmed", "refused", "failed", "handedOver"],
        "engine": ["jev"],
        "page_miss": ["read", "report", "settle"],
        "reply": ["yes", "no", "expired", "stopped"],
        "handover": ["signIn", "captcha", "grant", "payment", "file", "cookies"],
        "ending": ["done", "stopped", "stuck", "ceiling", "failed", "needsUser", "noPro", "dailyLimit", "unavailable",
                   "notFinished"],
        "failure": ["openFailed", "neverSettled", "bridgeLost", "engineUnavailable", "sheetFailed", "planFailed",
                    "subgoalFailed", "browserDidNotStart"],
        "not_run": ["expired", "updateWaiting", "stoppedAll", "macSlept", "appQuit", "browserNotRunning",
                    "browserNotInstalled", "remoteDebuggingOff", "notAllowed"],
        "reported_ending": ["failed", "unavailable", "stuck"],
        "dialog": ["alert", "confirm", "prompt", "beforeunload"],
    ]
    private static let contractEvents: [String: [String: String]] = [
        "plan": ["result": "plan_result", "ms": "count", "usd": "usd"],
        "model": ["purpose": "purpose", "result": "plan_result", "ms": "count", "usd": "usd"],
        "step": ["op": "operation", "role": "role", "outcome": "outcome", "confidence": "fraction", "engine": "engine",
                 "ms": "count", "usd": "usd"],
        "page": ["miss": "page_miss"],
        "wait": ["s": "seconds", "answered": "answered"],
        "question": ["op": "operation", "role": "role"],
        "answer": ["reply": "reply"],
        "handover": ["handover": "handover"],
        "continued": [:],
        "ending": ["ending": "ending", "failure": "failure", "not_run": "not_run", "rows": "count"],
        "taken_back": [:],
        "dialog": ["dialog": "dialog", "accepted": "answered"],
        "download_refused": [:],
        "address_refused": [:],
    ]

    func testTheReportsWireContractIsTheLiteralPinnedAgainstTheServer() throws {
        XCTAssertEqual(ErrandReporter.values.mapValues { $0.sorted() }, Self.contractValues.mapValues { $0.sorted() },
                       "the app's lists, from its enums, are the pinned literal")
        let button = element("button")
        var record = ErrandRecord(errandID: UUID(), goal: goal)
        record.note(.plan(.ok, milliseconds: 12, costUSD: 0.02))
        record.note(.model(.subgoal, .ok, milliseconds: 9, costUSD: 0.0002))
        record.append(AgentAction(operation: .click, target: button, destination: nil, payload: nil, isPlannedSearch: false),
                      outcome: .acted, confidence: 0.9, engine: JevDecisionEngine.engineName, milliseconds: 40, costUSD: 0.001,
                      operationConfidence: 0.95, targetConfidence: 0.9, targets: 12)
        record.note(.read(.init(end: .noLines, blocks: 0,
                                walk: .init(root: .main, roots: 1, pageHidden: false, met: 4, kept: 0, dropped: [.unseen: 4],
                                            cut: nil))))
        record.note(.pageMiss(.read))
        record.note(.serviceWait(seconds: 2, answered: true))
        record.note(.question(about: AgentAction(operation: .click, target: button, destination: nil, payload: nil,
                                                 isPlannedSearch: false)))
        record.note(.answer(.yes))
        record.note(.handover(.signIn, host: host))
        record.note(.continued)
        record.note(.takenBack)
        record.note(.dialog(.confirm, accepted: false))
        record.note(.downloadRefused)
        record.note(.addressRefused)
        record.end(.failed, failure: .bridgeLost, notRun: .notAllowed)
        let events = try XCTUnwrap(ErrandReporter.report(of: record, appVersion: "1.3.37")["events"]?.array)
        XCTAssertEqual(Set(events.compactMap { $0["kind"]?.string }), Set(Self.contractEvents.keys), "every kind")
        for event in events {
            let kind = try XCTUnwrap(event["kind"]?.string)
            let fields = try XCTUnwrap(Self.contractEvents[kind], kind)
            XCTAssertEqual(Set(try XCTUnwrap(event.object).keys), Set(fields.keys).union(["kind"]), "\(kind): its fields and no other")
            for (name, type) in fields {
                guard let list = Self.contractValues[type] else { continue }
                XCTAssertTrue(list.contains(try XCTUnwrap(event[name]?.string)), "\(kind).\(name) is one of \(type)")
            }
        }
    }

    /// ITER-076 stage 4a — a read's event and Jev's own numbers on a step stay on the Mac: the server's contract
    /// is closed, and a kind or a field it does not hold would have the whole report refused. They go into a
    /// report once both sides list them.
    func testAReadAndJevsOwnNumbersStayOutOfTheReport() throws {
        var record = ErrandRecord(errandID: UUID(), goal: goal)
        record.note(.read(.init(end: .read, blocks: 15)))
        record.append(AgentAction(operation: .click, target: element("link"), destination: nil, payload: nil,
                                  isPlannedSearch: false),
                      outcome: .reconsidered, confidence: 0.5, engine: JevDecisionEngine.engineName, milliseconds: 5,
                      costUSD: nil, operationConfidence: 0.9, targetConfidence: 0.5, targets: 40)
        record.end(.stuck, failure: nil)
        let events = try XCTUnwrap(ErrandReporter.report(of: record, appVersion: "1.3.37")["events"]?.array)
        XCTAssertEqual(events, [
            .object(["kind": .string("step"), "op": .string("click"), "role": .string("link"),
                     "outcome": .string("reconsidered"), "confidence": .number(0.5), "engine": .string("jev"),
                     "ms": .number(5)]),
            .object(["kind": .string("ending"), "ending": .string("stuck"), "rows": .number(0)]),
        ])
    }

    /// P1-1 — a text the contract does not list is left out of the event, so the server takes the rest of the
    /// report; one outside the lists would be refused whole.
    func testAValueOutsideTheContractIsLeftOutOfItsEvent() throws {
        var record = ErrandRecord(errandID: UUID(), goal: goal)
        record.append(AgentAction(operation: .click, target: nil, destination: nil, payload: nil, isPlannedSearch: false),
                      outcome: .acted, confidence: 0.5, engine: "scripted", milliseconds: 5, costUSD: nil)
        record.note(.question(operation: "intranet", targetRole: "Delete"))
        record.end(.stuck, failure: nil)
        let events = try XCTUnwrap(ErrandReporter.report(of: record, appVersion: "1.3.37")["events"]?.array)
        XCTAssertEqual(Array(events.prefix(2)), [
            .object(["kind": .string("step"), "op": .string("click"), "outcome": .string("acted"), "confidence": .number(0.5),
                     "ms": .number(5)]),
            .object(["kind": .string("question")]),
        ])
    }

    /// P2-1 — a report the server kept but the queue could not let go of (a disk that is full) is not sent again and
    /// again: the flush stops at once, and the report goes at a later one.
    func testADeliveredReportTheQueueCannotLetGoOfIsNotSentAgainInThatFlush() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mw-reports-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let wire = Wire()
        wire.offline = true
        let full = Flag()
        let reports = ErrandReporter(
            client: ProLLMClient(licenseKey: { wire.license }, send: { try await wire.respond($0) }, log: { _ in }),
            directory: folder, appVersion: "1.3.37",
            persist: { data, file in
                if full.on { throw CocoaError(.fileWriteOutOfSpace) }
                try ErrandReporter.onDisk(data, file)
            })
        for _ in 1...2 {
            var record = ErrandRecord(errandID: UUID(), goal: goal)
            record.end(.failed, failure: .openFailed)
            reports.report(record)
        }
        await reports.sendWaiting()
        XCTAssertEqual(reports.waiting.count, 2)
        let tried = wire.requests.count
        wire.offline = false
        full.on = true
        let finished = Flag()
        let round = Task { await reports.sendWaiting(); finished.on = true }
        let deadline = ContinuousClock.now + .seconds(2)
        while !finished.on, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        let sent = wire.requests.count - tried
        full.on = false
        await round.value
        XCTAssertTrue(finished.on || sent == 1, "the flush returned")
        XCTAssertEqual(sent, 1, "sent once, not again while the queue cannot let it go")
        XCTAssertEqual(reports.waiting.count, 2, "it still waits, and goes at a later flush")
    }

    /// P2-2 — a report past seven days leaves the disk at the next flush, with no new report written.
    func testAReportPastSevenDaysLeavesTheDiskAtTheNextErrandsStart() async throws {
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        let wire = Wire()
        wire.offline = true
        h.link.connect()
        let folder = h.folder.appendingPathComponent("Reports")
        var now = Date()
        let reports = reporter(wire, folder: folder, now: { now })
        let service = h.makeService(reporter: reports)
        _ = try await runOne(h, service, failed())
        await reports.sendWaiting()
        let file = folder.appendingPathComponent("queue.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        now += 8 * 86_400
        _ = service.start(goal: "Another errand", origin: .chat(messageID: UUID()))
        await h.until({ !FileManager.default.fileExists(atPath: file.path) }, "the expired report gone from disk")
    }

    // MARK: - Cleared with MetaChat's history

    /// Owner decision (I-03): clearing MetaChat leaves nothing of the agent on disk. The clear reaches the
    /// service's `deleteAllRecords` (ChatService's `clearErrandRecords`), and the waiting reports go with it.
    func testClearingMetaChatsHistoryEmptiesTheQueueAndNothingIsSentLater() async throws {
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        let wire = Wire()
        wire.offline = true
        h.link.connect()
        let folder = h.folder.appendingPathComponent("Reports")
        let reports = reporter(wire, folder: folder)
        let service = h.makeService(reporter: reports)
        _ = try await runOne(h, service, failed())
        await reports.sendWaiting()
        XCTAssertEqual(reports.waiting.count, 1)
        let tried = wire.requests.count

        service.deleteAllRecords()
        XCTAssertEqual(reports.waiting.count, 0, "the queue is cleared with the records")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("queue.json").path),
                       "nothing of it is left on disk")
        wire.offline = false
        _ = service.start(goal: "Another errand", origin: .chat(messageID: UUID()))
        await reports.sendWaiting()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(wire.requests.count, tried, "nothing is sent later")
    }

    /// A clear while a report is on its way: that one is gone already, the ones behind it are not sent.
    func testAClearDuringASendStopsTheReportsBehindIt() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mw-reports-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let wire = Wire()
        wire.offline = true
        let reports = reporter(wire, folder: folder)
        for _ in 1...3 {
            var record = ErrandRecord(errandID: UUID(), goal: goal)
            record.end(.failed, failure: .openFailed)
            reports.report(record)
        }
        await reports.sendWaiting()
        XCTAssertEqual(reports.waiting.count, 3)
        let tried = wire.requests.count
        wire.offline = false
        wire.slow = true
        let round = Task { await reports.sendWaiting() }
        while wire.requests.count == tried { try await Task.sleep(for: .milliseconds(2)) }
        reports.clearWaiting()
        await round.value
        XCTAssertEqual(wire.requests.count, tried + 1, "only the one already on its way")
        XCTAssertEqual(reports.waiting.count, 0)
    }

    /// A flush awaited while another one runs — the one a new report starts — returns only once a round begun after
    /// the call has ended: what waited when it was made has gone. Returning at once, it would say "flushed" with the
    /// reports still waiting.
    func testAFlushAwaitedWhileAnotherRunsReturnsOnlyOnceWhatWaitedHasGone() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mw-reports-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let wire = Wire()
        wire.hold()
        let reports = reporter(wire, folder: folder)
        var first = ErrandRecord(errandID: UUID(), goal: goal)
        first.end(.failed, failure: .openFailed)
        reports.report(first)
        let deadline = ContinuousClock.now + .seconds(5)
        while wire.requests.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        XCTAssertEqual(wire.requests.count, 1, "the premise: the report's own flush is on its way")
        var second = ErrandRecord(errandID: UUID(), goal: goal)
        second.end(.stuck, failure: nil)
        reports.report(second)
        let returned = Flag()
        let call = Task { await reports.sendWaiting(); returned.on = true }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(returned.on, "the call waits for its round")
        wire.release()
        await call.value
        XCTAssertEqual(try wire.requests.map { try body($0)["errand_id"] as? String },
                       [first.errandID.uuidString, second.errandID.uuidString])
        XCTAssertEqual(reports.waiting.count, 0, "what waited at the call has gone")
    }

    /// A call made while a round is failing — the network came back as its request was on its way — asks for a round
    /// of its own: the report that could not go then goes now, not at some later flush.
    func testACallMadeWhileARoundFailsAsksForOneMoreRound() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mw-reports-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let wire = Wire()
        wire.offline = true
        wire.hold()
        let reports = reporter(wire, folder: folder)
        var record = ErrandRecord(errandID: UUID(), goal: goal)
        record.end(.failed, failure: .openFailed)
        reports.report(record)
        let deadline = ContinuousClock.now + .seconds(5)
        while wire.requests.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        XCTAssertEqual(wire.requests.count, 1, "the premise: a request that will fail is on its way")
        wire.offline = false
        let call = Task { await reports.sendWaiting() }
        try await Task.sleep(for: .milliseconds(50))
        wire.release()
        await call.value
        XCTAssertEqual(wire.requests.count, 2, "tried again in the call's own round")
        XCTAssertEqual(reports.waiting.count, 0, "and it went")
    }

    // MARK: - Without Pro, nothing is sent

    func testWithoutProNothingIsSentAndTheReportWaits() async throws {
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        let wire = Wire()
        wire.pro = false
        h.link.connect()
        let folder = h.folder.appendingPathComponent("Reports")
        let reports = reporter(wire, folder: folder)
        let service = h.makeService(reporter: reports)
        let id = try await runOne(h, service, failed())
        await reports.sendWaiting()
        XCTAssertEqual(wire.requests.count, 0, "no request at all without Pro")
        XCTAssertEqual(reports.waiting.map(\.errandID), [id], "it waits")
        wire.pro = true
        await reports.sendWaiting()
        XCTAssertEqual(try wire.requests.map { try body($0)["errand_id"] as? String }, [id.uuidString])
        XCTAssertEqual(reports.waiting.count, 0)
    }

    // MARK: - A report that cannot go waits on disk

    func testAReportThatCannotGoWaitsOnDiskOwnerOnlyAndGoesWithTheNextReport() async throws {
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        let wire = Wire()
        wire.status = 503
        h.link.connect()
        let folder = h.folder.appendingPathComponent("Reports")
        let reports = reporter(wire, folder: folder)
        let service = h.makeService(reporter: reports)
        let first = try await runOne(h, service, failed())
        await h.until({ wire.requests.count == 1 }, "the first try")
        await reports.sendWaiting()
        XCTAssertEqual(reports.waiting.map(\.errandID), [first])
        let file = folder.appendingPathComponent("queue.json")
        let fileMode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        let folderMode = try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? Int
        XCTAssertEqual(fileMode, 0o600, "the queue is the owner's alone")
        XCTAssertEqual(folderMode, 0o700)

        let tried = wire.requests.count
        wire.status = 200
        let second = try await runOne(h, service, failed(0))
        await h.until({ reports.waiting.isEmpty && wire.requests.count >= tried + 2 }, "both reports sent")
        let sent = try wire.requests.dropFirst(tried).map { try body($0)["errand_id"] as? String }
        XCTAssertEqual(sent, [first.uuidString, second.uuidString], "the waiting one first, then the new one")
    }

    func testAWaitingReportGoesAtTheNextErrandsStart() async throws {
        let h = AgentServiceHarness()
        defer { h.cleanUp() }
        let wire = Wire()
        wire.offline = true
        h.link.connect()
        let reports = reporter(wire, folder: h.folder.appendingPathComponent("Reports"))
        let service = h.makeService(reporter: reports)
        let id = try await runOne(h, service, failed())
        await reports.sendWaiting()
        XCTAssertEqual(reports.waiting.map(\.errandID), [id])
        let tried = wire.requests.count
        wire.offline = false
        _ = service.start(goal: "Another errand", origin: .chat(messageID: UUID()))
        await h.until({ reports.waiting.isEmpty }, "the waiting report sent")
        XCTAssertEqual(try wire.requests.dropFirst(tried).map { try body($0)["errand_id"] as? String }, [id.uuidString])
    }

    func testTheQueueKeepsAtMostTwentyReportsAndNoneOlderThanSevenDays() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mw-reports-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let wire = Wire()
        wire.offline = true
        var now = Date(timeIntervalSince1970: 1_790_000_000)
        let reports = reporter(wire, folder: folder, now: { now })
        let ids = (1...21).map { _ in UUID() }
        for id in ids {
            var record = ErrandRecord(errandID: id, goal: goal)
            record.end(.failed, failure: .openFailed)
            reports.report(record)
            now += 60
        }
        await reports.sendWaiting()
        XCTAssertEqual(reports.waiting.map(\.errandID), Array(ids.dropFirst()), "the 20 newest, the oldest let go")

        now += 7 * 86_400 - 60 * 19
        var late = ErrandRecord(errandID: UUID(), goal: goal)
        late.end(.stuck, failure: nil)
        reports.report(late)
        await reports.sendWaiting()
        XCTAssertEqual(reports.waiting.map(\.errandID), Array(ids.suffix(19)) + [late.errandID],
                       "the one queued seven days and a minute ago is gone")
        now += 7 * 86_400 + 1
        await reports.sendWaiting()
        XCTAssertEqual(reports.waiting.map(\.errandID), [], "past seven days nothing waits")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("queue.json").path),
                       "and nothing of them is left on disk (Codex P2-2)")
    }

    /// The same errand reported again waits once.
    func testAnErrandWaitsOnceHoweverOftenItIsReported() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mw-reports-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let wire = Wire()
        wire.offline = true
        let reports = reporter(wire, folder: folder)
        var record = ErrandRecord(errandID: UUID(), goal: goal)
        record.end(.failed, failure: .openFailed)
        reports.report(record)
        reports.report(record)
        await reports.sendWaiting()
        XCTAssertEqual(reports.waiting.map(\.errandID), [record.errandID])
    }

    /// A report the server refuses as it is (400, 413) would fail again: it is let go. The rest — no Pro, the
    /// day's limit, the service down — waits.
    func testAReportTheServerRefusesAsItIsIsLetGoAndTheRestWaits() async throws {
        for (status, waits) in [(400, false), (413, false), (401, true), (429, true), (500, true), (503, true), (200, false)] {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mw-reports-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: folder) }
            let wire = Wire()
            wire.status = status
            let reports = reporter(wire, folder: folder)
            var record = ErrandRecord(errandID: UUID(), goal: goal)
            record.end(.unavailable, failure: .engineUnavailable)
            reports.report(record)
            await reports.sendWaiting()
            XCTAssertGreaterThanOrEqual(wire.requests.count, 1, "\(status): sent")
            XCTAssertEqual(reports.waiting.count, waits ? 1 : 0, "\(status)")
        }
    }
}
