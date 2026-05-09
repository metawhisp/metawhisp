import Foundation

/// Decides the final `Conversation.title` displayed everywhere (Library row,
/// Obsidian filename, conversation detail header, daily summary aggregation).
///
/// Calendar event title — the name the USER typed in their calendar — has
/// priority over the LLM-generated title. The LLM title is only a fallback
/// for recordings without a calendar link (manual record / fallback path /
/// no calendar permission). Without this, `StructuredGenerator` would
/// overwrite "Standup C" with whatever theme it inferred from the
/// transcript ("Discussing Project Updates And Marketing"), losing the
/// user's own naming convention.
///
/// Pure function so it's reasoned about without I/O. Bug history in
/// `specs/health-reports/2026-05-07-morning.md` and the WAL ITER-028 entry.
enum ConversationTitleResolver {
    static func resolve(calendarEventTitle: String?, llmTitle: String) -> String {
        if let cal = calendarEventTitle, !cal.isEmpty {
            return cal
        }
        return llmTitle
    }
}
