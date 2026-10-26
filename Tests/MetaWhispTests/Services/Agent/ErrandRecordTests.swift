import XCTest
@testable import MetaWhisp

/// What an errand leaves behind (ITER-074 §6.5): per step the operation, the
/// target's role and fingerprint, the confidence, the engine, the time and
/// the cost — never the page's text or what was typed.
final class ErrandRecordTests: XCTestCase {

    private let secretWords = "Private draft for Sam"

    private func target() -> ObservedElement {
        ObservedElement(index: 3, role: "textbox", name: secretWords, text: secretWords, href: nil, inputType: "text",
                        heading: secretWords, region: .main, inViewport: true, context: secretWords, formAction: nil,
                        formMethod: nil, formSubmitLabel: nil, options: [secretWords], checked: nil)
    }

    func testAStepKeepsWhatWasDoneButNoPageText() throws {
        var record = ErrandRecord(errandID: UUID(), goal: "Add three sites to a sheet")
        let action = AgentAction(operation: .type, target: target(), destination: nil, payload: secretWords,
                                 isPlannedSearch: false)
        record.append(action, outcome: .acted, confidence: 0.91, engine: "scripted", milliseconds: 120, costUSD: 0.002)
        let step = try XCTUnwrap(record.steps.first)
        XCTAssertEqual(step.operation, "type")
        XCTAssertEqual(step.targetRole, "textbox")
        XCTAssertEqual(step.fingerprint, target().fingerprint)
        XCTAssertEqual(step.outcome, .acted)
        let json = String(decoding: try JSONEncoder().encode(record), as: UTF8.self)
        XCTAssertFalse(json.contains("Private"), "no name, text, heading, context, value or typed text")
    }

    /// The report comes from the page's world, so even a role is kept only
    /// when it is one the agent acts on (review round 10).
    func testARoleTheAgentDoesNotActOnIsNotRecorded() throws {
        var record = ErrandRecord(errandID: UUID(), goal: "Add three sites to a sheet")
        let odd = ObservedElement(index: 0, role: secretWords, name: "", text: "", href: nil, inputType: nil,
                                  heading: nil, region: .main, inViewport: true, context: nil, formAction: nil,
                                  formMethod: nil, formSubmitLabel: nil, options: nil, checked: nil)
        record.append(AgentAction(operation: .click, target: odd, destination: nil, payload: nil, isPlannedSearch: false),
                      outcome: .acted, confidence: 0.9, engine: "scripted", milliseconds: 1, costUSD: nil)
        XCTAssertEqual(record.steps.first?.targetRole, "other")
    }

    func testTheRecordRoundTrips() throws {
        var record = ErrandRecord(errandID: UUID(), goal: "Add three sites to a sheet")
        record.append(AgentAction(operation: .scroll, target: nil, destination: nil, payload: nil, isPlannedSearch: false),
                      outcome: .acted, confidence: nil, engine: "scripted", milliseconds: 5, costUSD: nil)
        record.rows = [Scratchpad.Row(cells: ["One", "https://site-1.test/"], source: URL(string: "https://site-1.test/")!)]
        record.ending = .done
        let decoded = try JSONDecoder().decode(ErrandRecord.self, from: JSONEncoder().encode(record))
        XCTAssertEqual(decoded, record)
    }

    /// ITER-076 I-05: a failure that ended an errand is kept by its kind —
    /// one of a closed set, written as its name and nothing else.
    func testAFailureIsKeptByItsKindAlone() throws {
        var record = ErrandRecord(errandID: UUID(), goal: "Add three sites to a sheet")
        record.ending = .failed
        record.failure = .bridgeLost
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        XCTAssertEqual(json["failure"] as? String, "bridgeLost")
        XCTAssertEqual(try JSONDecoder().decode(ErrandRecord.self, from: JSONEncoder().encode(record)), record)
        XCTAssertEqual(Set(ErrandRecord.Failure.allCases.map(\.rawValue)),
                       ["openFailed", "neverSettled", "bridgeLost", "engineUnavailable", "sheetFailed", "planFailed",
                        "subgoalFailed", "browserDidNotStart"])
    }

    /// Review round 1 (P2-1, P2-6): the Sheet's state and what the errand
    /// spent come back whole; a record saved before either existed still
    /// reads.
    func testTheSheetsStateAndTheSpendRoundTrip() throws {
        var record = ErrandRecord(errandID: UUID(), goal: "Add three sites to a sheet")
        record.sheet = URL(string: "https://sheet.test/1")
        record.sheetWrite = .pasted
        record.spentUSD = 0.0205
        XCTAssertEqual(try JSONDecoder().decode(ErrandRecord.self, from: JSONEncoder().encode(record)), record)
        let before = #"{"errandID":"\#(UUID().uuidString)","goal":"g","steps":[],"rows":[]}"#
        let old = try JSONDecoder().decode(ErrandRecord.self, from: Data(before.utf8))
        XCTAssertNil(old.sheetWrite)
        XCTAssertNil(old.spentUSD)
        XCTAssertEqual(old.events, [], "ITER-076 I-06a: a record saved before events were kept reads with none")
        XCTAssertEqual(old.droppedEvents, 0)
    }

    // MARK: - ITER-076 I-06a: every event on record

    private let errand = UUID(uuidString: "1A2B3C4D-5E6F-4A1B-8C2D-3E4F5A6B7C8D")!

    private func click(role: String = "button") -> AgentAction {
        let button = ObservedElement(index: 1, role: role, name: "Send", text: "Send", href: nil, inputType: nil,
                                     heading: nil, region: .main, inViewport: true, context: nil, formAction: nil,
                                     formMethod: nil, formSubmitLabel: nil, options: nil, checked: nil)
        return AgentAction(operation: .click, target: button, destination: nil, payload: nil, isPlannedSearch: false)
    }

    /// Each kind of event says, in the log, its number and its fields — and
    /// nothing more. The record's line for an event is the line the log got.
    func testEachEventSaysItsFieldsAndNothingMore() {
        var record = ErrandRecord(errandID: errand, goal: "Add three sites to a sheet")
        let scroll = AgentAction(operation: .scroll, target: nil, destination: nil, payload: nil, isPlannedSearch: false)
        let lines: [String?] = [
            record.note(.plan(.ok, milliseconds: 12, costUSD: 0.02)),
            record.append(scroll, outcome: .acted, confidence: 0.95, engine: "jev", milliseconds: 40, costUSD: 0.001344),
            record.append(click(), outcome: .refused, confidence: nil, engine: "jev", milliseconds: 7, costUSD: nil),
            record.note(.pageMiss(.read)),
            record.note(.serviceWait(seconds: 1, answered: true)),
            record.note(.serviceWait(seconds: 2, answered: nil)),
            record.note(.question(about: click())),
            record.note(.answer(.expired)),
            record.note(.handover(.signIn, host: "site-5.test")),
            record.end(.failed, failure: .bridgeLost),
        ]
        let fingerprint = click().target!.fingerprint
        XCTAssertEqual(lines, [
            "[Errand 1A2B3C4D] #1 plan result=ok ms=12 usd=0.020000",
            "[Errand 1A2B3C4D] #2 step op=scroll outcome=acted confidence=0.95 engine=jev ms=40 usd=0.001344",
            "[Errand 1A2B3C4D] #3 step op=click role=button fp=\(fingerprint) outcome=refused engine=jev ms=7",
            "[Errand 1A2B3C4D] #4 page miss=read",
            "[Errand 1A2B3C4D] #5 wait s=1.0 answered=true",
            "[Errand 1A2B3C4D] #6 wait s=2.0",
            "[Errand 1A2B3C4D] #7 question op=click role=button",
            "[Errand 1A2B3C4D] #8 answer reply=expired",
            "[Errand 1A2B3C4D] #9 handover kind=signIn host=site-5.test",
            "[Errand 1A2B3C4D] #10 ending kind=failed failure=bridgeLost rows=0",
        ])
        XCTAssertEqual(record.events.count, 10)
        XCTAssertEqual(record.events.indices.map(record.logLine(at:)), lines.compactMap { $0 })
        XCTAssertEqual(record.ending, .failed)
        XCTAssertEqual(record.failure, .bridgeLost)
    }

    /// ITER-076 I-09: what the tab did on its own is kept by its kind alone —
    /// a dialog by its kind and its answer, never its words; a refused
    /// download or address with no file name and no address — and round-trips.
    func testWhatTheTabDidIsKeptByItsKindAlone() throws {
        var record = ErrandRecord(errandID: errand, goal: "Add three sites to a sheet")
        let lines = [
            record.note(.dialog(.confirm, accepted: false)),
            record.note(.dialog(.beforeunload, accepted: true)),
            record.note(.downloadRefused),
            record.note(.addressRefused),
        ]
        XCTAssertEqual(lines, [
            "[Errand 1A2B3C4D] #1 dialog kind=confirm accepted=false",
            "[Errand 1A2B3C4D] #2 dialog kind=beforeunload accepted=true",
            "[Errand 1A2B3C4D] #3 download refused",
            "[Errand 1A2B3C4D] #4 address refused",
        ])
        let again = try JSONDecoder().decode(ErrandRecord.self, from: JSONEncoder().encode(record))
        XCTAssertEqual(again.events, record.events)
    }

    /// ITER-076 stage 4a: each read of the page is on record by the guard
    /// that ended it — or as read — with how many lines the page gave and
    /// what its walk met; a step keeps Jev's own confidences and how many
    /// targets its operation was offered. Each line says those kinds and
    /// numbers and nothing more; a correction keeps them; they round-trip,
    /// and a step saved before them still reads.
    func testAReadAndJevsOwnNumbersSayTheirKindsAndNumbersAndNothingMore() throws {
        var record = ErrandRecord(errandID: errand, goal: "Find 10 jokes")
        let walk = ErrandModel.Capture.Walk(root: .role, roots: 2, pageHidden: false, met: 9, kept: 0,
                                            dropped: [.unseen: 5, .hidden: 3, .writing: 1], cut: .time)
        let fingerprint = click().target!.fingerprint
        let lines = [
            record.note(.read(.init(end: .nothingToFind))),
            record.note(.read(.init(end: .noLines, blocks: 0, walk: walk))),
            record.note(.read(.init(end: .read, blocks: 15))),
            record.append(click(), outcome: .reconsidered, confidence: 0.54, engine: "jev", milliseconds: 9, costUSD: nil,
                          operationConfidence: 0.91, targetConfidence: 0.54, targets: 120),
        ]
        XCTAssertEqual(lines, [
            "[Errand 1A2B3C4D] #1 read end=nothingToFind",
            "[Errand 1A2B3C4D] #2 read end=noLines blocks=0 root=role roots=2 hidden=false met=9 kept=0 "
                + "dropped=hidden:3,unseen:5,writing:1 cut=time",
            "[Errand 1A2B3C4D] #3 read end=read blocks=15",
            "[Errand 1A2B3C4D] #4 step op=click role=button fp=\(fingerprint) outcome=reconsidered confidence=0.54 "
                + "opConfidence=0.91 targetConfidence=0.54 targets=120 engine=jev ms=9",
        ])
        XCTAssertEqual(record.markLastStep(.gone),
                       "[Errand 1A2B3C4D] #4 step op=click role=button fp=\(fingerprint) outcome=gone confidence=0.54 "
                       + "opConfidence=0.91 targetConfidence=0.54 targets=120 engine=jev ms=9", "a correction keeps them")
        XCTAssertEqual(record.steps.first?.targets, 120)
        XCTAssertEqual(try JSONDecoder().decode(ErrandRecord.self, from: JSONEncoder().encode(record)), record)
        let before = #"{"errandID":"\#(UUID().uuidString)","goal":"g","steps":[{"operation":"click","outcome":"acted","#
            + #""engine":"jev","milliseconds":5}],"rows":[]}"#
        let old = try XCTUnwrap(try JSONDecoder().decode(ErrandRecord.self, from: Data(before.utf8)).steps.first)
        XCTAssertNil(old.operationConfidence)
        XCTAssertNil(old.targetConfidence)
        XCTAssertNil(old.targets)
    }

    /// A step's event is the step `steps` keeps: corrected, it is said again
    /// under its own number; taken back, `steps` drops it and its event says
    /// so in place — numbers only grow (I-06a review, P2-1).
    func testACorrectedStepIsSaidAgainUnderItsNumberAndOneTakenBackIsSaidSo() {
        var record = ErrandRecord(errandID: errand, goal: "Add three sites to a sheet")
        record.note(.plan(.ok, milliseconds: 1, costUSD: 0))
        record.append(click(), outcome: .acted, confidence: 0.9, engine: "jev", milliseconds: 5, costUSD: nil)
        let fingerprint = click().target!.fingerprint
        XCTAssertEqual(record.markLastStep(.failed),
                       "[Errand 1A2B3C4D] #2 step op=click role=button fp=\(fingerprint) outcome=failed confidence=0.9 engine=jev ms=5")
        XCTAssertEqual(record.events.last, .step(record.steps[0]))
        record.append(click(), outcome: .acted, confidence: 0.9, engine: "jev", milliseconds: 5, costUSD: nil)
        XCTAssertEqual(record.removeLastStep(), "[Errand 1A2B3C4D] #3 taken back")
        XCTAssertEqual(record.steps.count, 1)
        XCTAssertEqual(record.events.count, 3)
        XCTAssertEqual(record.events.last, .takenBack)
        XCTAssertEqual(record.logLine(at: 2), "[Errand 1A2B3C4D] #3 taken back")
        XCTAssertEqual(record.end(.stopped, failure: nil), "[Errand 1A2B3C4D] #4 ending kind=stopped rows=0")
        XCTAssertEqual(record.markLastStep(.gone),
                       "[Errand 1A2B3C4D] #2 step op=click role=button fp=\(fingerprint) outcome=gone confidence=0.9 engine=jev ms=5",
                       "the step before is still the last one")
    }

    /// The saved ending is the errand's last event: the service's takes the
    /// place of its run's, under the same number, and an ending already so
    /// says nothing new. An errand that never ran says why.
    func testTheSavedEndingTakesThePlaceOfTheRunsOwn() {
        var record = ErrandRecord(errandID: errand, goal: "Add three sites to a sheet")
        record.note(.plan(.ok, milliseconds: 1, costUSD: 0))
        record.rows = [Scratchpad.Row(cells: ["One"], source: URL(string: "https://site-1.test/")!)]
        XCTAssertEqual(record.end(.stopped, failure: nil), "[Errand 1A2B3C4D] #2 ending kind=stopped rows=1")
        XCTAssertNil(record.end(.stopped, failure: nil), "already so: nothing new")
        XCTAssertEqual(record.end(.ceiling, failure: nil), "[Errand 1A2B3C4D] #2 ending kind=ceiling rows=1")
        XCTAssertEqual(record.events.count, 2)
        XCTAssertEqual(record.ending, .ceiling)

        var never = ErrandRecord(errandID: errand, goal: "Add three sites to a sheet")
        XCTAssertEqual(never.end(.failed, failure: nil, notRun: .browserNotRunning),
                       "[Errand 1A2B3C4D] #1 ending kind=failed notRun=browserNotRunning rows=0")
    }

    /// At most 200 events: past that the newest are kept — the end and what
    /// led to it — and the rest are counted; numbers go on.
    func testARecordKeepsTheNewest200EventsAndCountsTheRest() throws {
        var record = ErrandRecord(errandID: errand, goal: "Add three sites to a sheet")
        record.note(.plan(.ok, milliseconds: 1, costUSD: 0))
        for _ in 1...204 { record.note(.pageMiss(.read)) }
        let last = record.end(.stuck, failure: nil)
        XCTAssertEqual(ErrandRecord.maxEvents, 200)
        XCTAssertEqual(record.events.count, 200)
        XCTAssertEqual(record.droppedEvents, 6)
        XCTAssertEqual(record.events.last, .ending(.stuck, failure: nil, notRun: nil, rows: 0), "the end is kept")
        XCTAssertEqual(last, "[Errand 1A2B3C4D] #206 ending kind=stuck rows=0")
        XCTAssertEqual(record.logLine(at: 0), "[Errand 1A2B3C4D] #7 page miss=read")
        let decoded = try JSONDecoder().decode(ErrandRecord.self, from: JSONEncoder().encode(record))
        XCTAssertEqual(decoded, record)
        XCTAssertEqual(decoded.droppedEvents, 6)
    }

    /// A typed value, a page's label and a role from the page's world reach
    /// neither the record nor any line: a step and a question about it keep
    /// the operation and a role the agent acts on alone.
    func testNoTypedValueOrLabelReachesTheEventsOrTheirLines() throws {
        let typed = "hunter2-typed-secret"
        var record = ErrandRecord(errandID: errand, goal: "Add three sites to a sheet")
        let typing = AgentAction(operation: .type, target: target(), destination: nil, payload: typed,
                                 isPlannedSearch: false)
        var lines = [record.append(typing, outcome: .acted, confidence: 0.9, engine: "jev", milliseconds: 3,
                                   costUSD: nil)]
        lines.append(record.note(.question(about: typing)))
        let odd = click(role: secretWords)
        lines.append(record.note(.question(about: odd)))
        lines.append(record.end(.done, failure: nil) ?? "")
        XCTAssertEqual(Array(record.events.dropFirst().prefix(2)),
                       [.question(operation: "type", targetRole: "textbox"), .question(operation: "click", targetRole: "other")])
        let json = String(decoding: try JSONEncoder().encode(record), as: UTF8.self)
        for secret in [typed, "Private", "Send"] {
            XCTAssertFalse(json.contains(secret), secret)
            for line in lines { XCTAssertFalse(line.contains(secret), "\(secret) in \(line)") }
        }
    }

    // MARK: - ITER-076 brain, step 2: the facts and the answer they make

    /// The answer is each fact's quote and then its page's address — grouped
    /// by requirement, in the order each was first answered, each quote of a
    /// page once — and nothing else; the sources are the rows' pages, then the
    /// facts', once each. No fact: no answer.
    func testTheAnswerIsEachFactsQuoteAndItsPagesLinkGroupedByRequirement() {
        var record = ErrandRecord(errandID: errand, goal: "Find 10 jokes and their prices")
        XCTAssertNil(record.answer)
        XCTAssertEqual(record.sources, [])
        record.facts = [
            .init(requirements: ["r2"], quote: "Price 4 dollars", source: "main/:3", url: "https://b.test/p"),
            .init(requirements: ["r1"], quote: "Joke 1\nline two", source: "main/:2", url: "https://a.test/"),
            .init(requirements: ["r2"], quote: "Price 5 dollars", source: "main/:4", url: "https://a.test/"),
            .init(requirements: ["r1"], quote: "Joke 1\nline two", source: "main/:9", url: "https://a.test/"),
            .init(requirements: ["r1"], quote: "Price 4 dollars", source: "main/:3", url: "https://b.test/p"),
            .init(requirements: ["r1"], quote: "Joke 2", source: "main/:5", url: "https://c.test/"),
        ]
        XCTAssertEqual(record.answer, "Price 4 dollars\nhttps://b.test/p\n\nPrice 5 dollars\nhttps://a.test/\n\n"
                       + "Joke 1\nline two\nhttps://a.test/\n\nJoke 2\nhttps://c.test/")
        XCTAssertEqual(record.sources.map(\.absoluteString), ["https://b.test/p", "https://a.test/", "https://c.test/"])
        record.rows = [Scratchpad.Row(cells: ["Site"], source: URL(string: "https://row.test/")!)]
        XCTAssertEqual(record.sources.map(\.absoluteString),
                       ["https://row.test/", "https://b.test/p", "https://a.test/", "https://c.test/"])
    }

    /// ITER-076 stage 1 (№ 34, 36): a quote no requirement rests on — context
    /// the reader kept — is in the answer of an errand that did not end done,
    /// which ends with everything it read, and never in a done errand's
    /// answer, which is what answers the requirements. The sources are the
    /// pages of the answer's quotes.
    func testContextIsInTheAnswerOnlyOfAnErrandThatDidNotEndDone() {
        var record = ErrandRecord(errandID: errand, goal: "Find 10 jokes")
        record.facts = [
            .init(requirements: [], quote: "Six jokes", source: "main/:1", url: "https://a.test/"),
            .init(requirements: ["r1"], quote: "Joke 1", source: "main/:2", url: "https://a.test/"),
            .init(requirements: [], quote: "Page 2 of 2", source: "main/:9", url: "https://c.test/"),
            .init(requirements: ["r1"], quote: "Joke 7", source: "main/:2", url: "https://b.test/"),
        ]
        let everything = "Joke 1\nhttps://a.test/\n\nJoke 7\nhttps://b.test/\n\nSix jokes\nhttps://a.test/\n\n"
            + "Page 2 of 2\nhttps://c.test/"
        XCTAssertEqual(record.answer, everything, "still running: everything read")
        XCTAssertEqual(record.sources.map(\.absoluteString), ["https://a.test/", "https://c.test/", "https://b.test/"])
        for ending in ErrandRecord.Ending.allCases where ending != .done {
            record.end(ending, failure: nil)
            XCTAssertEqual(record.answer, everything, ending.rawValue)
        }
        record.end(.done, failure: nil)
        XCTAssertEqual(record.answer, "Joke 1\nhttps://a.test/\n\nJoke 7\nhttps://b.test/", "done: what answers r1")
        XCTAssertEqual(record.sources.map(\.absoluteString), ["https://a.test/", "https://b.test/"])
    }

    /// 2026-10-15 (the owner: the result counts; the bench's total of a table lived only in the reader's words): a
    /// done errand answers each requirement — in the order each was first answered — in the reader's words: the last
    /// claim that answered it whole, then the pages of the facts that claim rests on, once each, as a reference
    /// browser agent drafts its answer from the facts its reader wrote (`draft_answer`, `retrieval.py` 1820-1836,
    /// MIT) — then each fact beneath it that its words do not hold, by the page's own words. A requirement no claim
    /// answered gives its quotes as before. An errand that did not end done ends with everything it read, the page's
    /// own words.
    func testADoneErrandAnswersEachRequirementInTheReadersWords() throws {
        var record = ErrandRecord(errandID: errand, goal: "Sum the second table's Due column")
        record.facts = [
            .init(requirements: ["r1"], quote: "$50.00", source: "main/:46", url: "https://t.test/tables"),
            .init(requirements: ["r1"], quote: "$51.00", source: "main/:52", url: "https://t.test/tables"),
            .init(requirements: ["r2"], quote: "Updated 2026", source: "main/:2", url: "https://u.test/"),
            .init(requirements: [], quote: "Example 2", source: "main/:40", url: "https://v.test/"),
        ]
        record.statements = [
            .init(requirement: nil, text: "The second table is Example 2.", basis: [3]),
            .init(requirement: "r1", text: "The total is $100.00.", basis: [0, 1]),
            .init(requirement: "r1", text: "The total due is $101.00, $50.00 plus $51.00.", basis: [0, 1, 3]),
        ]
        record.end(.done, failure: nil)
        XCTAssertEqual(record.answer, "The total due is $101.00, $50.00 plus $51.00.\nhttps://t.test/tables\nhttps://v.test/"
                       + "\n\nExample 2\nhttps://v.test/\n\nUpdated 2026\nhttps://u.test/",
                       "its words, its pages, the fact its words do not hold, then r2's quote")
        record.end(.notFinished, failure: nil)
        XCTAssertEqual(record.answer, "$50.00\nhttps://t.test/tables\n\n$51.00\nhttps://t.test/tables\n\nUpdated 2026\n"
                       + "https://u.test/\n\nExample 2\nhttps://v.test/", "not done: what it read, the page's own words")
        XCTAssertEqual(try JSONDecoder().decode(ErrandRecord.self, from: JSONEncoder().encode(record)), record)
        let before = #"{"errandID":"\#(UUID().uuidString)","goal":"g","steps":[],"rows":[]}"#
        XCTAssertEqual(try JSONDecoder().decode(ErrandRecord.self, from: Data(before.utf8)).statements, [])
    }

    /// A requirement one read answered with two claims is answered by both, in their order: the version on PyPI's
    /// heading and its release date are one answer in two claims, and kept by its last claim alone the answer gave
    /// the date and no version — done, and wrong (Haiku bench, 2026-10-18). A claim an earlier read made for it is a
    /// former answer, superseded, as before; a record whose claims carry no read gives its last claim, as before.
    func testARequirementAReadAnsweredInTwoClaimsIsAnsweredByBoth() throws {
        var record = ErrandRecord(errandID: errand, goal: "What is the latest released version of httpx?")
        record.facts = [
            .init(requirements: ["r1"], quote: "httpx 0.27.0", source: "main/:1", url: "https://p.test/old"),
            .init(requirements: ["r1"], quote: "httpx 0.28.1", source: "main/:1", url: "https://p.test/httpx"),
            .init(requirements: ["r1"], quote: "Released: Dec 6, 2024\nLatest release", source: "main/:88",
                  url: "https://p.test/httpx"),
        ]
        record.statements = [
            .init(requirement: "r1", text: "The latest version is 0.27.0.", basis: [0], read: 1),
            .init(requirement: "r1", text: "The page's heading is httpx 0.28.1: version 0.28.1.", basis: [1], read: 2),
            .init(requirement: "r1", text: "It was released on Dec 6, 2024, the latest release.", basis: [2], read: 2),
        ]
        record.end(.done, failure: nil)
        XCTAssertEqual(record.answer, "The page's heading is httpx 0.28.1: version 0.28.1.\nhttps://p.test/httpx"
                       + "\n\nIt was released on Dec 6, 2024, the latest release.\nhttps://p.test/httpx"
                       + "\n\nReleased: Dec 6, 2024\nLatest release\nhttps://p.test/httpx",
                       "both claims of the last read, each fact its words do not hold beneath, the earlier read's out")
        XCTAssertEqual(try JSONDecoder().decode(ErrandRecord.self, from: JSONEncoder().encode(record)), record)
    }

    /// The same read's claims, as ErrandModel numbers them: each statement carries the read that made it, and a
    /// statement read again in a later read is kept once, at its latest read.
    func testAReadNumbersItsStatementsAndKeepsARepeatOnceAtItsLatestRead() {
        let shown: [ErrandModel.Block] = [.init(label: "main/:1", kind: "heading", text: "httpx 0.28.1"),
                                          .init(label: "main/:2", kind: "paragraph", text: "Released: Dec 6, 2024")]
        let claims = [ErrandModel.Claim(cite: .init(first: "main/:1", last: "main/:1"), drawsOn: [], records: [],
                                        requirement: "r1", text: "Version 0.28.1."),
                      ErrandModel.Claim(cite: .init(first: "main/:2", last: "main/:2"), drawsOn: [], records: [],
                                        requirement: "r1", text: "Released on Dec 6, 2024.")]
        let first = ErrandModel.read(after: claims, shown: shown, url: "https://p.test/httpx", kept: [], said: [],
                                     asked: ["r1"], read: 1)
        XCTAssertEqual(first.statements.map(\.read), [1, 1])
        let again = ErrandModel.read(after: [claims[0]], shown: shown, url: "https://p.test/httpx", kept: first.facts,
                                     said: first.statements, asked: ["r1"], read: 2)
        XCTAssertEqual(again.statements.map(\.text), ["Released on Dec 6, 2024.", "Version 0.28.1."])
        XCTAssertEqual(again.statements.map(\.read), [1, 2])
    }

    /// The facts come back whole; a record saved before facts were kept
    /// still reads, with none.
    func testFactsRoundTripAndARecordSavedBeforeThemStillReads() throws {
        var record = ErrandRecord(errandID: errand, goal: "Find 10 jokes")
        record.facts = [.init(requirements: ["r1"], quote: "Joke 1", source: "main/:2", url: "https://a.test/"),
                        .init(requirements: [], quote: "Six jokes", source: "main/:1", url: "https://a.test/")]
        XCTAssertEqual(try JSONDecoder().decode(ErrandRecord.self, from: JSONEncoder().encode(record)), record)
        let before = #"{"errandID":"\#(UUID().uuidString)","goal":"g","steps":[],"rows":[]}"#
        XCTAssertEqual(try JSONDecoder().decode(ErrandRecord.self, from: Data(before.utf8)).facts, [])
    }
}
