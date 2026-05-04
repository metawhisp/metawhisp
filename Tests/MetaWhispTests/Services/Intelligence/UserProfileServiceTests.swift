import XCTest
@testable import MetaWhisp

/// TDD-driven tests for UserProfileService (spec://specs/TDD.md).
/// Service builds the "About Me" sections from UserMemory entries.
///
/// Rules covered here:
/// - kind == "person" memories are EXCLUDED (those are about other people).
/// - kind == "project" / "preference" / "decision" / "fact" go into matching sections.
/// - Legacy memories with nil kind fall into the FACTS section.
/// - Within a section, memories are sorted newest first.
@MainActor
final class UserProfileServiceTests: XCTestCase {

    private func mem(
        content: String,
        kind: String? = nil,
        subject: String? = nil,
        characterization: String? = nil,
        createdAt: Date = Date()
    ) -> UserMemory {
        let m = UserMemory(
            content: content,
            category: "system",
            sourceApp: "test",
            confidence: 0.9
        )
        m.kind = kind
        m.subject = subject
        m.characterization = characterization
        m.createdAt = createdAt
        return m
    }

    func test_buildSections_excludesPersonKind() {
        let inputs = [
            mem(content: "Sam works on community", kind: "person", subject: "Sam"),
            mem(content: "Alex handles backend", kind: "person", subject: "Alex"),
            mem(content: "User builds MetaWhisp", kind: "project", subject: "MetaWhisp"),
        ]
        let sections = UserProfileService.buildSections(from: inputs)
        let allEntries = sections.flatMap { $0.entries }
        XCTAssertFalse(allEntries.contains { $0.subject == "Sam" })
        XCTAssertFalse(allEntries.contains { $0.subject == "Alex" })
        XCTAssertTrue(allEntries.contains { $0.subject == "MetaWhisp" })
    }

    func test_buildSections_groupsByKind() {
        let inputs = [
            mem(content: "User builds MetaWhisp", kind: "project", subject: "MetaWhisp"),
            mem(content: "User prefers Cerebras LLM", kind: "preference"),
            mem(content: "Decided $30/year", kind: "decision"),
            mem(content: "User lives in Belgrade", kind: "fact"),
        ]
        let sections = UserProfileService.buildSections(from: inputs)
        let titleByKind = Dictionary(uniqueKeysWithValues: sections.map { ($0.kind, $0.title) })
        XCTAssertEqual(titleByKind["project"], "Projects")
        XCTAssertEqual(titleByKind["preference"], "Preferences")
        XCTAssertEqual(titleByKind["decision"], "Decisions")
        XCTAssertEqual(titleByKind["fact"], "Facts")
    }

    func test_buildSections_legacyNilKindGoesToFacts() {
        let inputs = [
            mem(content: "User is from Belgrade", kind: nil),
        ]
        let sections = UserProfileService.buildSections(from: inputs)
        let factsSection = sections.first { $0.kind == "fact" }
        XCTAssertNotNil(factsSection)
        XCTAssertEqual(factsSection?.entries.count, 1)
        XCTAssertEqual(factsSection?.entries.first?.content, "User is from Belgrade")
    }

    func test_buildSections_sortsByCreatedAtDesc() {
        let now = Date()
        let inputs = [
            mem(content: "old fact", kind: "fact", createdAt: now.addingTimeInterval(-3600)),
            mem(content: "new fact", kind: "fact", createdAt: now),
        ]
        let sections = UserProfileService.buildSections(from: inputs)
        let factsSection = sections.first { $0.kind == "fact" }
        XCTAssertEqual(factsSection?.entries.first?.content, "new fact")
        XCTAssertEqual(factsSection?.entries.last?.content, "old fact")
    }

    func test_buildSections_dropsEmptySections() {
        let inputs = [
            mem(content: "User builds MetaWhisp", kind: "project"),
        ]
        let sections = UserProfileService.buildSections(from: inputs)
        // Only sections with entries should appear; preferences/decisions/facts are absent here.
        XCTAssertEqual(sections.map { $0.kind }, ["project"])
    }

    func test_buildSections_skipsDismissedMemories() {
        let kept = mem(content: "User builds MetaWhisp", kind: "project")
        let dismissed = mem(content: "User builds OldThing", kind: "project")
        dismissed.isDismissed = true
        let sections = UserProfileService.buildSections(from: [kept, dismissed])
        let proj = sections.first { $0.kind == "project" }
        XCTAssertEqual(proj?.entries.count, 1)
        XCTAssertEqual(proj?.entries.first?.content, "User builds MetaWhisp")
    }
}
