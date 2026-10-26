import XCTest
@testable import MetaWhisp

final class AgentReadCacheTests: XCTestCase {
    private static let preview = URL(string: "https://example.test/preview")!
    private static let current = URL(string: "https://example.test/current")!
    private static let opening = "Opening hours: 09:00 to 17:00."
    private static let support = "Support hours: 10:00 to 16:00."

    /// An identical listing on another document still needs its own source check.
    @MainActor
    func testIdenticalTextOnAnotherDocumentIsReadWithItsOwnSource() async throws {
        let bridge = IdenticalListings()
        let model = scripted(["Read the preview", "Open https://example.test/current and read the current listing"]) {
            asked, _ in
            guard (asked.contents.last ?? nil)?.contains("# Capture\nURL: https://example.test/current\n") == true else {
                return .text(RecordedModel.reading([]))
            }
            return .text(RecordedModel.reading([
                RecordedModel.claim(cite: ("main/:1", "main/:1"), requirement: "r1"),
            ], answered: true))
        }
        let run = try makeRun(model, bridge: bridge, requirements: [
            .init(id: "r1", text: "Find opening hours from the current listing, not its preview", kind: .information),
        ])

        let outcome = await run.run(report: { _ in })

        XCTAssertEqual(bridge.captures.map(\.url), [Self.preview.absoluteString, Self.current.absoluteString])
        XCTAssertEqual(bridge.captures.map(\.text), Array(repeating: Self.opening + "\n" + Self.support, count: 2),
                       "Both documents really supplied identical captured text")
        XCTAssertTrue(bridge.inner.navigatedURLs.contains(Self.current), "The browser navigated to the second document")
        XCTAssertEqual(model.requests("read").count, 2)
        XCTAssertEqual(model.requests("verify").count, 1)
        XCTAssertEqual(outcome.ending, .done)
        XCTAssertEqual(outcome.answer, Self.opening + "\n" + Self.current.absoluteString)
        XCTAssertEqual(outcome.sources, [Self.current])
        XCTAssertEqual(run.record.facts.map(\.url), [Self.current.absoluteString])
        XCTAssertEqual(bridge.inner.openTabCount, 0)
    }

    /// A partial read narrows the question without changing the document's text.
    @MainActor
    func testUnchangedPageIsReadAgainForItsRemainingRequirement() async throws {
        let bridge = IdenticalListings()
        let model = scripted(["Read opening hours", "Read support hours"]) { _, number in
            let block = number == 0 ? "main/:1" : "main/:2"
            return .text(RecordedModel.reading([
                RecordedModel.claim(cite: (block, block), requirement: number == 0 ? "r1" : "r2"),
            ], answered: number > 0))
        }
        let run = try makeRun(model, bridge: bridge, requirements: [
            .init(id: "r1", text: "Find opening hours", kind: .information),
            .init(id: "r2", text: "Find support hours", kind: .information),
        ])

        let outcome = await run.run(report: { _ in })

        XCTAssertEqual(bridge.captures.map(\.url), Array(repeating: Self.preview.absoluteString, count: 2))
        XCTAssertEqual(bridge.captures.map(\.text), Array(repeating: Self.opening + "\n" + Self.support, count: 2))
        XCTAssertTrue(bridge.inner.navigatedURLs.isEmpty, "Changing what remains to find did not navigate")
        let reads = model.requests("read")
        XCTAssertEqual(reads.count, 2)
        let first = try XCTUnwrap(reads.first?.contents.last ?? nil)
        XCTAssertTrue(first.hasSuffix("# Requirement ids\nr1, r2"))
        let second = try XCTUnwrap(reads.dropFirst().first?.contents.last ?? nil)
        XCTAssertTrue(second.hasSuffix("# Requirement ids\nr2"), "Only the unfulfilled requirement is asked again")
        XCTAssertTrue(second.contains(Self.opening + "\" requirements=r1"), "The first read's evidence is retained")
        XCTAssertEqual(model.requests("verify").count, 1)
        XCTAssertEqual(outcome.ending, .done)
        XCTAssertEqual(outcome.answer, [Self.opening, Self.support].map { $0 + "\n" + Self.preview.absoluteString }
            .joined(separator: "\n\n"))
        XCTAssertEqual(outcome.sources, [Self.preview])
        XCTAssertEqual(run.record.facts.map(\.requirements), [["r1"], ["r2"]])
        XCTAssertEqual(bridge.inner.openTabCount, 0)
    }

    /// Repeating the same question on unchanged content spends at most one more read (2026-10-15: a reader that
    /// missed a heading once found it the second time; a reference browser agent's `barren_reads`, MIT).
    @MainActor
    func testUnchangedPageAndRequirementsDoNotRepeatAnUnproductiveReadMoreThanOnce() async throws {
        let bridge = IdenticalListings()
        let model = scripted(["Read the listing", "Check the listing again", "Check it a third time"]) { _, _ in
            .text(RecordedModel.reading([]))
        }
        let run = try makeRun(model, bridge: bridge, requirements: [
            .init(id: "r1", text: "Find weekend opening hours", kind: .information),
        ])

        let outcome = await run.run(report: { _ in })

        XCTAssertEqual(bridge.captures.map(\.url), Array(repeating: Self.preview.absoluteString, count: 3))
        XCTAssertEqual(bridge.captures.map(\.text), Array(repeating: Self.opening + "\n" + Self.support, count: 3))
        XCTAssertEqual(model.requests("read").count, 2)
        XCTAssertEqual(model.requests("subgoal").count, 6, "three sub-goals, the model's end and two ends rejected")
        XCTAssertTrue(model.requests("verify").isEmpty)
        let reads = run.record.events.compactMap { event -> ErrandRecord.Event.Read.End? in
            if case .read(let read) = event { return read.end }
            return nil
        }
        XCTAssertEqual(reads, [.read, .read, .readBefore])
        XCTAssertEqual(outcome.ending, .notFinished)
        XCTAssertNil(outcome.answer)
        XCTAssertTrue(outcome.sources.isEmpty)
        XCTAssertTrue(run.record.facts.isEmpty)
        XCTAssertEqual(bridge.inner.openTabCount, 0)
    }

    private func scripted(_ subgoals: [String],
                          read: @escaping @Sendable (RecordedModel.Asked, Int) -> RecordedModel.Reply) -> RecordedModel {
        RecordedModel { asked, number in
            switch asked.purpose {
            case "subgoal":
                return number < subgoals.count ? .calls([RecordedModel.goal(subgoals[number])]) : .text("Done.")
            case "read": return read(asked, number)
            case "verify": return RecordedModel.verdict(complete: true)
            default: return .status(400)
            }
        }
    }

    @MainActor
    private func makeRun(_ model: RecordedModel, bridge: IdenticalListings,
                         requirements: [AgentPlan.Requirement]) throws -> AgentRun {
        let goal = requirements.map(\.text).joined(separator: ". ")
        let plan = try XCTUnwrap(AgentPlan(goal: goal, requirements: requirements, answerExpected: true))
        let engine = ScriptedEngine(choice: { request in
            ScriptedEngine.pick(request.candidates.first { $0.action.operation == .done })
        })
        return AgentRun(goal: goal, planner: FixedPlanner(plan: plan), errandID: UUID(),
                        collaborators: .init(bridge: bridge, engine: engine, writer: FakeWriter(), sheet: FixtureSheet(),
                                             confirm: { _ in .no }, log: { _ in }, model: model.model),
                        startPage: Self.preview)
    }

    /// Real fixture documents retain their URLs and network lock; only their displayed content is replaced.
    @MainActor
    private final class IdenticalListings: BrowserBridge {
        let inner = WebViewBridge()
        private var installedAt: String?
        private(set) var captures: [ErrandModel.Capture] = []
        private let blocks = ObserverScript.blocksSource(limit: ErrandModel.chunkLimit * AgentRun.maxReads)

        func openTab(_ url: URL) async throws -> BrowserTab { try await inner.openTab(url) }
        func closeTab(_ tab: BrowserTab) async throws { try await inner.closeTab(tab) }
        func isLoading(_ tab: BrowserTab) async throws -> Bool { try await inner.isLoading(tab) }
        func runAwaiting(_ javascript: String, in tab: BrowserTab) async throws -> String {
            try await inner.runAwaiting(javascript, in: tab)
        }

        func run(_ javascript: String, in tab: BrowserTab) async throws -> String {
            if javascript == ObserverScript.source || javascript == blocks {
                let address = try await inner.run("String(location.href)", in: tab)
                if address != installedAt {
                    let script = """
                    (() => {
                      document.title = 'Service hours';
                      document.body.innerHTML = '<main><p>Opening hours: 09:00 to 17:00.</p><p>Support hours: 10:00 to 16:00.</p></main>';
                      return 'ready';
                    })()
                    """
                    _ = try await inner.run(script, in: tab)
                    installedAt = address
                }
            }
            let result = try await inner.run(javascript, in: tab)
            if javascript == blocks, let capture = ErrandModel.Capture.decode(result) { captures.append(capture) }
            return result
        }
    }
}
