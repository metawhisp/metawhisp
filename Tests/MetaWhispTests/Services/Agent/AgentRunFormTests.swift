import XCTest
@testable import MetaWhisp

/// ITER-076 stage 7 — "request a demo on site X": the agent fills the demo
/// form from the user's own details and sends it only after the user's Yes
/// on exactly the values it showed. Two questions for a whole form — Fill,
/// then Send; nothing typed before Fill, nothing sent before Send; a value
/// the site changes after the Yes is never sent; a field the page marks
/// secret is never typed into; nothing after Stop.
@MainActor
final class AgentRunFormTests: XCTestCase {

    private static let goal = "Request a demo on site four forty"

    private static func plan(_ goal: String = goal) throws -> AgentPlan {
        try XCTUnwrap(AgentPlan(goal: goal, requirements: [.init(id: "r1", text: "Request the demo", kind: .action)],
                                answerExpected: false))
    }

    /// The user's details: name, company and work e-mail told to MetaChat —
    /// no phone — and the Pro account's e-mail beside them.
    private static let facts = FormFacts.collect(memories: [
        .init(content: "My name is Sam Example", toldMetaChat: true, createdAt: Date(timeIntervalSince1970: 3)),
        .init(content: "I work at AcmeCorp", toldMetaChat: true, createdAt: Date(timeIntervalSince1970: 2)),
        .init(content: "My work email is sam@example.test", toldMetaChat: true, createdAt: Date(timeIntervalSince1970: 1)),
    ], proEmail: "sam.pro@example.test")

    private static let message = "We would like a demo for our team."

    /// The text model: one sub-goal, then done. Text 16 writes each field
    /// from the details by its label — nothing for one it was not told of;
    /// text 4 writes the message. The verifier says done. Each answer says
    /// `costUSD`.
    private nonisolated static func model(_ written: [String: String] = ["First name": "Sam", "Last name": "Example",
                                                               "Company": "AcmeCorp", "Full name": "Sam Example"],
                                          costUSD: Double? = 0.0002)
        -> RecordedModel {
        RecordedModel(costUSD: costUSD) { asked, n in
            switch asked.purpose {
            case "subgoal": return n < 1 ? .calls([RecordedModel.goal("Fill in and send the demo form")]) : .text("Done.")
            case "field_text":
                guard asked.contents.first == ModelTexts.formFieldText else {
                    return .text(#"{"text": "\#(message)"}"#)
                }
                let input = (try? JSONSerialization.jsonObject(with: Data(((asked.contents.last ?? nil) ?? "").utf8)))
                    as? [String: Any]
                let label = (input?["field"] as? [String: Any])?["label"] as? String ?? ""
                return .text(written[label].map { #"{"text": "\#($0)"}"# } ?? #"{"text": null}"#)
            case "verify": return RecordedModel.verdict(complete: true)
            default: return .status(400)
            }
        }
    }

    /// Jev types in `field` while it is empty, then clicks `send`, then says
    /// DONE; every risk answer: reversible, no grant.
    private nonisolated static func jev(field: String = "First name", send: String = "Request a demo",
                                        grant: @escaping @Sendable (AgentAction) -> Double? = { _ in 0.0 })
        -> ScriptedEngine {
        ScriptedEngine(choice: { request in
            let candidates = request.candidates
            if let type = candidates.first(where: {
                $0.action.operation == .type && $0.action.target?.name == field && ($0.action.target?.value ?? "").isEmpty
            }) {
                return ScriptedEngine.pick(type)
            }
            if let click = candidates.first(where: { $0.action.operation == .click && $0.action.target?.name == send }) {
                return ScriptedEngine.pick(click)
            }
            return ScriptedEngine.pick(candidates.first { $0.action.operation == .done })
        }, grant: grant)
    }

    /// The fixture browser, whose tab stays open when the run closes it, to
    /// read what the page holds once the run is over.
    @MainActor
    final class FormTab: BrowserBridge {
        let inner = WebViewBridge()
        private(set) var tab: BrowserTab?
        /// Runs before each script the run sends; true stops that script.
        var before: (@MainActor (String) -> Bool)?

        func openTab(_ url: URL) async throws -> BrowserTab {
            let opened = try await inner.openTab(url)
            tab = opened
            return opened
        }
        func isLoading(_ tab: BrowserTab) async throws -> Bool { try await inner.isLoading(tab) }
        func closeTab(_ tab: BrowserTab) async throws {}
        func run(_ javascript: String, in tab: BrowserTab) async throws -> String {
            if before?(javascript) == true { throw CancellationError() }
            return try await inner.run(javascript, in: tab)
        }
        func runAwaiting(_ javascript: String, in tab: BrowserTab) async throws -> String {
            try await inner.runAwaiting(javascript, in: tab)
        }
        func holdSends(_ held: Bool, in tab: BrowserTab) async -> Bool { await inner.holdSends(held, in: tab) }
        func letNavigate(to address: String, in tab: BrowserTab) { inner.letNavigate(to: address, in: tab) }
        func events(in tab: BrowserTab) -> [BrowserEvent] { inner.events(in: tab) }

        func read(_ script: String) async throws -> String { try await inner.run(script, in: try XCTUnwrap(tab)) }
        func value(_ id: String) async throws -> String { try await read("document.getElementById('\(id)').value") }
    }

    /// Every question the run asked, in order.
    @MainActor
    final class Questions {
        var asked: [ConfirmationRequest] = []
        var forms: [FormQuestion] { asked.compactMap(\.form) }
    }

    private func run(_ jev: ScriptedEngine = AgentRunFormTests.jev(), model: RecordedModel = AgentRunFormTests.model(),
                     on site: String = "site-440", query: String = "", plan: AgentPlan? = nil,
                     goal: String = goal, facts: FormFacts = facts, bridge: FormTab, questions: Questions,
                     answerWindow: Duration = .seconds(ConfirmationRequest.answerWindow),
                     waitForUser: @escaping @MainActor @Sendable (ErrandHandover, BrowserTab, Duration) async -> Bool = {
                         _, _, _ in false
                     },
                     answer: @escaping @MainActor (ConfirmationRequest, Int) async -> ConfirmationRequest.Answer?)
        throws -> AgentRun {
        AgentRun(goal: goal, planner: try FixedPlanner(plan: plan ?? Self.plan(goal)), errandID: UUID(),
                 collaborators: .init(bridge: bridge, engine: jev, writer: nil, sheet: nil, confirm: { request in
                     questions.asked.append(request)
                     return await answer(request, questions.asked.count - 1)
                 }, log: { _ in }, model: model.model, waitForUser: waitForUser, facts: { facts }),
                 answerWindow: answerWindow, startPage: URL(string: "https://\(site).test/\(query)")!)
    }

    private func fieldValues(_ bridge: FormTab, _ ids: [String]) async throws -> [String] {
        var values: [String] = []
        for id in ids { values.append(try await bridge.value(id)) }
        return values
    }

    // MARK: - Fill, then Send: two questions

    /// A six-field demo form asks exactly two questions — Fill, then Send —
    /// with every field's value and where it came from: the details by code
    /// or by text 16, the message by text 4, a phone no detail holds left
    /// empty. Sent, it ends "sent" with the page the site showed after.
    func testASixFieldFormAsksExactlyTwoQuestionsFillThenSend() async throws {
        let bridge = FormTab()
        let questions = Questions()
        let model = Self.model()
        let run = try run(model: model, bridge: bridge, questions: questions) { _, _ in .yes }
        let outcome = await run.run(report: { _ in })

        XCTAssertEqual(questions.asked.count, 2, "\(run.record.eventLines)")
        XCTAssertEqual(questions.forms.map(\.kind), [.fill, .send])
        let rows: [FormRow] = [
            FormRow(label: "First name", shown: .value("Sam", .memories, unsure: false)),
            FormRow(label: "Last name", shown: .value("Example", .memories, unsure: false)),
            FormRow(label: "Work email", shown: .value("sam@example.test", .memories, unsure: false)),
            FormRow(label: "Company", shown: .value("AcmeCorp", .memories, unsure: false)),
            FormRow(label: "Phone", shown: .notKnown),
            FormRow(label: "How can we help?", shown: .value(Self.message, .request, unsure: false)),
        ]
        XCTAssertEqual(questions.forms.first?.rows, rows)
        XCTAssertEqual(questions.forms.first?.host, "site-440.test")
        XCTAssertNil(questions.forms.first?.destination, "the form sends to its own site")
        XCTAssertEqual(questions.forms.last?.rows, rows, "the Send shows the values the page holds")
        XCTAssertEqual(questions.forms.last?.changed, false)
        XCTAssertEqual(questions.asked.first?.action.operation, .type)
        XCTAssertEqual(questions.asked.last?.action.target?.name, "Request a demo")

        XCTAssertEqual(outcome.ending, .done)
        XCTAssertEqual(outcome.form, FormEnding(kind: .sent, host: "site-440.test",
                                                kinds: ["first name", "last name", "email", "company", "message"],
                                                labels: ["First name", "Last name", "Work email", "Company",
                                                         "How can we help?"],
                                                url: "https://site-440.test/thanks"))
        XCTAssertEqual(outcome.sources, [URL(string: "https://site-440.test/thanks")!])
        let path = try await bridge.read("location.pathname")
        XCTAssertEqual(path, "/thanks", "the form was sent")

        // Text 16 wrote the fields with the details; text 4 the message; code
        // the e-mail — no call for it.
        let written = model.requests("field_text")
        XCTAssertEqual(written.filter { $0.contents.first == ModelTexts.formFieldText }.count, 3)
        XCTAssertEqual(written.filter { $0.contents.first == ModelTexts.fieldText }.count, 1)
        XCTAssertTrue(written.filter { $0.contents.first == ModelTexts.formFieldText }.allSatisfy {
            (($0.contents.last ?? nil) ?? "").contains(#""details": ["My name is Sam Example", "I work at AcmeCorp", "My work email is sam@example.test", "sam.pro@example.test"]"#)
        })
        // The record keeps no value, and the steps are the Fill's typing and
        // the Send's click, each with the user's Yes.
        let kept = String(decoding: try JSONEncoder().encode(run.record), as: UTF8.self)
        for value in ["Sam", "AcmeCorp", "sam@example.test", Self.message] {
            XCTAssertFalse(kept.contains(value), "the record holds \(value)")
        }
        XCTAssertEqual(run.record.steps.map { "\($0.operation) \($0.outcome.rawValue)" },
                       Array(repeating: "type confirmed", count: 5) + ["click confirmed"], "\(run.record.eventLines)")
    }

    /// ITER-076 stage 10b — a form's field texts reserve the worst case of
    /// their own requests, text 16's and text 4's alike, as every call of the
    /// text model does: a server that says no cost counts exactly that.
    func testAFormsFieldTextsReserveTheWorstCaseOfTheirOwnRequests() async throws {
        let bridge = FormTab()
        let questions = Questions()
        let model = Self.model(costUSD: nil)
        let run = try run(model: model, bridge: bridge, questions: questions) { _, _ in .yes }
        let outcome = await run.run(report: { _ in })
        XCTAssertEqual(outcome.ending, .done, "\(run.record.eventLines)")
        let written = model.requests("field_text")
        XCTAssertEqual(written.filter { $0.contents.first == ModelTexts.formFieldText }.count, 3, "the premise: text 16")
        XCTAssertEqual(written.filter { $0.contents.first == ModelTexts.fieldText }.count, 1, "the premise: text 4")
        let costs = RecordedModel.costs(on: run.record, plan: false)
        XCTAssertEqual(costs.count, model.worstCases.count)
        for (index, (cost, worst)) in zip(costs, model.worstCases).enumerated() {
            XCTAssertEqual(cost, worst, accuracy: 1e-6, "call \(index), \(model.requests[index].purpose)")
        }
    }

    /// A No to Fill ends the errand: nothing was typed into the form.
    func testANoToFillTypesNothing() async throws {
        let bridge = FormTab()
        let questions = Questions()
        let run = try run(bridge: bridge, questions: questions) { _, _ in .no }
        let outcome = await run.run(report: { _ in })
        XCTAssertEqual(questions.forms.map(\.kind), [.fill])
        XCTAssertEqual(outcome.ending, .stopped)
        XCTAssertEqual(outcome.form, FormEnding(kind: .notFilled, host: "site-440.test"))
        let values = try await fieldValues(bridge, ["first", "last", "email", "company", "phone", "message"])
        XCTAssertEqual(values, ["", "", "", "", "", ""])
        XCTAssertFalse(run.record.steps.contains { $0.operation == "type" && $0.outcome != .refused })
    }

    /// A No to Send leaves the form filled, never sent.
    func testANoToSendLeavesTheFormFilledNotSent() async throws {
        let bridge = FormTab()
        let questions = Questions()
        let run = try run(bridge: bridge, questions: questions) { request, _ in request.form?.kind == .fill ? .yes : .no }
        let outcome = await run.run(report: { _ in })
        XCTAssertEqual(questions.forms.map(\.kind), [.fill, .send])
        XCTAssertEqual(outcome.ending, .stopped)
        XCTAssertEqual(outcome.form, FormEnding(kind: .notSent, host: "site-440.test"))
        let values = try await fieldValues(bridge, ["first", "email", "company"])
        XCTAssertEqual(values, ["Sam", "sam@example.test", "AcmeCorp"])
        let path = try await bridge.read("location.pathname")
        XCTAssertEqual(path, "/", "not sent")
    }

    /// Two minutes of silence to Send is No: not sent.
    func testSilenceToSendIsNoAndNothingIsSent() async throws {
        let bridge = FormTab()
        let questions = Questions()
        let run = try run(bridge: bridge, questions: questions, answerWindow: .milliseconds(300)) { request, _ in
            guard request.form?.kind == .send else { return .yes }
            try? await Task.sleep(for: .seconds(2))
            return .yes
        }
        let outcome = await run.run(report: { _ in })
        XCTAssertEqual(outcome.form, FormEnding(kind: .notSent, host: "site-440.test", silence: true))
        let path = try await bridge.read("location.pathname")
        XCTAssertEqual(path, "/", "not sent")
    }

    // MARK: - The Yes is bound to the values

    /// The site changes a value while the Send waits: the Yes is void, the
    /// question is asked once more saying so; changed again, the errand ends
    /// — the form was never sent.
    func testAValueTheSiteKeepsChangingIsNeverSent() async throws {
        let bridge = FormTab()
        let questions = Questions()
        var boundScripts = 0
        bridge.before = { script in
            if script.contains(#""boundValues":["#) { boundScripts += 1 }
            return false
        }
        let run = try run(bridge: bridge, questions: questions) { request, number in
            if request.form?.kind == .send {
                _ = try? await bridge.read("document.getElementById('company').value = 'Other Corp \(number)'; 'ok'")
            }
            return .yes
        }
        let outcome = await run.run(report: { _ in })
        XCTAssertEqual(questions.forms.map(\.kind), [.fill, .send, .send], "one more ask, no more")
        XCTAssertEqual(questions.forms.map(\.changed), [false, false, true])
        XCTAssertEqual(questions.forms.last?.rows.first { $0.label == "Company" }?.value, "Other Corp 1",
                       "the question asked again shows the value the page holds now")
        XCTAssertEqual(outcome.ending, .needsUser)
        XCTAssertEqual(outcome.form, FormEnding(kind: .keptChanging, host: "site-440.test"))
        let path = try await bridge.read("location.pathname")
        XCTAssertEqual(path, "/", "never sent")
        XCTAssertEqual(boundScripts, 0, "the run's own look voids the Yes: no script bound to the values — a "
                       + "lookup or the click — ever ran: \(run.record.eventLines)")
        XCTAssertFalse(run.record.steps.contains { $0.operation == "click" && $0.outcome == .confirmed })
    }

    /// Stop right as the Send's click goes out: the record says the form's
    /// Send was pressed from that moment, so the errand saved at the Stop
    /// never says only "Stopped.".
    func testFromTheMomentSendIsPressedTheRecordSaysSo() async throws {
        let bridge = FormTab()
        let questions = Questions()
        var made: AgentRun?
        var atThePress: FormEnding??
        bridge.before = { script in
            guard atThePress == nil, script.contains(#""operation":"click""#), script.contains(#""boundValues":["#)
            else { return false }
            atThePress = .some(made?.record.form)
            made?.stop()
            return false
        }
        let run = try run(bridge: bridge, questions: questions) { _, _ in .yes }
        made = run
        let outcome = await run.run(report: { _ in })
        XCTAssertEqual(atThePress, .some(FormEnding(kind: .notConfirmed, host: "site-440.test",
                                                    url: "https://site-440.test/")), "\(run.record.eventLines)")
        XCTAssertEqual(outcome.ending, .stopped)
        XCTAssertNotNil(outcome.form, "never only Stopped once Send was pressed")
    }

    /// Changed once, the value the user then says Yes to is the one sent.
    func testAValueChangedOnceIsAskedAgainAndSentAsTheUserSawIt() async throws {
        let bridge = FormTab()
        let questions = Questions()
        let run = try run(bridge: bridge, questions: questions) { request, number in
            if request.form?.kind == .send, number == 1 {
                _ = try? await bridge.read("document.getElementById('company').value = 'AcmeCorp Labs'; 'ok'")
            }
            return .yes
        }
        let outcome = await run.run(report: { _ in })
        XCTAssertEqual(questions.forms.map(\.kind), [.fill, .send, .send])
        XCTAssertEqual(questions.forms.last?.rows.first { $0.label == "Company" }?.shown,
                       .value("AcmeCorp Labs", .memories, unsure: true), "shown as the page holds it, to check")
        XCTAssertEqual(outcome.form?.kind, .sent)
    }

    /// Send pressed, and the next page still shows the form: not confirmed,
    /// with the page to check — never "sent", never only "Stopped.".
    func testASendTheNextPageDoesNotConfirmEndsNotConfirmed() async throws {
        let bridge = FormTab()
        let questions = Questions()
        let run = try run(bridge: bridge, questions: questions) { request, _ in
            if request.form?.kind == .send {
                _ = try? await bridge.read("document.getElementById('demo').onsubmit = () => false; 'ok'")
            }
            return .yes
        }
        let outcome = await run.run(report: { _ in })
        XCTAssertEqual(questions.forms.map(\.kind), [.fill, .send])
        XCTAssertEqual(outcome.ending, .needsUser)
        XCTAssertEqual(outcome.form, FormEnding(kind: .notConfirmed, host: "site-440.test",
                                                url: "https://site-440.test/"))
        XCTAssertTrue(run.record.steps.contains { $0.operation == "click" && $0.outcome == .confirmed },
                      "Send was pressed: \(run.record.eventLines)")
    }

    /// Owner decision of 2026-10-19: a form that shows what it costs but asks
    /// no card details is no payment — its Send is asked about as any send,
    /// and goes with the Yes.
    func testASendOfAFormThatShowsAnAmountIsSentAfterTheYes() async throws {
        let bridge = FormTab()
        let questions = Questions()
        let run = try run(Self.jev(field: "First name", send: "Book it"), on: "site-447", bridge: bridge,
                          questions: questions) { _, _ in .yes }
        let outcome = await run.run(report: { _ in })
        XCTAssertEqual(questions.forms.map(\.kind), [.fill, .send], "\(run.record.eventLines)")
        XCTAssertFalse(run.record.events.contains(.handover(.payment, host: "site-447.test")), "\(run.record.eventLines)")
        // Sent; the page that came showed no confirmation, which the record says as it would for any form.
        XCTAssertEqual(outcome.form?.kind, .notConfirmed, "\(run.record.eventLines)")
        let path = try await bridge.read("location.pathname")
        XCTAssertEqual(path, "/thanks", "sent with the Yes: \(run.record.eventLines)")
    }

    /// Jev judges the Send a grant: the user's part — never asked about,
    /// never pressed.
    func testASendJevJudgesAGrantIsTheUsersNeverPressed() async throws {
        let bridge = FormTab()
        let questions = Questions()
        let jev = Self.jev(grant: { $0.operation == .click ? 0.9 : 0 })
        let run = try run(jev, bridge: bridge, questions: questions) { _, _ in .yes }
        let outcome = await run.run(report: { _ in })
        XCTAssertEqual(questions.forms.map(\.kind), [.fill], "\(run.record.eventLines)")
        XCTAssertEqual(outcome.ending, .needsUser)
        XCTAssertTrue(run.record.events.contains(.handover(.grant, host: "site-440.test")))
        let path = try await bridge.read("location.pathname")
        XCTAssertEqual(path, "/", "never pressed")
    }

    /// The site sets a field Fill left empty (review round 1, Kimi P2-2): no
    /// approved row says where such a value came from — "written from the
    /// request" would not be true — so it is never sent under a Yes: no Send
    /// is asked, nothing is pressed, and the form is the user's to finish.
    func testAFieldTheSiteSetsAfterFillIsNeverSentUnderASourceThatIsNotItsOwn() async throws {
        let bridge = FormTab()
        let questions = Questions()
        let run = try run(bridge: bridge, questions: questions) { request, _ in
            if request.form?.kind == .fill {
                // The page sets the phone as the message — the Fill's last
                // field — is typed.
                _ = try? await bridge.read("""
                    document.getElementById('message').addEventListener('input', () => setTimeout(() => {
                      document.getElementById('phone').value = '+1 555 010 0100';
                    }, 0)); 'ok'
                    """)
            }
            return .yes
        }
        let outcome = await run.run(report: { _ in })
        XCTAssertEqual(questions.forms.map(\.kind), [.fill], "\(run.record.eventLines)")
        XCTAssertEqual(outcome.ending, .needsUser)
        XCTAssertNil(outcome.form, "the errand's own line: the user finishes that step")
        let path = try await bridge.read("location.pathname")
        XCTAssertEqual(path, "/", "never sent")
    }

    /// Review round 1, C5: a box the form now sends ticked — no approved row
    /// shows a box — is never sent under a Yes that did not show it: no Send
    /// is asked, nothing is pressed.
    func testABoxTheFormSendsTickedIsNeverSentUnderAYesThatDidNotShowIt() async throws {
        let bridge = FormTab()
        let questions = Questions()
        let run = try run(Self.jev(field: "First name", send: "Get my demo"), on: "site-443", bridge: bridge,
                          questions: questions) { request, _ in
            if request.form?.kind == .fill {
                _ = try? await bridge.read("document.getElementById('agree').checked = true; 'ok'")
            }
            return .yes
        }
        let outcome = await run.run(report: { _ in })
        XCTAssertEqual(questions.forms.map(\.kind), [.fill], "\(run.record.eventLines)")
        XCTAssertEqual(outcome.ending, .needsUser)
        XCTAssertNil(outcome.form)
        let path = try await bridge.read("location.pathname")
        XCTAssertEqual(path, "/", "never sent")
    }

    /// Review round 1, C5: a list the form now sends a choice of — no
    /// approved row shows a choice — is never sent under a Yes that did not
    /// show it.
    func testAChoiceTheFormSendsIsNeverSentUnderAYesThatDidNotShowIt() async throws {
        let bridge = FormTab()
        let questions = Questions()
        let run = try run(Self.jev(field: "First name", send: "Get my demo"), on: "site-443", bridge: bridge,
                          questions: questions) { request, _ in
            if request.form?.kind == .fill {
                _ = try? await bridge.read("document.getElementById('country').selectedIndex = 1; 'ok'")
            }
            return .yes
        }
        let outcome = await run.run(report: { _ in })
        XCTAssertEqual(questions.forms.map(\.kind), [.fill], "\(run.record.eventLines)")
        XCTAssertEqual(outcome.ending, .needsUser)
        XCTAssertNil(outcome.form)
        let path = try await bridge.read("location.pathname")
        XCTAssertEqual(path, "/", "never sent")
    }

    /// Review round 1, C7: the form comes to carry an OAuth request — hidden
    /// fields the page adds while the Send waits — so its Send grants access:
    /// the user's part, never pressed, even after the Yes.
    func testAGrantTheFormGainsWhileTheSendWaitsIsNeverPressed() async throws {
        let bridge = FormTab()
        let questions = Questions()
        let run = try run(bridge: bridge, questions: questions) { request, _ in
            if request.form?.kind == .send {
                _ = try? await bridge.read("""
                    for (const [name, value] of [['client_id', 'app'], ['redirect_uri', 'https://site-440.test/back']]) {
                      const field = document.createElement('input');
                      field.type = 'hidden';
                      field.name = name;
                      field.value = value;
                      document.getElementById('demo').appendChild(field);
                    }
                    'ok'
                    """)
            }
            return .yes
        }
        let outcome = await run.run(report: { _ in })
        XCTAssertEqual(outcome.ending, .needsUser, "\(run.record.eventLines)")
        XCTAssertTrue(run.record.events.contains(.handover(.grant, host: "site-440.test")), "\(run.record.eventLines)")
        let path = try await bridge.read("location.pathname")
        XCTAssertEqual(path, "/", "never pressed")
    }

    /// Review round 1, C8: the Send names the site the button pressed sends
    /// to — its own destination, set apart from its form's.
    func testASendButtonThatSendsElsewhereNamesThatSite() async throws {
        let bridge = FormTab()
        let questions = Questions()
        let run = try run(Self.jev(field: "First name", send: "Request a demo"), on: "site-455", bridge: bridge,
                          questions: questions) { request, _ in request.form?.kind == .fill ? .yes : .no }
        _ = await run.run(report: { _ in })
        XCTAssertEqual(questions.forms.map(\.kind), [.fill, .send], "\(run.record.eventLines)")
        XCTAssertNil(questions.forms.first?.destination, "the form is set to send to its own site")
        XCTAssertEqual(questions.forms.last?.destination, "collect.example.net")
    }

    /// Review round 1, C9: a form sent by GET carries what it held in the
    /// next page's address — values the site changed after Fill and the
    /// user then said Yes to as well: none of them reaches the record or the
    /// link MetaChat shows.
    func testThePageAfterAGetSendKeepsNoValueTheSendShowed() async throws {
        let bridge = FormTab()
        let questions = Questions()
        let run = try run(Self.jev(field: "Full name", send: "Request a demo"), on: "site-456", bridge: bridge,
                          questions: questions) { request, number in
            if request.form?.kind == .send, number == 1 {
                _ = try? await bridge.read("""
                    document.getElementById('name').value = 'Alex Example';
                    document.getElementById('email').value = 'alex@example.test';
                    'ok'
                    """)
            }
            return .yes
        }
        let outcome = await run.run(report: { _ in })
        XCTAssertEqual(questions.forms.map(\.kind), [.fill, .send, .send], "\(run.record.eventLines)")
        XCTAssertEqual(questions.forms.last?.rows.compactMap(\.value), ["Alex Example", "alex@example.test"])
        let address = try await bridge.read("location.href")
        XCTAssertTrue(address.contains("alex"), "sent by GET with what the user said Yes to: \(address)")
        XCTAssertEqual(outcome.form?.kind, .sent)
        XCTAssertEqual(outcome.form?.url, "https://site-456.test/thanks")
        XCTAssertEqual(outcome.sources, [URL(string: "https://site-456.test/thanks")!])
        let kept = String(decoding: try JSONEncoder().encode(run.record), as: UTF8.self)
        XCTAssertFalse(kept.lowercased().contains("alex"), "the record holds a value the form sent")
    }

    // MARK: - Review round 1: the whole form, and only its own Send

    /// C1: a demo form whose e-mail and web address the site filled in
    /// itself, beside one empty field, is still one form of the user's
    /// details: one Fill that shows every field — the site's e-mail replaced
    /// by the user's own, a web address no detail holds left empty — then the
    /// Send, showing the same; no field is ever typed on its own around them.
    func testAFormWithAnEmailTheSiteFilledBesideOneEmptyFieldIsPreviewedWhole() async throws {
        let bridge = FormTab()
        let questions = Questions()
        var atTheSend: [String] = []
        let run = try run(Self.jev(field: "Full name", send: "Request a demo"), on: "site-449", bridge: bridge,
                          questions: questions) { request, _ in
            guard request.form?.kind == .send else { return .yes }
            atTheSend = (try? await self.fieldValues(bridge, ["name", "email", "site"])) ?? []
            return .no
        }
        let outcome = await run.run(report: { _ in })
        XCTAssertEqual(questions.forms.map(\.kind), [.fill, .send], "\(run.record.eventLines)")
        let rows = [
            FormRow(label: "Full name", shown: .value("Sam Example", .memories, unsure: false)),
            FormRow(label: "Work email", shown: .value("sam@example.test", .memories, unsure: false)),
            FormRow(label: "Website", shown: .notKnown),
        ]
        XCTAssertEqual(questions.forms.first?.rows, rows)
        XCTAssertEqual(questions.forms.last?.rows, rows)
        XCTAssertEqual(atTheSend, ["Sam Example", "sam@example.test", ""])
        XCTAssertFalse(questions.asked.contains { $0.form == nil }, "no question outside the form's two")
        XCTAssertEqual(outcome.form, FormEnding(kind: .notSent, host: "site-449.test"))
    }

    /// C2: a form whose own script sends it as a field is typed in never goes
    /// out before the Send's Yes: what it sends is held back, and the form is
    /// the user's to finish.
    func testAFormItsOwnScriptSendsAsItIsTypedInIsNeverSentBeforeTheSendsYes() async throws {
        let bridge = FormTab()
        let questions = Questions()
        let run = try run(on: "site-450", bridge: bridge, questions: questions) { _, _ in .yes }
        let outcome = await run.run(report: { _ in })
        XCTAssertEqual(questions.forms.map(\.kind), [.fill], "\(run.record.eventLines)")
        let path = try await bridge.read("location.pathname")
        XCTAssertEqual(path, "/", "never sent")
        XCTAssertEqual(outcome.ending, .needsUser)
        XCTAssertNil(outcome.form)
        // The errand over, the tab's sends are its own again: the form the
        // user sends goes out.
        _ = try await bridge.read("document.getElementById('demo').submit(); 'ok'")
        try await bridge.inner.waitForURL(URL(string: "https://site-450.test/thanks")!, in: try XCTUnwrap(bridge.tab))
    }

    /// C2: the user's part met while a form is filled — the form came to hold
    /// a password, filled in, so typing in it could send it: a sign-in (an
    /// empty one sends none, 2026-10-21) — gets the tab with its sends free:
    /// what the user sends there goes out.
    func testTheUsersPartAfterFillHasTheTabsSendsFree() async throws {
        let bridge = FormTab()
        let questions = Questions()
        let seen = Seen()
        let run = try run(bridge: bridge, questions: questions, waitForUser: { _, tab, _ in
            _ = try? await bridge.read("document.getElementById('demo').submit(); 'ok'")
            try? await bridge.inner.waitForURL(URL(string: "https://site-440.test/thanks")!, in: tab,
                                               timeout: .seconds(3))
            seen.path = (try? await bridge.read("location.pathname")) ?? ""
            return false
        }) { request, _ in
            if request.form?.kind == .fill {
                _ = try? await bridge.read("""
                    const pass = document.createElement('input');
                    pass.type = 'password';
                    pass.name = 'pass';
                    pass.value = 'demo-pass-40';
                    document.getElementById('demo').appendChild(pass);
                    'ok'
                    """)
            }
            return .yes
        }
        _ = await run.run(report: { _ in })
        XCTAssertTrue(run.record.events.contains(.handover(.signIn, host: "site-440.test")), "\(run.record.eventLines)")
        XCTAssertEqual(seen.path, "/thanks", "the user's own send went out")
    }

    @MainActor
    final class Seen {
        var path = ""
    }

    /// C3: the button changes a value as it is pressed — each press another:
    /// the press finds it changed before the form goes and sends nothing; the
    /// question is asked once more, showing it; changed again, the errand
    /// ends. The form is never sent.
    func testAValueTheButtonChangesAsItIsPressedIsNeverSent() async throws {
        let bridge = FormTab()
        let questions = Questions()
        let run = try run(Self.jev(field: "First name", send: "Request a demo"), on: "site-451", bridge: bridge,
                          questions: questions) { _, _ in .yes }
        let outcome = await run.run(report: { _ in })
        XCTAssertEqual(questions.forms.map(\.kind), [.fill, .send, .send], "\(run.record.eventLines)")
        XCTAssertEqual(questions.forms.last?.changed, true)
        XCTAssertEqual(questions.forms.last?.rows.first { $0.label == "Company" }?.value, "Other Corp 1",
                       "asked again with what the page holds")
        XCTAssertEqual(outcome.form, FormEnding(kind: .keptChanging, host: "site-451.test"))
        let path = try await bridge.read("location.pathname")
        XCTAssertEqual(path, "/", "never sent")
    }

    /// C4: another form's own button — a box of its own fields beside the
    /// filled one — may send that form or, by its script, the filled one:
    /// which is not known. It is never asked about as the filled form's Send,
    /// and never pressed.
    func testAnotherFormsOwnButtonIsNeverAskedUnderTheFilledFormsYes() async throws {
        let bridge = FormTab()
        let questions = Questions()
        let run = try run(Self.jev(field: "Full name", send: "Talk to sales"), on: "site-453", bridge: bridge,
                          questions: questions) { _, _ in .yes }
        _ = await run.run(report: { _ in })
        XCTAssertEqual(questions.forms.map(\.kind), [.fill], "\(run.record.eventLines)")
        XCTAssertTrue(run.record.eventLines.contains { $0.contains("op=click") },
                      "Jev chose the button: \(run.record.eventLines)")
        let demo = try await bridge.read("String(window.demoSent)")
        XCTAssertEqual(demo, "0", "the filled form was never sent")
        let sales = try await bridge.read("String(window.salesSent)")
        XCTAssertEqual(sales, "0", "the button was never pressed")
    }

    /// C4: a button in no form beside the filled form and another the site
    /// put a value in: it may send that value, never shown — never pressed
    /// under the filled form's Yes.
    func testAButtonInNoFormBesideAFormHoldingValuesItNeverShowedIsNeverPressed() async throws {
        let bridge = FormTab()
        let questions = Questions()
        let run = try run(Self.jev(field: "Full name", send: "Send now"), on: "site-454", bridge: bridge,
                          questions: questions) { request, _ in
            if request.form?.kind == .fill {
                _ = try? await bridge.read("document.getElementById('who').value = 'Alex Example'; 'ok'")
            }
            return .yes
        }
        _ = await run.run(report: { _ in })
        XCTAssertEqual(questions.forms.map(\.kind), [.fill], "\(run.record.eventLines)")
        XCTAssertTrue(run.record.eventLines.contains { $0.contains("op=click") },
                      "Jev chose the button: \(run.record.eventLines)")
        let sent = try await bridge.read("String(window.sent)")
        XCTAssertEqual(sent, "0", "never pressed")
    }

    /// C4: a button in no form, beside two filled forms a script gathers:
    /// which of them it sends is not known — it is never asked about as
    /// either's Send, and never pressed.
    func testAButtonInNoFormBesideTwoFilledFormsIsNeverPressed() async throws {
        let bridge = FormTab()
        let questions = Questions()
        let jev = ScriptedEngine(choice: { request in
            let candidates = request.candidates
            for name in ["Full name", "Your name"] {
                if let type = candidates.first(where: {
                    $0.action.operation == .type && $0.action.target?.name == name
                        && ($0.action.target?.value ?? "").isEmpty
                }) {
                    return ScriptedEngine.pick(type)
                }
            }
            if let click = candidates.first(where: { $0.action.operation == .click && $0.action.target?.name == "Send now" }) {
                return ScriptedEngine.pick(click)
            }
            return ScriptedEngine.pick(candidates.first { $0.action.operation == .done })
        })
        let model = Self.model(["Full name": "Sam Example", "Your name": "Sam Example"])
        let run = try run(jev, model: model, on: "site-454", bridge: bridge, questions: questions) { _, _ in .yes }
        _ = await run.run(report: { _ in })
        XCTAssertEqual(questions.forms.map(\.kind), [.fill, .fill], "\(run.record.eventLines)")
        XCTAssertTrue(run.record.eventLines.contains { $0.contains("op=click") },
                      "Jev chose the button: \(run.record.eventLines)")
        let sent = try await bridge.read("String(window.sent)")
        XCTAssertEqual(sent, "0", "never pressed")
    }

    // MARK: - What cannot be filled

    /// Decision 7.1: a required field no detail holds ends the errand before
    /// the preview, naming it; nothing was typed. A street address is never
    /// typed (decision 7.2).
    func testARequiredFieldNoDetailHoldsEndsTheErrandNamingIt() async throws {
        let bridge = FormTab()
        let questions = Questions()
        let run = try run(Self.jev(field: "Full name", send: "Contact sales"), on: "site-445", bridge: bridge,
                          questions: questions) { _, _ in .yes }
        let outcome = await run.run(report: { _ in })
        XCTAssertTrue(questions.asked.isEmpty, "no preview")
        XCTAssertEqual(outcome.ending, .needsUser)
        XCTAssertEqual(outcome.form, FormEnding(kind: .detailsMissing, host: "site-445.test", labels: ["Phone"]))
        let values = try await fieldValues(bridge, ["name", "email", "phone", "street"])
        XCTAssertEqual(values, ["", "", "", ""])
    }

    /// A form with a field the page marks secret, filled in, could send it:
    /// the form is the user's — no field of it is typed into, and no preview
    /// is asked.
    func testAFormWithASecretFieldIsTheUsersAndNothingIsTyped() async throws {
        let bridge = FormTab()
        let questions = Questions()
        let run = try run(Self.jev(field: "Full name", send: "Create account"), on: "site-444", query: "?filled",
                          bridge: bridge, questions: questions) { _, _ in .yes }
        let outcome = await run.run(report: { _ in })
        XCTAssertTrue(questions.asked.isEmpty)
        XCTAssertEqual(outcome.ending, .needsUser)
        XCTAssertTrue(run.record.events.contains(.handover(.signIn, host: "site-444.test")), "\(run.record.eventLines)")
        let values = try await fieldValues(bridge, ["name", "email", "pass"])
        XCTAssertEqual(values, ["", "", "account-pass-44"], "nothing typed, the password as the page left it")
    }

    /// Empty, that field sends nothing (owner decision 4; 2026-10-20, a blind
    /// errand stopped at a practice form's first field): the rest of the form
    /// is previewed, filled with one Yes and sent with the next. The password
    /// is in no row and never typed: it is withheld.
    func testAFormWhoseSecretFieldIsEmptyIsFilledAndThePasswordIsNeverTyped() async throws {
        let bridge = FormTab()
        let questions = Questions()
        var atTheSend: [String] = []
        let run = try run(Self.jev(field: "Full name", send: "Create account"), on: "site-444", bridge: bridge,
                          questions: questions) { request, _ in
            if request.form?.kind == .send {
                atTheSend = (try? await self.fieldValues(bridge, ["name", "email", "pass"])) ?? []
            }
            return .yes
        }
        let outcome = await run.run(report: { _ in })
        XCTAssertFalse(run.record.events.contains(.handover(.signIn, host: "site-444.test")), "\(run.record.eventLines)")
        XCTAssertEqual(questions.forms.map(\.kind), [.fill, .send], "\(run.record.eventLines)")
        XCTAssertEqual(questions.forms.first?.rows.map(\.label), ["Full name", "Email"])
        XCTAssertEqual(questions.forms.last?.rows.map(\.label), ["Full name", "Email"])
        XCTAssertEqual(atTheSend, ["Sam Example", "sam@example.test", ""])
        XCTAssertEqual(outcome.form?.kind, .sent, "\(run.record.eventLines)")
    }

    /// A sign-up that needs its password (`required`) and holds it empty (2026-10-21): the rest of the form is
    /// previewed and filled with one Yes, and its send is the user's sign-in, handed over before the Send question.
    /// Nothing is sent, and the password is never typed.
    func testAFormThatNeedsItsEmptyPasswordIsFilledThenItsSendIsTheUsersSignIn() async throws {
        let bridge = FormTab()
        let questions = Questions()
        let run = try run(Self.jev(field: "Full name", send: "Create account"), on: "site-444", query: "?required",
                          bridge: bridge, questions: questions) { _, _ in .yes }
        _ = await run.run(report: { _ in })
        XCTAssertEqual(questions.forms.map(\.kind), [.fill], "\(run.record.eventLines)")
        XCTAssertTrue(run.record.events.contains(.handover(.signIn, host: "site-444.test")), "\(run.record.eventLines)")
        let values = try await fieldValues(bridge, ["name", "email", "pass"])
        XCTAssertEqual(values, ["Sam Example", "sam@example.test", ""])
        let path = try await bridge.read("location.pathname")
        XCTAssertEqual(path, "/", "never sent")
    }

    /// The form came to need its password while the Send question waited (`required` since it was asked): on the page
    /// the Yes came on, the press is the user's sign-in, and nothing is sent.
    func testAPasswordTheFormCameToNeedWhileItsSendWaitedIsTheUsersSignIn() async throws {
        let bridge = FormTab()
        let questions = Questions()
        let run = try run(Self.jev(field: "Full name", send: "Create account"), on: "site-444", bridge: bridge,
                          questions: questions) { request, _ in
            if request.form?.kind == .send {
                _ = try? await bridge.read("document.getElementById('pass').required = true; 'ok'")
            }
            return .yes
        }
        _ = await run.run(report: { _ in })
        XCTAssertEqual(questions.forms.map(\.kind), [.fill, .send], "\(run.record.eventLines)")
        XCTAssertTrue(run.record.events.contains(.handover(.signIn, host: "site-444.test")), "\(run.record.eventLines)")
        let path = try await bridge.read("location.pathname")
        XCTAssertEqual(path, "/", "never sent")
    }

    /// A press of a form no Fill filled — the practice form's submit, asked about as any send — whose password the
    /// form came to need while the Yes waited: on the page the Yes came on, the press is the user's sign-in, and
    /// nothing is sent (2026-10-21).
    func testAPasswordAFormCameToNeedWhileItsYesWaitedIsTheUsersSignIn() async throws {
        let bridge = FormTab()
        let questions = Questions()
        let run = try run(Self.jev(field: "No such field", send: "submit"), on: "site-497", bridge: bridge,
                          questions: questions) { request, _ in
            if request.form == nil, request.action.target?.name == "submit" {
                _ = try? await bridge.read("document.getElementById('password').required = true; 'ok'")
            }
            return .yes
        }
        _ = await run.run(report: { _ in })
        XCTAssertEqual(questions.asked.count, 1, "\(run.record.eventLines)")
        XCTAssertTrue(run.record.events.contains(.handover(.signIn, host: "site-497.test")), "\(run.record.eventLines)")
        XCTAssertFalse(bridge.inner.navigatedURLs.contains { $0.path == "/submit" }, "\(run.record.eventLines)")
    }

    /// A search of two fields is no form of the user's details: no preview.
    func testATwoFieldSearchGetsNoPreview() async throws {
        let bridge = FormTab()
        let questions = Questions()
        let run = try run(Self.jev(field: "From", send: "Search flights"), on: "site-446",
                          goal: "Find flights from Berlin", bridge: bridge, questions: questions) { _, _ in .no }
        _ = await run.run(report: { _ in })
        XCTAssertTrue(questions.forms.isEmpty, "\(run.record.eventLines)")
    }

    // MARK: - A form without a form tag

    /// A demo form a script gathers without a form tag, as a React page
    /// draws one, is previewed, filled and sent by its own button.
    func testAFormWithoutAFormTagIsFilledAndSent() async throws {
        let bridge = FormTab()
        let questions = Questions()
        let run = try run(Self.jev(field: "Full name", send: "Book my demo"), on: "site-441", bridge: bridge,
                          questions: questions) { _, _ in .yes }
        let outcome = await run.run(report: { _ in })
        XCTAssertEqual(questions.forms.map(\.kind), [.fill, .send], "\(run.record.eventLines)")
        XCTAssertEqual(questions.forms.first?.rows.map(\.label), ["Full name", "Email", "Company", "Message"])
        let sent = try await bridge.read("String(window.sent)")
        XCTAssertEqual(sent, "1")
        let values = try await bridge.read("JSON.stringify(window.sentValues)")
        XCTAssertEqual(values, #"["Sam Example","sam@example.test","AcmeCorp","\#(Self.message)"]"#)
        XCTAssertEqual(outcome.form?.kind, .sent)
        XCTAssertEqual(outcome.form?.kinds, ["name", "email", "message"], "the company's field names no kind")
    }

    /// A button outside the box that holds a formless form's fields — in no
    /// group of theirs — may still send them by its script: its click asks
    /// the Yes bound to the values, never goes on Jev's word alone (№ 93).
    func testAButtonOutsideAFormlessFormsBoxStillAsksTheBoundSend() async throws {
        let bridge = FormTab()
        let questions = Questions()
        let run = try run(Self.jev(field: "Full name", send: "Send request"), on: "site-448", bridge: bridge,
                          questions: questions) { request, _ in request.form?.kind == .fill ? .yes : .no }
        let outcome = await run.run(report: { _ in })
        XCTAssertEqual(questions.forms.map(\.kind), [.fill, .send], "\(run.record.eventLines)")
        XCTAssertEqual(outcome.form, FormEnding(kind: .notSent, host: "site-448.test"))
        let sent = try await bridge.read("String(window.sent)")
        XCTAssertEqual(sent, "0", "never sent without the Yes")
    }

    // MARK: - Stop

    /// Stop during the preview: nothing is typed, and the errand says
    /// "Stopped." as any Stop does.
    func testStopDuringThePreviewTypesNothing() async throws {
        let bridge = FormTab()
        let questions = Questions()
        var made: AgentRun?
        let run = try run(bridge: bridge, questions: questions) { _, _ in
            made?.stop()
            return .yes
        }
        made = run
        let outcome = await run.run(report: { _ in })
        XCTAssertEqual(outcome.ending, .stopped)
        XCTAssertNil(outcome.form)
        let values = try await fieldValues(bridge, ["first", "last", "email", "company", "message"])
        XCTAssertEqual(values, ["", "", "", "", ""])
    }

    /// Stop while the form is being filled: no field is typed into after it.
    func testStopDuringTheFillTypesNothingAfterIt() async throws {
        let bridge = FormTab()
        let questions = Questions()
        var made: AgentRun?
        var typed = 0
        bridge.before = { script in
            guard script.contains(#""operation":"type""#) else { return false }
            typed += 1
            guard typed == 2 else { return false }
            made?.stop()
            return true
        }
        let run = try run(bridge: bridge, questions: questions) { _, _ in .yes }
        made = run
        let outcome = await run.run(report: { _ in })
        XCTAssertEqual(outcome.ending, .stopped)
        let values = try await fieldValues(bridge, ["first", "last", "email", "company", "message"])
        XCTAssertEqual(values, ["Sam", "", "", "", ""])
        XCTAssertEqual(typed, 2, "no type sent after Stop")
    }

    /// Stop pressed between two of the Fill's fields — while the page is
    /// looked at again before the next one: no field is typed after it.
    func testStopBetweenTwoFieldsOfTheFillTypesNothingAfterIt() async throws {
        let bridge = FormTab()
        let questions = Questions()
        var made: AgentRun?
        var typed = 0
        var stoppedAt: Int?
        bridge.before = { script in
            if script.contains(#""operation":"type""#) { typed += 1 }
            if typed == 1, stoppedAt == nil, script == ObserverScript.source {
                stoppedAt = typed
                made?.stop()
            }
            return false
        }
        let run = try run(bridge: bridge, questions: questions) { _, _ in .yes }
        made = run
        let outcome = await run.run(report: { _ in })
        XCTAssertEqual(stoppedAt, 1, "Stop came after the first field")
        XCTAssertEqual(outcome.ending, .stopped)
        XCTAssertEqual(typed, 1, "no type sent after Stop: \(run.record.eventLines)")
        let values = try await fieldValues(bridge, ["first", "last", "email", "company", "message"])
        XCTAssertEqual(values, ["Sam", "", "", "", ""])
    }

    // MARK: - The form's own typing

    /// A field of a previewed form is typed only by its Fill (№ 57): Jev
    /// choosing the field left empty types nothing and writes nothing.
    func testAFieldOfAPreviewedFormIsNeverTypedOnItsOwn() async throws {
        let bridge = FormTab()
        let questions = Questions()
        let model = Self.model()
        var phoneChosen = 0
        let jev = ScriptedEngine(choice: { request in
            let candidates = request.candidates
            if let first = candidates.first(where: {
                $0.action.operation == .type && $0.action.target?.name == "First name" && ($0.action.target?.value ?? "").isEmpty
            }) {
                return ScriptedEngine.pick(first)
            }
            if phoneChosen < 2, let phone = candidates.first(where: {
                $0.action.operation == .type && $0.action.target?.name == "Phone"
            }) {
                phoneChosen += 1
                return ScriptedEngine.pick(phone)
            }
            return ScriptedEngine.pick(candidates.first { $0.action.operation == .done })
        })
        let run = try run(jev, model: model, bridge: bridge, questions: questions) { _, _ in .yes }
        _ = await run.run(report: { _ in })
        XCTAssertEqual(questions.forms.map(\.kind), [.fill], "no question for the phone on its own")
        XCTAssertEqual(model.requests("field_text").count, 4, "the Fill's three texts and its message; none after")
        let phone = try await bridge.value("phone")
        XCTAssertEqual(phone, "")
    }

    // MARK: - The eight-field demo form (№ 225)

    /// A demo form of eight fields — text, a list, a date, a consent box —
    /// filled up to Send, and not sent without the Yes.
    func testTheEightFieldDemoFormIsFilledUpToSendAndNotSentWithoutTheYes() async throws {
        let bridge = FormTab()
        let questions = Questions()
        let run = try run(Self.jev(field: "First name", send: "Get my demo"), on: "site-443", bridge: bridge,
                          questions: questions) { request, _ in request.form?.kind == .fill ? .yes : .no }
        let outcome = await run.run(report: { _ in })
        XCTAssertEqual(questions.forms.map(\.kind), [.fill, .send])
        XCTAssertEqual(questions.forms.first?.rows.map(\.label),
                       ["First name", "Last name", "Work email", "Company", "Phone", "Preferred day"])
        let values = try await fieldValues(bridge, ["first", "last", "email", "company", "phone", "day"])
        XCTAssertEqual(values, ["Sam", "Example", "sam@example.test", "AcmeCorp", "", ""])
        let path = try await bridge.read("location.pathname")
        XCTAssertEqual(path, "/", "not sent without the Yes")
        XCTAssertEqual(outcome.form, FormEnding(kind: .notSent, host: "site-443.test"))
    }

    // MARK: - Review round 2

    /// Jev on a form: types in First name while it is empty, scrolls once,
    /// then clicks `send`, then says DONE.
    nonisolated static func scrollsThenSends(send: String) -> ScriptedEngine {
        let scrolled = Flag()
        return ScriptedEngine(choice: { request in
            let candidates = request.candidates
            if let type = candidates.first(where: {
                $0.action.operation == .type && $0.action.target?.name == "First name"
                    && ($0.action.target?.value ?? "").isEmpty
            }) {
                return ScriptedEngine.pick(type)
            }
            if !scrolled.set(), let scroll = candidates.first(where: { $0.action.operation == .scroll }) {
                return ScriptedEngine.pick(scroll)
            }
            if let click = candidates.first(where: { $0.action.operation == .click && $0.action.target?.name == send }) {
                return ScriptedEngine.pick(click)
            }
            return ScriptedEngine.pick(candidates.first { $0.action.operation == .done })
        })
    }

    /// A flag set once, from any thread: false the first time.
    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var isSet = false

        func set() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            let was = isSet
            isSet = true
            return was
        }
    }

    /// R2-3: a field the site filled, standing alone outside the filled
    /// form's box, beside a button in no form whose script sends it too: it
    /// would go out unshown — the Send is never asked, nothing is pressed.
    func testAFieldOutsideTheFormBesideAButtonInNoFormIsNeverSentUnshown() async throws {
        let bridge = FormTab()
        let questions = Questions()
        let run = try run(Self.jev(field: "Full name", send: "Send request"), on: "site-461", bridge: bridge,
                          questions: questions) { _, _ in .yes }
        let outcome = await run.run(report: { _ in })
        XCTAssertEqual(questions.forms.map(\.kind), [.fill], "\(run.record.eventLines)")
        XCTAssertTrue(run.record.eventLines.contains { $0.contains("op=click") },
                      "Jev chose the button: \(run.record.eventLines)")
        let sent = try await bridge.read("String(window.sent)")
        XCTAssertEqual(sent, "0", "never pressed")
        XCTAssertEqual(outcome.ending, .needsUser)
        XCTAssertNil(outcome.form)
    }

    /// R2-3: a page too big to read whole may hold a control the form sends
    /// that no look reported: its Send is never asked, nothing is pressed.
    func testAFormOnAPageTooBigToReadWholeIsNeverAskedToSend() async throws {
        let bridge = FormTab()
        let questions = Questions()
        let run = try run(bridge: bridge, questions: questions) { request, _ in
            if request.form?.kind == .fill {
                _ = try? await bridge.read("""
                    for (let i = 0; i < 700; i++) {
                      const more = document.createElement('button');
                      more.type = 'button';
                      more.textContent = 'More ' + i;
                      document.body.appendChild(more);
                    }
                    'ok'
                    """)
            }
            return .yes
        }
        let outcome = await run.run(report: { _ in })
        XCTAssertEqual(questions.forms.map(\.kind), [.fill], "\(run.record.eventLines)")
        let path = try await bridge.read("location.pathname")
        XCTAssertEqual(path, "/", "never sent")
        XCTAssertEqual(outcome.ending, .needsUser)
        XCTAssertNil(outcome.form)
    }

    /// R2-3: a list the form sends from outside its tag — joined to it by its
    /// `form` attribute — is the form's: its choice, which no row shows, is
    /// never sent under a Yes that did not show it.
    func testAListTheFormSendsFromOutsideItsTagIsNeverSentUnshown() async throws {
        let bridge = FormTab()
        let questions = Questions()
        let run = try run(Self.jev(field: "First name", send: "Request a demo"), on: "site-464", bridge: bridge,
                          questions: questions) { _, _ in .yes }
        let outcome = await run.run(report: { _ in })
        XCTAssertEqual(questions.forms.map(\.kind), [.fill], "\(run.record.eventLines)")
        let path = try await bridge.read("location.pathname")
        XCTAssertEqual(path, "/", "never sent")
        XCTAssertNil(outcome.form)
    }

    /// R2-4: the site makes a value Fill typed longer than a look holds whole:
    /// the card could show it only cut, while the whole would be bound and
    /// sent — it is never asked about, nothing is pressed.
    func testAValueTheSiteMakesTooLongToShowWholeIsNeverAskedAbout() async throws {
        let bridge = FormTab()
        let questions = Questions()
        let run = try run(bridge: bridge, questions: questions) { request, _ in
            if request.form?.kind == .fill {
                _ = try? await bridge.read("""
                    document.getElementById('message').addEventListener('input', () => setTimeout(() => {
                      document.getElementById('message').value = 'We would like a demo. ' + 'More words. '.repeat(25);
                    }, 0)); 'ok'
                    """)
            }
            return .yes
        }
        let outcome = await run.run(report: { _ in })
        XCTAssertEqual(questions.forms.map(\.kind), [.fill], "\(run.record.eventLines)")
        let path = try await bridge.read("location.pathname")
        XCTAssertEqual(path, "/", "never sent")
        XCTAssertEqual(outcome.ending, .needsUser)
        XCTAssertNil(outcome.form)
    }

    /// R2-5: the site sends the form to an address that holds the e-mail typed
    /// in it — /thanks/<e-mail>: neither the link MetaChat shows nor the
    /// record keeps it.
    func testAnAddressHoldingATypedValueInItsPathIsKeptWithoutIt() async throws {
        let bridge = FormTab()
        let questions = Questions()
        let run = try run(Self.jev(field: "Full name", send: "Request a demo"), on: "site-462", bridge: bridge,
                          questions: questions) { _, _ in .yes }
        let outcome = await run.run(report: { _ in })
        let address = try await bridge.read("location.href")
        XCTAssertTrue(address.contains("sam@example.test"), "sent to the address that holds it: \(address)")
        XCTAssertEqual(outcome.form?.kind, .sent, "\(run.record.eventLines)")
        XCTAssertEqual(outcome.form?.url, "https://site-462.test/thanks")
        XCTAssertEqual(outcome.sources, [URL(string: "https://site-462.test/thanks")!])
        let kept = String(decoding: try JSONEncoder().encode(run.record), as: UTF8.self)
        XCTAssertFalse(kept.lowercased().contains("sam@example.test"), "the record holds the e-mail")
        XCTAssertFalse(kept.lowercased().contains("sam%40example.test"), "the record holds the e-mail")
    }

    /// R2-5: the page writes the e-mail typed in it into its own address; a
    /// page read after Fill keeps its words and its address without it — in
    /// the record, the answer and its sources.
    func testAPageReadAfterFillKeepsNoTypedValueInItsAddress() async throws {
        let bridge = FormTab()
        let questions = Questions()
        let goal = "Request a demo on site four sixty-three and say how long it takes"
        let plan = try XCTUnwrap(AgentPlan(goal: goal, requirements: [
            .init(id: "r1", text: "Request the demo", kind: .action),
            .init(id: "r2", text: "How long a demo takes", kind: .information),
        ], answerExpected: true))
        let model = RecordedModel { asked, n in
            switch asked.purpose {
            case "subgoal": return n < 1 ? .calls([RecordedModel.goal("Fill in the demo form")]) : .text("Done.")
            case "field_text":
                guard asked.contents.first == ModelTexts.formFieldText else { return .text(#"{"text": null}"#) }
                let input = (try? JSONSerialization.jsonObject(with: Data(((asked.contents.last ?? nil) ?? "").utf8)))
                    as? [String: Any]
                let label = (input?["field"] as? [String: Any])?["label"] as? String ?? ""
                return .text(label == "Full name" ? #"{"text": "Sam Example"}"# : #"{"text": null}"#)
            case "read":
                return .text(RecordedModel.reading([RecordedModel.claim(cite: ("main/:1", "main/:2"), requirement: "r2")]))
            case "verify": return RecordedModel.verdict(complete: true)
            default: return .status(400)
            }
        }
        let jev = ScriptedEngine(choice: { request in
            let candidates = request.candidates
            if let type = candidates.first(where: {
                $0.action.operation == .type && $0.action.target?.name == "Full name"
                    && ($0.action.target?.value ?? "").isEmpty
            }) {
                return ScriptedEngine.pick(type)
            }
            return ScriptedEngine.pick(candidates.first { $0.action.operation == .done })
        })
        let run = try run(jev, model: model, on: "site-463", plan: plan, goal: goal, bridge: bridge,
                          questions: questions) { _, _ in .yes }
        let outcome = await run.run(report: { _ in })
        let address = try await bridge.read("location.href")
        XCTAssertTrue(address.contains("sam@example.test"), "the page wrote it into its address: \(address)")
        XCTAssertEqual(questions.forms.map(\.kind), [.fill], "\(run.record.eventLines)")
        XCTAssertFalse(run.record.facts.isEmpty, "the page was read: \(run.record.eventLines)")
        let kept = String(decoding: try JSONEncoder().encode(run.record), as: UTF8.self)
        XCTAssertFalse(kept.lowercased().contains("sam@example.test"), "the record holds the e-mail")
        XCTAssertFalse((outcome.answer ?? "").contains("sam@example.test"))
        XCTAssertFalse(outcome.sources.contains { $0.absoluteString.contains("sam@example.test") }, "\(outcome.sources)")
    }
}
