import XCTest
@testable import MetaWhisp

/// ITER-076 stage 11 — "fill this page": the window the user looks at, its empty fields' texts from text 16 with
/// the user's words of the send as the goal and the user's details, all asked together and kept to the agent's
/// spend ceiling (§8), then the hands; and what MetaChat reads back: the fields filled, the values not known, the
/// lists the user picks from.
@MainActor
final class DoHereTests: XCTestCase {
    private let pid: pid_t = 4_242
    private let words = "fill this page"

    private func field(_ label: String, _ role: String = "AXTextField") -> HereField {
        HereField(label: label, role: role)
    }

    private let facts = FormFacts.collect(memories: [
        FormFacts.Memory(content: "My name is Sam Example", toldMetaChat: true, createdAt: Date(timeIntervalSince1970: 0)),
    ], proEmail: "sam@example.test")

    /// What a request asks of text 16: its input as the model reads it.
    nonisolated private static func input(_ asked: RecordedModel.Asked) -> [String: Any] {
        let user = asked.contents.last.flatMap { $0 } ?? ""
        return (try? JSONSerialization.jsonObject(with: Data(user.utf8))) as? [String: Any] ?? [:]
    }

    nonisolated private static func label(_ asked: RecordedModel.Asked) -> String {
        (input(asked)["field"] as? [String: Any])?["label"] as? String ?? ""
    }

    /// Text 16's answer: a text, or null.
    nonisolated private static func answer(_ text: String?) -> RecordedModel.Reply {
        .text(text.map { #"{"text": "\#($0)"}"# } ?? #"{"text": null}"#)
    }

    private func doHere(_ fields: [HereField], model: RecordedModel, world: FakeHereWorld,
                        limits: AgentBudget.Limits = .standard, asked: ((([String]) -> Void))? = nil) -> DoHere {
        let facts = self.facts
        return DoHere(app: { [pid] in pid },
                      look: { _ in HereLook(fields: fields, title: "Edit your profile", text: "Edit your profile") },
                      facts: { labels in asked?(labels); return facts },
                      model: model.model, hands: world, limits: limits, optionWait: .milliseconds(60))
    }

    // MARK: - The texts

    /// Each field that takes typing is asked once, with text 16 — strict JSON, its cap — the user's words of the
    /// send as the goal, the user's details, the field by its name and role, and the page; a pop-up button never.
    func testEachFieldIsAskedWithTextSixteenTheUsersWordsAndDetails() async throws {
        let model = RecordedModel { asked, _ in Self.answer(Self.label(asked) == "Job Title" ? nil : "Sam") }
        var labelsAsked: [[String]] = []
        let run = doHere([field("First Name"), field("Bio", "AXTextArea"), field("Company", "AXComboBox"),
                          field("Language", "AXPopUpButton"), field("Job Title")], model: model, world: FakeHereWorld(),
                         asked: { labelsAsked.append($0) })
        _ = await run.run(goal: words)
        let requests = model.requests("field_text")
        XCTAssertEqual(Set(requests.map(Self.label)), ["First Name", "Bio", "Company", "Job Title"])
        XCTAssertEqual(labelsAsked, [["First Name", "Bio", "Company", "Job Title"]], "the details, for these labels")
        for asked in requests {
            XCTAssertEqual(asked.contents.first, ModelTexts.formFieldText)
            XCTAssertEqual(asked.body["response_format"] as? NSDictionary,
                           try XCTUnwrap(try JSONSerialization.jsonObject(with: JSONEncoder().encode(ErrandModel.fieldTextFormat))
                                         as? NSDictionary))
            XCTAssertEqual(asked.body["max_tokens"] as? Int, ErrandModel.fieldTextTokens)
            let input = Self.input(asked)
            XCTAssertEqual(input["goal"] as? String, words)
            XCTAssertEqual(input["details"] as? [String], ["My name is Sam Example", "sam@example.test"])
            let field = try XCTUnwrap(input["field"] as? [String: Any])
            XCTAssertEqual(field["role"] as? String, field["label"] as? String == "Company" ? "combobox" : "textbox")
            XCTAssertEqual(field["value"] as? String, "")
            XCTAssertEqual((input["page"] as? [String: Any])?["title"] as? String, "Edit your profile")
        }
    }

    /// The fields are asked together: every request is out before the first answer comes.
    func testTheFieldsAreAskedTogether() async throws {
        let arrivals = Arrivals()
        let model = RecordedModel { _, _ in
            arrivals.note()
            return .after(.milliseconds(500), Self.answer("Sam"))
        }
        let labels = ["First Name", "Last Name", "Company", "Job Title"]
        let began = ContinuousClock.now
        _ = await doHere(labels.map { field($0) }, model: model, world: FakeHereWorld()).run(goal: words)
        XCTAssertEqual(arrivals.all.count, 4)
        let last = try XCTUnwrap(arrivals.all.max())
        XCTAssertLessThan(last - began, .milliseconds(450), "all out before the first answer")
    }

    // MARK: - What MetaChat reads back

    /// Filled, not known and to pick, each in the page's order, by the field's name — exactly the result's shape.
    func testTheResultNamesWhatWasFilledNotKnownAndToPick() async {
        let model = RecordedModel { asked, _ in
            switch Self.label(asked) {
            case "Job Title": return Self.answer(nil)
            case "Company": return Self.answer("Acme")
            case "Country": return Self.answer("Germany")
            default: return Self.answer("Sam")
            }
        }
        let world = FakeHereWorld()
        world.optionsAfter["Germany"] = [HereOption(title: "Germany", id: 1)]
        let result = await doHere([field("First Name"), field("Company", "AXComboBox"), field("Job Title"),
                                   field("Language", "AXPopUpButton"), field("Country", "AXComboBox"),
                                   field("Last Name")], model: model, world: world).run(goal: words)
        XCTAssertEqual(result, HereResult(filled: ["First Name", "Country", "Last Name"], unknown: ["Job Title"],
                                          pick: ["Company", "Language"]))
        XCTAssertEqual(result.json,
                       #"{"filled": ["First Name", "Country", "Last Name"], "unknown": ["Job Title"], "pick": ["Company", "Language"], "failed": []}"#)
        XCTAssertEqual(HereResult().json, #"{"filled": [], "unknown": [], "pick": [], "failed": []}"#)
        XCTAssertEqual(world.acts.filter { if case .paste = $0 { return true } else { return false } }.count, 4,
                       "the field not known gets nothing")
    }

    /// A field whose call failed — the service down, the day's limit — is named as failed: it was not filled, and
    /// nothing says its value is not known (2026-10-07: in no list, MetaChat could not say why it stayed empty).
    func testAFieldWhoseCallFailedIsNamedAsFailed() async {
        let model = RecordedModel { asked, _ in Self.label(asked) == "Bio" ? .status(503) : Self.answer("Sam") }
        let world = FakeHereWorld()
        let result = await doHere([field("First Name"), field("Bio", "AXTextArea")], model: model, world: world)
            .run(goal: words)
        XCTAssertEqual(result, HereResult(filled: ["First Name"], failed: ["Bio"]))
        XCTAssertFalse(world.acts.contains(.focus("Bio")))
    }

    /// Each call reserves its worst case first, as every agent call does (§8): one that would cross the spend
    /// ceiling is not asked, and its field is named as failed.
    func testNoCallGoesPastTheSpendCeiling() async throws {
        let page = ObservedPage(url: "", title: "Edit your profile", truncated: false, flags: .none, elements: [],
                                text: "Edit your profile")
        let one = ErrandModel.worstCaseUSD(of: DoHere.request(goal: words, details: facts.details.map(\.text),
                                                             field: DoHere.element(field("First Name"), index: 0),
                                                             page: page))
        XCTAssertGreaterThan(one, 0)
        let limits = AgentBudget.Limits(steps: 40, activeSeconds: 600, spendMicros: Int(one * 1.5 * 1_000_000),
                                        expiry: .seconds(1_800))
        let model = RecordedModel(costUSD: nil) { _, _ in Self.answer("Sam") }
        let result = await doHere([field("First Name"), field("Last Name")], model: model, world: FakeHereWorld(),
                                  limits: limits).run(goal: words)
        XCTAssertEqual(model.requests("field_text").map(Self.label), ["First Name"])
        XCTAssertEqual(result, HereResult(filled: ["First Name"], failed: ["Last Name"]))
    }

    // MARK: - When nothing is done

    /// No words, no window, no field: nothing asked, nothing touched, three empty lists.
    func testNothingIsDoneWithoutWordsAWindowOrAField() async {
        let model = RecordedModel { _, _ in Self.answer("Sam") }
        let world = FakeHereWorld()
        let noWords = await doHere([field("First Name")], model: model, world: world).run(goal: "  \n")
        var noWindow = doHere([field("First Name")], model: model, world: world)
        noWindow.app = { nil }
        let none = await noWindow.run(goal: words)
        let noField = await doHere([], model: model, world: world).run(goal: words)
        XCTAssertEqual([noWords, none, noField], [HereResult(), HereResult(), HereResult()])
        XCTAssertTrue(model.requests.isEmpty)
        XCTAssertTrue(world.acts.isEmpty)
    }

    // MARK: - The eyes, again

    /// A window that shows no field is read again — every 300 ms, for up to 5 s — and the first read that shows one
    /// is the look: Chrome showed a page's fields to the Accessibility API only a while after it was first asked
    /// (measured 2026-10-07: 0.25 to 2 s; 2026-10-13: 2.2 to 2.8 s). A process with no window is read once.
    func testAWindowThatShowsNoFieldIsReadAgainForAWhile() async {
        XCTAssertEqual(DoHere.readEvery, .milliseconds(300))
        XCTAssertEqual(DoHere.readWait, .seconds(5))
        let field = HereNode(role: "AXTextField", title: "First Name", value: "")
        let reads = Reads()
        let look = await DoHere.read(pid, every: .milliseconds(5), within: .seconds(2)) { _ in
            reads.next() >= 5 ? HereNode(role: "AXWindow", children: [HereNode(role: "AXWebArea", children: [field])])
                : HereNode(role: "AXWindow")
        }
        XCTAssertEqual(look?.fields.map(\.label), ["First Name"])
        XCTAssertEqual(reads.count, 5, "no read after the one that showed it")
        let empty = await DoHere.read(pid, every: .milliseconds(5), within: .milliseconds(60)) { _ in
            HereNode(role: "AXWindow")
        }
        XCTAssertEqual(empty?.fields.count, 0, "a window with no field, once the wait is over")
        let none = Reads()
        let nothing = await DoHere.read(pid, every: .milliseconds(5), within: .seconds(2)) { _ in
            none.next()
            return nil
        }
        XCTAssertNil(nothing)
        XCTAssertEqual(none.count, 1)
    }

    // MARK: - The window the user looks at

    /// The last app the user activated that is not MetaWhisp: the browser they were in when they spoke, or the
    /// one they came from to type in MetaChat.
    func testTheWindowIsTheLastAppActivatedThatIsNotMetaWhisp() {
        let own: pid_t = 100
        var trail = UserWindow.Trail(own: own)
        XCTAssertNil(trail.last)
        trail.activated(own)
        XCTAssertNil(trail.last, "MetaWhisp alone: no window")
        trail.activated(200)
        XCTAssertEqual(trail.last, 200)
        trail.activated(own)
        XCTAssertEqual(trail.last, 200, "typed in MetaChat: the app the user came from")
        trail.activated(300)
        trail.activated(own)
        trail.activated(own)
        XCTAssertEqual(trail.last, 300)
    }
}

/// How many times the eyes read.
private final class Reads: @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0

    @discardableResult
    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        reads += 1
        return reads
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return reads
    }
}

/// When each request reached the server.
private final class Arrivals: @unchecked Sendable {
    private let lock = NSLock()
    private var times: [ContinuousClock.Instant] = []

    func note() {
        lock.lock()
        times.append(.now)
        lock.unlock()
    }

    var all: [ContinuousClock.Instant] {
        lock.lock()
        defer { lock.unlock() }
        return times
    }
}
