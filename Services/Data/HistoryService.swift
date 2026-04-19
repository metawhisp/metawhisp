import Foundation
import SwiftData
import os

/// Manages persistent transcription history via SwiftData.
@MainActor
final class HistoryService: ObservableObject {
    private static let log = Logger(subsystem: "com.metawhisp.app", category: "History")

    let modelContainer: ModelContainer

    init() {
        do {
            let schema = Schema([HistoryItem.self, ScreenContext.self, AdviceItem.self, UserMemory.self, TaskItem.self, ChatMessage.self, Conversation.self, ScreenObservation.self, IndexedFile.self])
            let config = ModelConfiguration("MetaWhisp", schema: schema)
            modelContainer = try ModelContainer(for: schema, configurations: [config])
            Self.log.info("History database ready")
        } catch {
            Self.log.error("Failed to create ModelContainer: \(error)")
            // Fallback: in-memory only
            do {
                modelContainer = try ModelContainer(
                    for: HistoryItem.self, ScreenContext.self, AdviceItem.self, UserMemory.self, TaskItem.self, ChatMessage.self, Conversation.self, ScreenObservation.self, IndexedFile.self,
                    configurations: ModelConfiguration(isStoredInMemoryOnly: true))
            } catch {
                Self.log.error("In-memory fallback also failed: \(error)")
                fatalError("Cannot create any ModelContainer — app cannot function without data storage")
            }
        }
    }

    /// Save a transcription result to history. Returns the item for further modification.
    @discardableResult
    func save(_ result: TranscriptionResult) -> HistoryItem? {
        let context = modelContainer.mainContext
        let item = HistoryItem(result: result)
        context.insert(item)
        do {
            try context.save()
            Self.log.info("Saved history item: \(item.wordCount) words")
            return item
        } catch {
            Self.log.error("Failed to save: \(error)")
            return nil
        }
    }

    /// Delete a single item.
    func delete(_ item: HistoryItem) {
        let context = modelContainer.mainContext
        context.delete(item)
        try? context.save()
    }

    /// Delete all history.
    func deleteAll() {
        let context = modelContainer.mainContext
        do {
            try context.delete(model: HistoryItem.self)
            try context.save()
            Self.log.info("All history deleted")
        } catch {
            Self.log.error("Failed to delete all: \(error)")
        }
    }
}
