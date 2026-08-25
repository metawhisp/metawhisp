import XCTest
@testable import MetaWhisp

/// The deck that makes a prompt change arguable.
///
/// Until now every change to what the Screen Agent says was judged by trying it
/// a few times and forming an impression. That is how a change can fix one
/// failure class and quietly reintroduce another, and how a regression survives
/// until a user reports it weeks later.
///
/// The golden labels are the decision and its reason code, never the generated
/// prose. A prompt is allowed to word things differently. It is not allowed to
/// change what gets shown.
///
/// Eleven of the fifteen cases expect silence, which is roughly the shape of a
/// real working day.
final class ScreenAgentReplayTests: XCTestCase {

    private struct Deck: Decodable {
        let version: Int
        let cases: [Case]
        let insight_cases: [InsightCase]?
    }

    /// A prompt-shaped fixture: what the model returns and what was on screen,
    /// nothing more. No hand-authored citations or quotes — those are the
    /// adapter's job, and hand-authoring them meant the deck was testing the
    /// director against evidence production would never construct.
    private struct InsightCase: Decodable {
        let id: String
        let locale: String
        let screen: String
        let headline: String
        let body: String
        let confidence: Double
        let retrieved: [String]?
        let expect: String
        let reason: String?
        let why: String
    }

    private struct Case: Decodable {
        let id: String
        let locale: String
        let screen: String
        let candidates: [Candidate]
        let recent: [String]?
        let expect: String
        let reason: String?
        let why: String
    }

    private struct Candidate: Decodable {
        let headline: String
        let body: String?
        let confidence: Double
        let cited: [String]
        let quote: String?
    }

    private func loadDeck() throws -> Deck {
        // The fixture lives beside the tests; SwiftPM does not copy it into a
        // bundle, so it is read from the source tree by path.
        let here = URL(fileURLWithPath: #filePath)
        let root = here
            .deletingLastPathComponent()   // Intelligence
            .deletingLastPathComponent()   // Services
            .deletingLastPathComponent()   // MetaWhispTests
        let url = root
            .appendingPathComponent("Fixtures/ScreenAgent/v1/deck.json")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Deck.self, from: data)
    }

    func testTheDeckIsLoadableAndBalanced() throws {
        let deck = try loadDeck()
        XCTAssertEqual(deck.version, 1)
        XCTAssertGreaterThanOrEqual(deck.cases.count, 15)
        XCTAssertEqual(Set(deck.cases.map(\.id)).count, deck.cases.count,
                       "case ids must be stable and unique — they are how a failure is named")

        let silences = deck.cases.filter { $0.expect == "silence" }.count
        XCTAssertGreaterThan(silences, deck.cases.count / 2,
                             "most screens are someone reading; a deck that mostly expects "
                             + "comments would reward a chattier agent")
        XCTAssertTrue(deck.cases.contains { $0.locale == "ru" },
                      "the user works in Russian, so the deck has to")
        XCTAssertTrue(deck.cases.allSatisfy { !$0.why.isEmpty },
                      "a case nobody can explain cannot be argued with when it fails")
    }

    /// Every case, through the real director and the real guards.
    func testEveryCaseDecidesTheWayItShould() throws {
        let deck = try loadDeck()
        var failures: [String] = []

        for testCase in deck.cases {
            let evidence = ScreenAgentEvidence([
                .init(id: "e1", contextID: UUID(), text: testCase.screen),
            ])
            let candidates = testCase.candidates.map {
                ScreenAgentDirector.Candidate(
                    headline: $0.headline,
                    body: $0.body ?? "",
                    citedEvidenceIDs: $0.cited,
                    quote: $0.quote,
                    confidence: $0.confidence,
                    namesReferent: InsightReferent.namesSomethingSpecific($0.headline)
                )
            }
            let decision = ScreenAgentDirector.decide(
                candidates: candidates,
                evidence: evidence,
                screenText: testCase.screen,
                recentHeadlines: testCase.recent ?? []
            )

            switch (testCase.expect, decision) {
            case ("item", .item):
                continue
            case ("silence", .silence(let reason)):
                if let expected = testCase.reason, reason.rawValue != expected {
                    failures.append("\(testCase.id): silent for '\(reason.rawValue)', "
                                    + "expected '\(expected)' — \(testCase.why)")
                }
            case ("item", .silence(let reason)):
                failures.append("\(testCase.id): stayed silent (\(reason.rawValue)) "
                                + "but should have spoken — \(testCase.why)")
            case ("silence", .item(let headline, _, _)):
                failures.append("\(testCase.id): said \"\(headline)\" "
                                + "but should have stayed quiet — \(testCase.why)")
            default:
                failures.append("\(testCase.id): unhandled expectation '\(testCase.expect)'")
            }
        }

        XCTAssertTrue(failures.isEmpty,
                      "\n" + failures.joined(separator: "\n"))
    }

    /// The reason codes are the diagnosis. A deck that only checked
    /// silent-versus-not would pass while every silence happened for the wrong
    /// cause, and nobody would know until the behavior was wrong in the wild.
    func testSilenceReasonsAreAssertedNotJustSilence() throws {
        let deck = try loadDeck()
        let silentCases = deck.cases.filter { $0.expect == "silence" }
        XCTAssertTrue(silentCases.allSatisfy { $0.reason != nil },
                      "every expected silence must say which reason it expects")
        XCTAssertGreaterThanOrEqual(
            Set(silentCases.compactMap(\.reason)).count, 5,
            "the deck must exercise several distinct reasons, not one over and over")
    }

    /// Codex's first required assertion for this deck: a fixture must cross the
    /// same bridge a live insight crosses. These run prompt-shaped output
    /// through the production adapter, so if the adapter starts lying — citing
    /// what it should not, anchoring what it did not — the deck fails.
    func testPromptShapedInsightsCrossTheProductionAdapter() throws {
        let deck = try loadDeck()
        let insightCases = deck.insight_cases ?? []
        XCTAssertGreaterThanOrEqual(insightCases.count, 5,
                                    "the adapter path is the one production takes; it needs cases")
        XCTAssertTrue(insightCases.contains { $0.expect == "item" },
                      "an all-silence adapter deck would reward a dead adapter")

        var failures: [String] = []
        for testCase in insightCases {
            // body stays exactly what the fixture says — padding it with the
            // headline created a mid-string capitalized word that read as a
            // proper noun and defeated the vagueness check.
            let insight = ExtractedInsight(
                body: testCase.body,
                headline: testCase.headline,
                reasoning: nil,
                category: "other",
                sourceApp: "Test",
                confidence: testCase.confidence
            )
            let retrieved = (testCase.retrieved ?? []).enumerated().map {
                InsightInvestigator.RetrievedRef(id: "m\($0.offset)", text: $0.element)
            }
            let (evidence, ids) = ScreenAgentCandidateAdapter.evidence(
                contextID: UUID(), ocrText: testCase.screen, retrieved: retrieved)
            let candidate = ScreenAgentCandidateAdapter.candidate(from: insight, citing: ids)
            let decision = ScreenAgentDirector.decide(
                candidates: [candidate], evidence: evidence,
                screenText: testCase.screen, recentHeadlines: [])

            switch (testCase.expect, decision) {
            case ("item", .item):
                continue
            case ("silence", .silence(let reason)):
                if let expected = testCase.reason, reason.rawValue != expected {
                    failures.append("\(testCase.id): silent for '\(reason.rawValue)', "
                                    + "expected '\(expected)' — \(testCase.why)")
                }
            case ("item", .silence(let reason)):
                failures.append("\(testCase.id): stayed silent (\(reason.rawValue)) "
                                + "but should have spoken — \(testCase.why)")
            case ("silence", .item(let headline, _, _)):
                failures.append("\(testCase.id): said \"\(headline)\" "
                                + "but should have stayed quiet — \(testCase.why)")
            default:
                failures.append("\(testCase.id): unhandled expectation '\(testCase.expect)'")
            }
        }
        XCTAssertTrue(failures.isEmpty, "\n" + failures.joined(separator: "\n"))
    }
}
