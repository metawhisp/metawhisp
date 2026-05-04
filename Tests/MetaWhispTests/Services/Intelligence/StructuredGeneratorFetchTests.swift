import XCTest
import SwiftData
@testable import MetaWhisp

/// Retroactive tests for `StructuredGenerator.fetchHistoryItems` —
/// the in-memory filter that replaced the flaky SwiftData predicate over
/// `Optional<UUID>`. Honest disclosure: I shipped the fix in a batch on
/// 2026-05-01 without writing the RED test first (user requested A→F all
/// at once). These tests pin the new behaviour AFTER the fact so future
/// regressions hit assertion failures, not silent "Quick note (empty)"
/// recap popups.
@MainActor
final class StructuredGeneratorFetchTests: XCTestCase {

    /// In-memory ModelContainer with the schema this helper needs.
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([HistoryItem.self, Conversation.self])
        let config = ModelConfiguration("Test", isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [config])
    }

    private func makeItem(text: String, conv: UUID?, secondsAgo: TimeInterval) -> HistoryItem {
        let item = HistoryItem(text: text, language: "en", audioDuration: 1.0, processingTime: 0.1)
        item.conversationId = conv
        item.createdAt = Date().addingTimeInterval(-secondsAgo)
        return item
    }

    /// 3 items linked to one conversation (in scrambled createdAt order),
    /// 2 items linked elsewhere/nil → fetch returns only the 3 linked,
    /// sorted by createdAt ascending.
    func test_fetchHistoryItems_returnsOnlyLinkedConversation_inOrder() throws {
        let container = try makeContainer()
        let ctx = ModelContext(container)
        let convId = UUID()
        let other = UUID()

        ctx.insert(makeItem(text: "third",  conv: convId, secondsAgo: 10))
        ctx.insert(makeItem(text: "first",  conv: convId, secondsAgo: 30))
        ctx.insert(makeItem(text: "second", conv: convId, secondsAgo: 20))
        ctx.insert(makeItem(text: "unrelated_other", conv: other,  secondsAgo: 15))
        ctx.insert(makeItem(text: "unrelated_nil",   conv: nil,    secondsAgo: 25))
        try ctx.save()

        let results = StructuredGenerator.fetchHistoryItems(conversationId: convId, in: ctx)
        XCTAssertEqual(results.map(\.text), ["first", "second", "third"])
    }

    /// No matching items → empty array (no crash, no fallback).
    func test_fetchHistoryItems_returnsEmptyForUnknownID() throws {
        let container = try makeContainer()
        let ctx = ModelContext(container)
        ctx.insert(makeItem(text: "x", conv: UUID(), secondsAgo: 10))
        ctx.insert(makeItem(text: "y", conv: nil,   secondsAgo: 20))
        try ctx.save()

        let results = StructuredGenerator.fetchHistoryItems(conversationId: UUID(), in: ctx)
        XCTAssertEqual(results.count, 0)
    }

    /// Items with nil conversationId never match a queried UUID. Guards
    /// against accidental `nil == nonNil` truthiness in the filter closure.
    func test_fetchHistoryItems_excludesItemsWithNilConversationId() throws {
        let container = try makeContainer()
        let ctx = ModelContext(container)
        let convId = UUID()
        ctx.insert(makeItem(text: "linked",      conv: convId, secondsAgo: 10))
        ctx.insert(makeItem(text: "orphan_nil",  conv: nil,    secondsAgo: 20))
        try ctx.save()

        let results = StructuredGenerator.fetchHistoryItems(conversationId: convId, in: ctx)
        XCTAssertEqual(results.map(\.text), ["linked"])
    }
}
