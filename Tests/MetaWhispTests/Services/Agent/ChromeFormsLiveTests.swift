import Foundation
import XCTest
@testable import MetaWhisp

/// ITER-076 stage 7 (№ 225, 244) — a demo form in a real Chrome (headless, a
/// profile of its own, the fixture pages served from inside Chrome), typed and
/// clicked as a person's input: filled up to Send with one Yes, and sent only
/// with the Yes bound to its values. Skipped without Chrome.
final class ChromeFormsLiveTests: XCTestCase {

    private static let facts = FormFacts.collect(memories: [
        .init(content: "My name is Sam Example", toldMetaChat: true, createdAt: Date(timeIntervalSince1970: 3)),
        .init(content: "I work at AcmeCorp", toldMetaChat: true, createdAt: Date(timeIntervalSince1970: 2)),
        .init(content: "My work email is sam@example.test", toldMetaChat: true, createdAt: Date(timeIntervalSince1970: 1)),
    ], proEmail: "sam.pro@example.test")

    private static let message = "We would like a demo for our team."

    /// The text model: one sub-goal; text 16 writes the names and the
    /// company from the details, text 4 the message.
    private static func model() -> RecordedModel {
        RecordedModel { asked, n in
            switch asked.purpose {
            case "subgoal": return n < 1 ? .calls([RecordedModel.goal("Fill in and send the demo form")]) : .text("Done.")
            case "field_text":
                guard asked.contents.first == ModelTexts.formFieldText else {
                    return .text(#"{"text": "\#(message)"}"#)
                }
                let input = (try? JSONSerialization.jsonObject(with: Data(((asked.contents.last ?? nil) ?? "").utf8)))
                    as? [String: Any]
                let label = (input?["field"] as? [String: Any])?["label"] as? String ?? ""
                let written = ["First name": "Sam", "Last name": "Example", "Company": "AcmeCorp",
                               "Full name": "Sam Example"]
                return .text(written[label].map { #"{"text": "\#($0)"}"# } ?? #"{"text": null}"#)
            case "verify": return RecordedModel.verdict(complete: true)
            default: return .status(400)
            }
        }
    }

    /// Jev types in `field` while it is empty, then clicks `send`.
    private static func jev(field: String, send: String) -> ScriptedEngine {
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
        })
    }

    @MainActor
    private final class Asked {
        var forms: [FormQuestion] = []
    }

    @MainActor
    private func run(on site: String, field: String, send: String, hands: KeepsTheTab, asked: Asked,
                     answer: @escaping @MainActor (FormQuestion) -> ConfirmationRequest.Answer?) throws -> AgentRun {
        try run(on: site, engine: Self.jev(field: field, send: send), hands: hands, asked: asked, answer: answer)
    }

    @MainActor
    private func run(on site: String, engine: ScriptedEngine, hands: KeepsTheTab, asked: Asked,
                     answer: @escaping @MainActor (FormQuestion) -> ConfirmationRequest.Answer?) throws -> AgentRun {
        let goal = "Request a demo on \(site)"
        let plan = try XCTUnwrap(AgentPlan(goal: goal, requirements: [.init(id: "r1", text: "Request the demo",
                                                                            kind: .action)],
                                           answerExpected: false))
        return AgentRun(goal: goal, planner: FixedPlanner(plan: plan), errandID: UUID(),
                        collaborators: .init(bridge: hands, engine: engine, writer: nil,
                                             sheet: nil, confirm: { request in
                                                 guard let form = request.form else { return .no }
                                                 asked.forms.append(form)
                                                 return answer(form)
                                             }, log: { _ in }, model: Self.model().model, facts: { Self.facts }),
                        startPage: URL(string: "https://\(site).test/")!)
    }

    @MainActor
    private func read(_ script: String, in hands: KeepsTheTab, world: ChromeWorld) async throws -> String {
        try await world.bridge.runInPage(script, in: try XCTUnwrap(hands.kept.first))
    }

    /// № 225: the eight-field demo form — text, a list, a date, a consent
    /// box — filled up to Send by a person's typing, and not sent without the
    /// Yes: No to Send, and the form stays on its page, filled.
    @MainActor
    func testTheEightFieldDemoFormIsFilledUpToSendAndNotSentWithoutTheYes() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let hands = KeepsTheTab(world.bridge)
        let asked = Asked()
        let run = try run(on: "site-443", field: "First name", send: "Get my demo", hands: hands, asked: asked) {
            $0.kind == .fill ? .yes : .no
        }
        let outcome = await run.run(report: { _ in })
        XCTAssertEqual(asked.forms.map(\.kind), [.fill, .send], "\(run.record.eventLines)")
        XCTAssertEqual(outcome.form, FormEnding(kind: .notSent, host: "site-443.test"))
        let values = try await read("['first','last','email','company','phone','day'].map((id) => " +
                                    "document.getElementById(id).value).join('|')", in: hands, world: world)
        XCTAssertEqual(values, "Sam|Example|sam@example.test|AcmeCorp||")
        let path = try await read("location.pathname", in: hands, world: world)
        XCTAssertEqual(path, "/", "not sent")
        XCTAssertFalse(world.fixtures.served.contains { $0.path == "/thanks" }, "no request carried the form")
        XCTAssertTrue(world.fixtures.blocked.isEmpty, "\(world.fixtures.blocked)")
    }

    /// With the Yes, the form is sent by a person's click: the site's next
    /// page shows its thanks, and the errand ends sent, with that page.
    @MainActor
    func testTheDemoFormIsSentByAPersonsClickAfterTheYes() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let hands = KeepsTheTab(world.bridge)
        let asked = Asked()
        let run = try run(on: "site-440", field: "First name", send: "Request a demo", hands: hands, asked: asked) { _ in
            .yes
        }
        let outcome = await run.run(report: { _ in })
        XCTAssertEqual(asked.forms.map(\.kind), [.fill, .send], "\(run.record.eventLines)")
        XCTAssertEqual(outcome.form?.kind, .sent, "\(run.record.eventLines)")
        XCTAssertEqual(outcome.form?.url, "https://site-440.test/thanks")
        XCTAssertEqual(outcome.sources, [URL(string: "https://site-440.test/thanks")!])
        let thanks = try await read("document.getElementById('thanks').hidden ? 'no' : 'yes'", in: hands, world: world)
        XCTAssertEqual(thanks, "yes")
        XCTAssertEqual(world.fixtures.served.filter { $0.path == "/thanks" }.count, 1, "sent once")
    }

    /// Review round 1, C1: a demo form whose e-mail and web address the site
    /// filled in itself, beside one empty field, is filled whole by a
    /// person's typing: the site's e-mail replaced by the user's own, the web
    /// address no detail holds emptied — as the preview showed them.
    @MainActor
    func testAFormTheSiteFilledInPartIsFilledWholeAsThePreviewShowedIt() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let hands = KeepsTheTab(world.bridge)
        let asked = Asked()
        let run = try run(on: "site-449", field: "Full name", send: "Request a demo", hands: hands, asked: asked) {
            $0.kind == .fill ? .yes : .no
        }
        _ = await run.run(report: { _ in })
        XCTAssertEqual(asked.forms.map(\.kind), [.fill, .send], "\(run.record.eventLines)")
        XCTAssertEqual(asked.forms.first?.rows.map(\.value), ["Sam Example", "sam@example.test", nil])
        let values = try await read("['name','email','site'].map((id) => document.getElementById(id).value).join('|')",
                                    in: hands, world: world)
        XCTAssertEqual(values, "Sam Example|sam@example.test|")
        XCTAssertFalse(world.fixtures.served.contains { $0.path == "/thanks" }, "not sent without the Yes")
    }

    /// Review round 1, C2: a form whose own script sends it as its e-mail is
    /// typed in — by a person's typing — never goes out before the Send's
    /// Yes: Chrome holds back every document the tab asks for while the form
    /// is filled, and the form is the user's to finish.
    @MainActor
    func testAFormItsOwnScriptSendsAsItIsTypedInNeverGoesOutBeforeTheSendsYes() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let hands = KeepsTheTab(world.bridge)
        let asked = Asked()
        let run = try run(on: "site-450", field: "First name", send: "Request a demo", hands: hands, asked: asked) { _ in
            .yes
        }
        let outcome = await run.run(report: { _ in })
        XCTAssertEqual(asked.forms.map(\.kind), [.fill], "\(run.record.eventLines)")
        XCTAssertFalse(world.fixtures.served.contains { $0.path == "/thanks" }, "no request carried the form")
        let path = try await read("location.pathname", in: hands, world: world)
        XCTAssertEqual(path, "/")
        XCTAssertEqual(outcome.ending, .needsUser)
        XCTAssertNil(outcome.form)
    }

    /// Review round 1, C2, the frames: a form the page sends into a frame of
    /// its own as its e-mail is typed in — a request with a body — is held
    /// back as one sent in its place is.
    @MainActor
    func testAFormSentIntoAFrameAsItIsTypedInNeverGoesOutBeforeTheSendsYes() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let hands = KeepsTheTab(world.bridge)
        let asked = Asked()
        let run = try run(on: "site-458", field: "First name", send: "Request a demo", hands: hands, asked: asked) { _ in
            .yes
        }
        let outcome = await run.run(report: { _ in })
        XCTAssertEqual(asked.forms.map(\.kind), [.fill], "\(run.record.eventLines)")
        XCTAssertFalse(world.fixtures.served.contains { $0.path == "/thanks" }, "no request carried the form")
        XCTAssertEqual(outcome.ending, .needsUser)
    }

    /// Review round 1, C2: what the tab holds back while a form is filled is
    /// what would send it — a frame the page loads meanwhile, a widget as
    /// many sites load, still loads, and the form goes on to its Send.
    @MainActor
    func testAFrameThePageLoadsWhileTheFormIsFilledStillLoads() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let hands = KeepsTheTab(world.bridge)
        let asked = Asked()
        let run = try run(on: "site-457", field: "First name", send: "Request a demo", hands: hands, asked: asked) {
            $0.kind == .fill ? .yes : .no
        }
        let outcome = await run.run(report: { _ in })
        XCTAssertEqual(asked.forms.map(\.kind), [.fill, .send], "\(run.record.eventLines)")
        XCTAssertTrue(world.fixtures.served.contains { $0.host == "site-1.test" }, "the page's frame loaded")
        XCTAssertEqual(outcome.form, FormEnding(kind: .notSent, host: "site-457.test"))
    }

    /// Review round 1, C3 — the race between the last aim and the press,
    /// tried: the Send button changes the company as it goes down, each press
    /// to another value, after every check before the press passed. The
    /// press itself finds the value changed and sends nothing; asked again
    /// with what the page holds, the same: the form never goes out.
    @MainActor
    func testAValueChangedAsTheSendGoesDownIsNeverSent() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let hands = KeepsTheTab(world.bridge)
        let asked = Asked()
        let run = try run(on: "site-451", field: "First name", send: "Request a demo", hands: hands, asked: asked) { _ in
            .yes
        }
        let outcome = await run.run(report: { _ in })
        XCTAssertEqual(asked.forms.map(\.kind), [.fill, .send, .send], "\(run.record.eventLines)")
        XCTAssertEqual(asked.forms.last?.changed, true)
        XCTAssertFalse(world.fixtures.served.contains { $0.path == "/thanks" }, "no request carried the form")
        XCTAssertEqual(outcome.form, FormEnding(kind: .keptChanging, host: "site-451.test"))
    }

    /// Review round 1, C3 — the other half of the race, tried: as the Send
    /// goes down, the page puts another control right over it, one that acts
    /// as the button comes up. The press is the Send's or nothing: the other
    /// control never acts.
    @MainActor
    func testAControlPutUnderThePressAsItGoesDownNeverActs() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let hands = KeepsTheTab(world.bridge)
        let asked = Asked()
        let run = try run(on: "site-452", field: "First name", send: "Request a demo", hands: hands, asked: asked) { _ in
            .yes
        }
        _ = await run.run(report: { _ in })
        XCTAssertEqual(asked.forms.first?.kind, .fill, "\(run.record.eventLines)")
        let other = try await read("String(window.other)", in: hands, world: world)
        XCTAssertEqual(other, "0", "the control put under the press never acted")
        XCTAssertFalse(world.fixtures.served.contains { $0.path == "/thanks" }, "no request carried the form")
    }

    // MARK: - Review round 2

    /// R2-1: what a form's own script sends of its values while the form is
    /// filled — by fetch, by XHR, by a beacon — never goes out: every request
    /// of the tab that sends is held back until the Send's Yes; what the page
    /// reads by GET still comes, and the form goes on to its Send.
    @MainActor
    func testWhatAFormsOwnScriptSendsWhileItIsFilledNeverGoesOut() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let hands = KeepsTheTab(world.bridge)
        let asked = Asked()
        let run = try run(on: "site-459", field: "First name", send: "Request a demo", hands: hands, asked: asked) {
            $0.kind == .fill ? .yes : .no
        }
        let outcome = await run.run(report: { _ in })
        XCTAssertEqual(asked.forms.map(\.kind), [.fill, .send], "\(run.record.eventLines)")
        let paths = world.fixtures.served.map(\.path)
        XCTAssertTrue(paths.contains("/api/read"), "a GET still comes: \(paths)")
        for sent in ["/api/fetch", "/api/xhr", "/api/beacon"] {
            XCTAssertFalse(paths.contains(sent), "\(sent) went out: \(paths)")
        }
        XCTAssertEqual(outcome.form, FormEnding(kind: .notSent, host: "site-459.test"))
    }

    /// R2-2: the page sends the filled form by itself once it is scrolled — a
    /// step the agent takes after Fill: held until the Send's Yes, nothing
    /// goes; the Send is asked as before.
    @MainActor
    func testAFormThePageSendsAsItIsScrolledNeverGoesOutBeforeTheSendsYes() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let hands = KeepsTheTab(world.bridge)
        let asked = Asked()
        let run = try run(on: "site-460", engine: AgentRunFormTests.scrollsThenSends(send: "Request a demo"),
                          hands: hands, asked: asked) { $0.kind == .fill ? .yes : .no }
        let outcome = await run.run(report: { _ in })
        XCTAssertTrue(run.record.steps.contains { $0.operation == "scroll" }, "\(run.record.eventLines)")
        XCTAssertFalse(world.fixtures.served.contains { $0.path == "/thanks" }, "no request carried the form")
        XCTAssertEqual(asked.forms.map(\.kind), [.fill, .send], "\(run.record.eventLines)")
        XCTAssertEqual(outcome.form, FormEnding(kind: .notSent, host: "site-460.test"))
    }

    /// R2-2: the agent's own navigation away from the filled form goes; what
    /// the page sends as it is left — a beacon with the e-mail — stays held;
    /// on the next page, the page's own requests go as ever.
    @MainActor
    func testTheAgentsOwnNavigationAwayGoesAndWhatThePageSendsAsItIsLeftDoesNot() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let hands = KeepsTheTab(world.bridge)
        let asked = Asked()
        let loaded = AgentRunFormTests.Flag()
        let engine = ScriptedEngine(choice: { request in
            let candidates = request.candidates
            if let type = candidates.first(where: {
                $0.action.operation == .type && $0.action.target?.name == "First name"
                    && ($0.action.target?.value ?? "").isEmpty
            }) {
                return ScriptedEngine.pick(type)
            }
            if let away = candidates.first(where: {
                [.open, .click].contains($0.action.operation) && $0.action.target?.name == "Pricing"
            }) {
                return ScriptedEngine.pick(away)
            }
            if let load = candidates.first(where: { $0.action.operation == .click && $0.action.target?.name == "Load prices" }),
               !loaded.set() {
                return ScriptedEngine.pick(load)
            }
            return ScriptedEngine.pick(candidates.first { $0.action.operation == .done })
        })
        let run = try run(on: "site-460", engine: engine, hands: hands, asked: asked) { _ in .yes }
        _ = await run.run(report: { _ in })
        let paths = world.fixtures.served.map(\.path)
        XCTAssertEqual(asked.forms.map(\.kind), [.fill], "\(run.record.eventLines)")
        XCTAssertTrue(paths.contains("/pricing"), "the agent's own navigation went: \(paths) \(run.record.eventLines)")
        XCTAssertFalse(paths.contains("/api/left"), "what the page sent as it was left went out: \(paths)")
        XCTAssertTrue(paths.contains("/api/prices"), "the next page's own request went: \(paths) \(run.record.eventLines)")
    }

    // MARK: - Review round 3

    /// R3-2: the hold cannot be put in place — the guard's session refuses the
    /// patterns that hold what the tab sends: that is a tab that cannot hold,
    /// so nothing is typed; what the page would send is never typed for it to
    /// send; and no half hold is left on the tab — what the user sends there
    /// afterwards goes out, and where the user goes there, the tab goes.
    @MainActor
    func testAHoldThatCannotBePutInPlaceFillsNothing() async throws {
        let world = try await ChromeWorld.start(proxied: true)
        defer { world.stop() }
        world.proxy?.answers = { message in
            message.contains("\"Fetch.enable\"") && message.components(separatedBy: "urlPattern").count - 1 == 3
                ? .error("Fetch.enable refused") : nil
        }
        let hands = KeepsTheTab(world.bridge)
        let asked = Asked()
        let run = try run(on: "site-459", field: "First name", send: "Request a demo", hands: hands, asked: asked) { _ in
            .yes
        }
        let outcome = await run.run(report: { _ in })
        XCTAssertEqual(asked.forms.map(\.kind), [.fill], "\(run.record.eventLines)")
        XCTAssertEqual(outcome.ending, .needsUser)
        let values = try await read("['first','email','company'].map((id) => document.getElementById(id).value).join('|')",
                                    in: hands, world: world)
        XCTAssertEqual(values, "||", "nothing typed")
        XCTAssertFalse(world.fixtures.served.contains { $0.path.hasPrefix("/api/") }, "\(world.fixtures.served)")
        _ = try await read("fetch('/api/later', { method: 'POST', body: '{}' }).catch(() => {}); 'asked'",
                           in: hands, world: world)
        try await waitUntilServed("/api/later", in: world)
        _ = try await read("setTimeout(() => { location.href = '/after'; }, 0); 'asked'", in: hands, world: world)
        try await waitUntilServed("/after", in: world)
    }

    /// R3-2: a frame in a process of its own that is gone before the Fill —
    /// its session gone with it — is no session the hold is wanting: the hold
    /// is put in place on every session the tab has, and the form is filled,
    /// what its script sends held.
    @MainActor
    func testAFrameGoneBeforeTheFillLeavesTheHoldInPlace() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let hands = KeepsTheTab(world.bridge)
        let asked = Asked()
        let run = try run(on: "site-467", field: "First name", send: "Request a demo", hands: hands, asked: asked) {
            $0.kind == .fill ? .yes : .no
        }
        let outcome = await run.run(report: { _ in })
        XCTAssertTrue(world.fixtures.served.contains { $0.host == "site-468.test" }, "the frame was drawn")
        XCTAssertEqual(asked.forms.map(\.kind), [.fill, .send], "\(run.record.eventLines)")
        let paths = world.fixtures.served.map(\.path)
        for sent in ["/api/fetch", "/api/beacon"] {
            XCTAssertFalse(paths.contains(sent), "\(sent) went out: \(paths)")
        }
        XCTAssertEqual(outcome.form, FormEnding(kind: .notSent, host: "site-467.test"))
    }

    /// R3-3: the agent's own navigation away from a filled form: the page it
    /// goes to is not held — its own request, sent as it starts, before any
    /// look of the agent's, goes; what the form's page sent as it was left
    /// stays held.
    @MainActor
    func testThePageTheAgentGoesToSendsItsOwnRequestsAsItStarts() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let hands = KeepsTheTab(world.bridge)
        let asked = Asked()
        let engine = ScriptedEngine(choice: { request in
            let candidates = request.candidates
            if let type = candidates.first(where: {
                $0.action.operation == .type && $0.action.target?.name == "First name"
                    && ($0.action.target?.value ?? "").isEmpty
            }) {
                return ScriptedEngine.pick(type)
            }
            if let away = candidates.first(where: {
                [.open, .click].contains($0.action.operation) && $0.action.target?.name == "Pricing"
            }) {
                return ScriptedEngine.pick(away)
            }
            return ScriptedEngine.pick(candidates.first { $0.action.operation == .done })
        })
        let run = try run(on: "site-465", engine: engine, hands: hands, asked: asked) { _ in .yes }
        _ = await run.run(report: { _ in })
        let paths = world.fixtures.served.map(\.path)
        XCTAssertEqual(asked.forms.map(\.kind), [.fill], "\(run.record.eventLines)")
        XCTAssertTrue(paths.contains("/pricing"), "the agent's own navigation went: \(paths)")
        XCTAssertTrue(paths.contains("/api/startup"), "the next page's own request went as it started: \(paths)")
        XCTAssertFalse(paths.contains("/api/left"), "what the page sent as it was left went out: \(paths)")
    }

    /// R3-3: the agent's own navigation opens the form's own page again: the
    /// page it brings has the form page's address, so what the form's page
    /// sends as it is left — naming that address — is still the form's: held.
    @MainActor
    func testWhatTheFormsPageSendsAsItIsOpenedAgainStaysHeld() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let hands = KeepsTheTab(world.bridge)
        let asked = Asked()
        let (toForm, typed, again) = (AgentRunFormTests.Flag(), AgentRunFormTests.Flag(), AgentRunFormTests.Flag())
        let engine = ScriptedEngine(choice: { request in
            let candidates = request.candidates
            let link = { (name: String) in
                candidates.first { [.open, .click].contains($0.action.operation) && $0.action.target?.name == name }
            }
            if let demo = link("Demo page"), !toForm.set() { return ScriptedEngine.pick(demo) }
            if let type = candidates.first(where: {
                $0.action.operation == .type && $0.action.target?.name == "First name"
            }), !typed.set() {
                return ScriptedEngine.pick(type)
            }
            if let over = link("Start over"), !again.set() { return ScriptedEngine.pick(over) }
            return ScriptedEngine.pick(candidates.first { $0.action.operation == .done })
        })
        let run = try run(on: "site-466", engine: engine, hands: hands, asked: asked) { _ in .yes }
        _ = await run.run(report: { _ in })
        let paths = world.fixtures.served.map(\.path)
        XCTAssertEqual(asked.forms.first?.kind, .fill, "\(run.record.eventLines)")
        XCTAssertEqual(paths.filter { $0 == "/demo" }.count, 2, "the form's page was opened again: \(paths) \(run.record.eventLines)")
        XCTAssertFalse(paths.contains("/api/left"), "what the form's page sent as it was left went out: \(paths)")
    }

    /// R3-3: a site whose pages name only the site as where their requests
    /// come from (referrer policy `origin`) names the same for every page of
    /// it: what the form's page sends as it is left, as the agent goes to the
    /// site's first page, is still the form's — held.
    @MainActor
    func testWhatAFormsPageSendsNamingOnlyItsSiteStaysHeldAsItIsLeft() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let hands = KeepsTheTab(world.bridge)
        let asked = Asked()
        let (toForm, home) = (AgentRunFormTests.Flag(), AgentRunFormTests.Flag())
        let engine = ScriptedEngine(choice: { request in
            let candidates = request.candidates
            let link = { (name: String) in
                candidates.first { [.open, .click].contains($0.action.operation) && $0.action.target?.name == name }
            }
            if let type = candidates.first(where: {
                $0.action.operation == .type && $0.action.target?.name == "First name"
                    && ($0.action.target?.value ?? "").isEmpty
            }) {
                return ScriptedEngine.pick(type)
            }
            if let demo = link("Demo page"), !toForm.set() { return ScriptedEngine.pick(demo) }
            if let back = link("Home"), !home.set() { return ScriptedEngine.pick(back) }
            return ScriptedEngine.pick(candidates.first { $0.action.operation == .done })
        })
        let run = try run(on: "site-469", engine: engine, hands: hands, asked: asked) { _ in .yes }
        _ = await run.run(report: { _ in })
        let paths = world.fixtures.served.map(\.path)
        XCTAssertEqual(asked.forms.first?.kind, .fill, "\(run.record.eventLines)")
        XCTAssertEqual(paths.filter { $0 == "/" }.count, 2, "the agent went back to the first page: \(paths) \(run.record.eventLines)")
        XCTAssertFalse(paths.contains("/api/left"), "what the form's page sent as it was left went out: \(paths)")
    }

    /// R3-3: the form's page writes its own address anew as it is filled, and
    /// the agent goes to that address: the page it brings has an address the
    /// form's page showed, so what the form's page sends as it is left is
    /// still the form's — held.
    @MainActor
    func testWhatTheFormsPageSendsAsTheAddressItWroteIsOpenedStaysHeld() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let hands = KeepsTheTab(world.bridge)
        let asked = Asked()
        let (typed, stepped) = (AgentRunFormTests.Flag(), AgentRunFormTests.Flag())
        let engine = ScriptedEngine(choice: { request in
            let candidates = request.candidates
            if let type = candidates.first(where: {
                $0.action.operation == .type && $0.action.target?.name == "First name"
            }), !typed.set() {
                return ScriptedEngine.pick(type)
            }
            if let step = candidates.first(where: {
                [.open, .click].contains($0.action.operation) && $0.action.target?.name == "Step two"
            }), !stepped.set() {
                return ScriptedEngine.pick(step)
            }
            return ScriptedEngine.pick(candidates.first { $0.action.operation == .done })
        })
        let run = try run(on: "site-470", engine: engine, hands: hands, asked: asked) { _ in .yes }
        _ = await run.run(report: { _ in })
        let served = world.fixtures.served
        XCTAssertEqual(asked.forms.first?.kind, .fill, "\(run.record.eventLines)")
        XCTAssertTrue(served.contains { $0.query == "step=2" }, "the agent went to step two: \(served) \(run.record.eventLines)")
        XCTAssertFalse(served.contains { $0.path == "/api/left" }, "what the form's page sent as it was left went out: \(served)")
    }

    /// Waits up to five seconds for `path` to be served.
    @MainActor
    private func waitUntilServed(_ path: String, in world: ChromeWorld) async throws {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if world.fixtures.served.contains(where: { $0.path == path }) { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("\(path) never went out: \(world.fixtures.served.map(\.path))")
    }

    /// A form a script gathers without a form tag: filled and sent by its own
    /// button, as a person would, after the Yes.
    @MainActor
    func testAFormWithoutAFormTagIsFilledAndSentByItsOwnButton() async throws {
        let world = try await ChromeWorld.start()
        defer { world.stop() }
        let hands = KeepsTheTab(world.bridge)
        let asked = Asked()
        let run = try run(on: "site-441", field: "Full name", send: "Book my demo", hands: hands, asked: asked) { _ in
            .yes
        }
        let outcome = await run.run(report: { _ in })
        XCTAssertEqual(asked.forms.map(\.kind), [.fill, .send], "\(run.record.eventLines)")
        let sent = try await read("String(window.sent) + ' ' + JSON.stringify(window.sentValues)", in: hands, world: world)
        XCTAssertEqual(sent, #"1 ["Sam Example","sam@example.test","AcmeCorp","\#(Self.message)"]"#)
        XCTAssertEqual(outcome.form?.kind, .sent)
    }

    // MARK: - A choice whose change the page sends (2026-10-21)

    /// The brain's choice in a list whose change the page sends — an author list that posts its form, a sort list
    /// that opens the sorted page by its address — in a real Chrome: the change and the list's put back are held back,
    /// the choice is asked about once, and with the Yes the page's own send goes out once, as chosen; with a No, none.
    @MainActor
    func testAChoiceWhoseChangeThePageSendsGoesOutOnceWithTheYesAndNeverWithANo() async throws {
        let cases = [("site-531", "Author", "Sam Lee", "/search", nil), ("site-532", "Sort by", "Cheapest", "/books", "sort=cheap")]
        for (site, list, option, path, query) in cases {
            for answer in [ConfirmationRequest.Answer.yes, .no] {
                let world = try await ChromeWorld.start()
                defer { world.stop() }
                let questions = AgentRunBrainModeTests.Questions()
                let choose: (String) -> String = { state in
                    #"[{"select_dropdown": {"index": \#(AgentRunBrainModeTests.index(of: list, in: state)), "text": "\#(option)"}}]"#
                }
                var parts = AgentRun.Collaborators(
                    bridge: KeepsTheTab(world.bridge),
                    engine: ScriptedEngine(choice: { _ in ChooseAnswer(candidateID: "", confidence: 0, goalMet: nil, usage: nil) },
                                           irreversible: { _ in 0.02 }),
                    writer: nil, sheet: nil, confirm: { request in
                        questions.asked.append(request)
                        return answer
                    }, log: { _ in })
                parts.brain = AgentRunBrainModeTests.StateBrain([choose])
                let goal = "Choose \(option) at https://\(site).test/"
                let plan = try XCTUnwrap(AgentPlan(goal: goal, requirements: [.init(id: "r1", text: "Choose", kind: .action)],
                                                   answerExpected: false))
                let run = AgentRun(goal: goal, planner: FixedPlanner(plan: plan), errandID: UUID(), collaborators: parts,
                                   startPage: URL(string: "https://\(site).test/")!)
                _ = await run.run(report: { _ in })
                let label = "\(site) \(answer): \(run.record.eventLines)"
                XCTAssertEqual(questions.asked.count, 1, label)
                let choices = run.record.steps.filter { $0.operation == "select" }.map(\.outcome)
                XCTAssertEqual(Array(choices.prefix(2)), [.acted, .acted], "the choice and its put back: \(label)")
                // Then the choice with the Yes — the page a post brings here is served without the posted choice, so
                // its check may not see it — or the No.
                XCTAssertEqual(choices.count, 3, label)
                XCTAssertEqual(choices.last == .refused, answer == .no, label)
                let sent = world.fixtures.served.filter { $0.path == path }
                XCTAssertEqual(sent.count, answer == .yes ? 1 : 0, "\(world.fixtures.served) \(label)")
                if let query, answer == .yes { XCTAssertEqual(sent.first?.query, query, label) }
                XCTAssertNotEqual(run.record.ending, .needsUser, label)
            }
        }
    }
}
