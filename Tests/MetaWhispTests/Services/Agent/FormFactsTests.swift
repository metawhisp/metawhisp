import SwiftData
import XCTest
@testable import MetaWhisp

/// ITER-076 stage 7 (№ 53, 87) — the user's own details a form is filled
/// from: confirmed memories — MetaChat's own filter — the ones the user told
/// MetaChat first, then the newest, at most as many as MetaChat reads; never a
/// memory that holds a card number; then the Pro account's e-mail. E-mail,
/// phone and web address are found in them by code, word for word.
final class FormFactsTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func memory(_ content: String, toldMetaChat: Bool = false, minutesAgo: Double = 0)
        -> FormFacts.Memory {
        FormFacts.Memory(content: content, toldMetaChat: toldMetaChat,
                         createdAt: now.addingTimeInterval(-minutesAgo * 60))
    }

    /// What the user told MetaChat comes first, newest first; then the rest,
    /// newest first; the Pro account's e-mail last, on its own.
    func testToldMetaChatFirstThenNewestThenTheProEmail() {
        let facts = FormFacts.collect(memories: [
            memory("Works on the onboarding flow", minutesAgo: 1),
            memory("My name is Sam Example", toldMetaChat: true, minutesAgo: 30),
            memory("I work at AcmeCorp", toldMetaChat: true, minutesAgo: 10),
            memory("Likes green tea", minutesAgo: 5),
        ], proEmail: "sam.pro@example.test")
        XCTAssertEqual(facts.details.map(\.text), ["I work at AcmeCorp", "My name is Sam Example",
                                                   "Works on the onboarding flow", "Likes green tea",
                                                   "sam.pro@example.test"])
        XCTAssertEqual(facts.details.map(\.source), [.memory, .memory, .memory, .memory, .proAccount])
    }

    /// At most as many memories as MetaChat reads for an answer; the Pro
    /// e-mail is beside them, not among them.
    func testAtMostTwentyMemories() {
        let many = (1...30).map { memory("Fact \($0)", minutesAgo: Double($0)) }
        let facts = FormFacts.collect(memories: many, proEmail: "sam@example.test")
        XCTAssertEqual(facts.details.filter { $0.source == .memory }.count, FormFacts.maxMemories)
        XCTAssertEqual(FormFacts.maxMemories, 20)
        XCTAssertEqual(facts.details.first?.text, "Fact 1", "the newest")
        XCTAssertEqual(facts.details.last?.text, "sam@example.test")
    }

    /// A memory that holds a card number — a run of digits that passes the
    /// Luhn check, however it is spaced or written — is never a detail: it is
    /// not sent to the writer, nor typed. A long number that is no card stays.
    func testAMemoryHoldingACardNumberIsNeverADetail() {
        let facts = FormFacts.collect(memories: [
            memory("My card is 4111 1111 1111 1111"),
            memory("Card ４１１１-１１１１-１１１１-１１１１ for the demo"),
            memory("Card 4111\u{200B}111111111111"),
            memory("Order number 1234 5678 9012 3456"),
            memory("My phone is +1 555 010 0199"),
        ], proEmail: nil)
        XCTAssertEqual(facts.details.map(\.text), ["Order number 1234 5678 9012 3456", "My phone is +1 555 010 0199"])
    }

    /// E-mail, phone and web address are found by code and copied exactly as
    /// the memory writes them — never put in a canonical form — memories
    /// first, in their order, then the Pro e-mail; each once.
    func testEmailPhoneAndWebAddressAreFoundWordForWord() {
        let facts = FormFacts.collect(memories: [
            memory("Reach me at Sam.Example@Example.test or call +1 (555) 010-0199", toldMetaChat: true),
            memory("Our site is acme.example.com and my other mail is sam@example.test"),
            memory("No contact here"),
        ], proEmail: "sam@example.test")
        XCTAssertEqual(facts.emails.map(\.text), ["Sam.Example@Example.test", "sam@example.test"])
        XCTAssertEqual(facts.emails.map(\.source), [.memory, .memory], "the Pro e-mail was a memory's already")
        XCTAssertEqual(facts.phones.map(\.text), ["+1 (555) 010-0199"])
        XCTAssertEqual(facts.links.map(\.text), ["acme.example.com"])
        let proOnly = FormFacts.collect(memories: [memory("Likes tea")], proEmail: "sam.pro@example.test")
        XCTAssertEqual(proOnly.emails.map(\.text), ["sam.pro@example.test"])
        XCTAssertEqual(proOnly.emails.map(\.source), [.proAccount])
    }

    /// ITER-076 stage 11: the details of a form in the window the user looks at — what the user told MetaChat
    /// first, then in the order given (MetaChat's own retrieval, nearest the form's labels first), not the newest;
    /// at most as many; never a card number; the Pro account's e-mail last.
    func testRankedDetailsAreToldMetaChatFirstThenInTheirRank() {
        let facts = FormFacts.collect(ranked: [
            memory("Works at AcmeCorp as a designer", minutesAgo: 50),
            memory("Likes green tea", minutesAgo: 1),
            memory("My name is Sam Example", toldMetaChat: true, minutesAgo: 30),
            memory("My card is 4111 1111 1111 1111"),
            memory("Lives in Berlin", toldMetaChat: true, minutesAgo: 90),
        ], proEmail: "sam.pro@example.test")
        XCTAssertEqual(facts.details.map(\.text), ["My name is Sam Example", "Lives in Berlin",
                                                   "Works at AcmeCorp as a designer", "Likes green tea",
                                                   "sam.pro@example.test"])
        XCTAssertEqual(facts.details.map(\.source), [.memory, .memory, .memory, .memory, .proAccount])
        let many = FormFacts.collect(ranked: (1...30).map { memory("Fact \($0)", minutesAgo: Double(30 - $0)) },
                                     proEmail: nil)
        XCTAssertEqual(many.details.map(\.text), (1...20).map { "Fact \($0)" }, "the first twenty in rank")
    }

    /// The app's facts come from its own store with MetaChat's filter: a
    /// dismissed memory and one waiting for review are not the user's.
    @MainActor
    func testTheStoresMemoriesAreReadWithMetaChatsFilter() throws {
        let container = try ModelContainer(for: Schema([UserMemory.self]),
                                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let context = ModelContext(container)
        let told = UserMemory(content: "My name is Sam Example", category: "system", sourceApp: "MetaChat",
                              confidence: 1.0)
        let seen = UserMemory(content: "I work at AcmeCorp", category: "system", sourceApp: "Slack", confidence: 0.9)
        let dismissed = UserMemory(content: "My phone is +1 555 010 0100", category: "system", sourceApp: "MetaChat",
                                   confidence: 1.0)
        dismissed.isDismissed = true
        let proposed = UserMemory(content: "My phone is +1 555 010 0101", category: "system", sourceApp: "Screen",
                                  confidence: 0.8)
        proposed.needsReview = true
        seen.createdAt = told.createdAt.addingTimeInterval(60)
        for item in [told, seen, dismissed, proposed] { context.insert(item) }
        try context.save()
        let facts = FormFacts.stored(in: container, proEmail: "sam@example.test")
        XCTAssertEqual(facts.details.map(\.text), ["My name is Sam Example", "I work at AcmeCorp", "sam@example.test"])
        XCTAssertTrue(facts.phones.isEmpty)
    }
}
