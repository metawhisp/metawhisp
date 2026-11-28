import SwiftData
import XCTest
@testable import MetaWhisp

/// T4 (owner, 2026-11-25), fixed at its cause 2026-11-26 («Yes, fix it»): a call or a dictation never creates a
/// project. The model's project name is kept only when it is one of the user's projects; anything else leaves the
/// conversation without a project. Before: every unknown name became a new project — 166 of 191 were used once.
@MainActor
final class ProjectNoInventionTests: XCTestCase {

    private var container: ModelContainer!
    private var aggregator: ProjectAggregator!

    override func setUpWithError() throws {
        let schema = Schema(versionedSchema: MetaWhispSchemaV10.self)
        container = try ModelContainer(for: schema, migrationPlan: MetaWhispMigrationPlan.self,
                                       configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        aggregator = ProjectAggregator()
        aggregator.configure(modelContainer: container)
    }

    private func rows() throws -> [ProjectAlias] { try ModelContext(container).fetch(FetchDescriptor<ProjectAlias>()) }

    private func addProject(_ name: String) throws {
        let ctx = ModelContext(container)
        ctx.insert(ProjectAlias(canonicalName: name))
        try ctx.save()
    }

    func testAnUnknownNameCreatesNothing() throws {
        XCTAssertNil(aggregator.existingCanonical(for: "Brand New Thing"))
        XCTAssertTrue(try rows().isEmpty, "no project is made from a call")
    }

    func testAKnownNameIsTheProjectsOwnName() throws {
        try addProject("Acme")
        XCTAssertEqual(aggregator.existingCanonical(for: "acme"), "Acme")
        XCTAssertEqual(aggregator.existingCanonical(for: "ACME"), "Acme")
        XCTAssertNil(aggregator.existingCanonical(for: "Acme Rockets"), "a different project is not this one")
        XCTAssertEqual(try rows().count, 1)
    }

    func testASpellingOfAnExistingProjectJoinsIt() throws {
        try addProject("Acme")
        XCTAssertEqual(aggregator.existingCanonical(for: "Acme."), "Acme")
        XCTAssertEqual(try rows().count, 1, "joined, not a second project")
    }

    /// The summary step writes a project only through the non-creating lookup.
    func testTheSummaryStepCannotCreateAProject() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../..").standardized
        let generator = try String(contentsOf: root.appendingPathComponent("Services/Intelligence/StructuredGenerator.swift"),
                                   encoding: .utf8)
        XCTAssertFalse(generator.contains("resolveCanonical"))
        XCTAssertFalse(generator.contains("ProjectAlias("))
        XCTAssertTrue(generator.contains("existingCanonical(for:"))
        let aggregatorSource = try String(contentsOf: root.appendingPathComponent("Services/Intelligence/ProjectAggregator.swift"),
                                          encoding: .utf8)
        XCTAssertFalse(aggregatorSource.contains("func resolveCanonical"), "the creating resolver is gone")
    }

    /// The model is told the user's projects and that it may not name a new one.
    func testThePromptListsEveryProjectAndForbidsNewNames() {
        let hint = ExistingProjectCatalog.promptHint(from: [("Acme", 12), ("Side Thing", 1), ("Agent Repo", 0)])
        XCTAssertTrue(hint.contains("- Acme"))
        XCTAssertTrue(hint.contains("- Side Thing"))
        XCTAssertTrue(hint.contains("- Agent Repo"), "a project an agent made has no conversations yet and still counts")
        XCTAssertTrue(hint.contains("null"))
        XCTAssertFalse(hint.lowercased().contains("invent a new"))
    }
}
