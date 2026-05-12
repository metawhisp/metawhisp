import XCTest
@testable import MetaWhisp

/// Pure-function tests for `ObsidianMarkdownRenderer` (ITER-035). One renderer
/// per entity type; assertions check frontmatter shape + body structure. We
/// don't lock the exact whitespace layout — those tests would break on every
/// cosmetic edit. We lock the things that **matter for Obsidian indexing**:
/// frontmatter keys, types, mandatory tags, wikilinks.
final class ObsidianMarkdownRendererTests: XCTestCase {

    private let fixedID = UUID(uuidString: "8a4b1c00-0000-0000-0000-000000000001")!
    private let fixedConvID = UUID(uuidString: "8a4b1c00-0000-0000-0000-00000000CCCC")!
    private let fixedDate: Date = {
        var c = DateComponents()
        c.year = 2026; c.month = 5; c.day = 12
        c.hour = 14; c.minute = 30; c.second = 0
        c.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: c)!
    }()

    // MARK: - Voice

    func test_renderVoice_minimumFieldsHasFrontmatter() {
        let v = ObsidianMarkdownRenderer.VoiceInput(
            id: fixedID,
            createdAt: fixedDate,
            project: nil,
            conversationId: nil,
            language: "ru",
            sourceApp: nil,
            textRaw: "купить продукты завтра",
            textProcessed: nil,
            durationSec: 3.5
        )
        let out = ObsidianMarkdownRenderer.renderVoice(v)
        XCTAssertTrue(out.hasPrefix("---\n"))
        XCTAssertTrue(out.contains("type: voice"))
        XCTAssertTrue(out.contains("id: \(fixedID.uuidString)"))
        XCTAssertTrue(out.contains("language: ru"))
        XCTAssertTrue(out.contains("duration_sec: 3.5"))
        XCTAssertTrue(out.contains("tags: [voice, metawhisp]"))
        XCTAssertTrue(out.contains("купить продукты завтра"))
        XCTAssertFalse(out.contains("project:"), "no project field when nil")
    }

    func test_renderVoice_projectAddedWhenPresent() {
        let v = ObsidianMarkdownRenderer.VoiceInput(
            id: fixedID, createdAt: fixedDate,
            project: "MetaWhisp", conversationId: fixedConvID,
            language: "en", sourceApp: "Claude",
            textRaw: "raw text", textProcessed: "cleaned text",
            durationSec: nil
        )
        let out = ObsidianMarkdownRenderer.renderVoice(v)
        XCTAssertTrue(out.contains("project: \"MetaWhisp\""))
        XCTAssertTrue(out.contains("conversation_id: \(fixedConvID.uuidString)"))
        XCTAssertTrue(out.contains("source_app: \"Claude\""))
        // Both raw + processed present and processed differs → show Cleaned section
        XCTAssertTrue(out.contains("## Cleaned"))
        XCTAssertTrue(out.contains("cleaned text"))
        XCTAssertTrue(out.contains("## Raw transcription"))
        XCTAssertTrue(out.contains("raw text"))
        // Wikilink to conversation
        XCTAssertTrue(out.contains("[[Conversations/\(fixedConvID.uuidString)]]"))
    }

    func test_renderVoice_dropsCleanedSectionWhenSameAsRaw() {
        let v = ObsidianMarkdownRenderer.VoiceInput(
            id: fixedID, createdAt: fixedDate,
            project: nil, conversationId: nil,
            language: nil, sourceApp: nil,
            textRaw: "same text", textProcessed: "same text",
            durationSec: nil
        )
        let out = ObsidianMarkdownRenderer.renderVoice(v)
        XCTAssertFalse(out.contains("## Cleaned"))
        XCTAssertTrue(out.contains("## Raw transcription"))
    }

    // MARK: - Meeting

    func test_renderMeeting_fullPayload() {
        let m = ObsidianMarkdownRenderer.MeetingInput(
            id: fixedID,
            title: "Standup with Sam",
            emoji: "💬",
            startedAt: fixedDate,
            finishedAt: fixedDate.addingTimeInterval(1800),
            calendarEventTitle: "Weekly standup",
            calendarAttendees: ["Sam Smith", "Alex Lee"],
            overview: "Discussed Q2 roadmap.",
            actionItems: ["Send recap to team", "Update PRD"],
            memoriesInline: ["Sam prefers async updates"],
            fullTranscript: "Alex: ...\nSam: ..."
        )
        let out = ObsidianMarkdownRenderer.renderMeeting(m)
        XCTAssertTrue(out.contains("type: meeting"))
        XCTAssertTrue(out.contains("calendar_event: \"Weekly standup\""))
        XCTAssertTrue(out.contains("attendees:"))
        XCTAssertTrue(out.contains("- \"Sam Smith\""))
        XCTAssertTrue(out.contains("- \"Alex Lee\""))
        XCTAssertTrue(out.contains("# 💬 Standup with Sam"))
        XCTAssertTrue(out.contains("## Summary"))
        XCTAssertTrue(out.contains("Discussed Q2 roadmap."))
        XCTAssertTrue(out.contains("## Action items"))
        XCTAssertTrue(out.contains("- [ ] Send recap to team"))
        XCTAssertTrue(out.contains("## Memories from this meeting"))
        XCTAssertTrue(out.contains("- Sam prefers async updates"))
        XCTAssertTrue(out.contains("## Transcript"))
    }

    func test_renderMeeting_titleWithoutEmoji() {
        let m = ObsidianMarkdownRenderer.MeetingInput(
            id: fixedID, title: "Quick sync", emoji: nil,
            startedAt: fixedDate, finishedAt: nil,
            calendarEventTitle: nil, calendarAttendees: [],
            overview: nil, actionItems: [], memoriesInline: [],
            fullTranscript: nil
        )
        let out = ObsidianMarkdownRenderer.renderMeeting(m)
        XCTAssertTrue(out.contains("# Quick sync"))
        XCTAssertFalse(out.contains("## Summary"))
        XCTAssertFalse(out.contains("## Action items"))
        XCTAssertFalse(out.contains("attendees:"))
    }

    // MARK: - Task

    func test_renderTask_open() {
        let t = ObsidianMarkdownRenderer.TaskInput(
            id: fixedID, taskID: "T-0001",
            description: "Починить окно",
            createdAt: fixedDate,
            dueAt: fixedDate.addingTimeInterval(86400),
            completed: false,
            assignee: nil, priority: "high",
            project: "MetaWhisp",
            conversationId: fixedConvID,
            sourceApp: "Claude"
        )
        let out = ObsidianMarkdownRenderer.renderTask(t)
        XCTAssertTrue(out.contains("type: task"))
        XCTAssertTrue(out.contains("task_id: T-0001"))
        XCTAssertTrue(out.contains("completed: false"))
        XCTAssertTrue(out.contains("priority: high"))
        XCTAssertTrue(out.contains("project: \"MetaWhisp\""))
        XCTAssertTrue(out.contains("# [ ] T-0001: Починить окно"))
        XCTAssertTrue(out.contains("**Due:**"))
        XCTAssertTrue(out.contains("[[Conversations/\(fixedConvID.uuidString)]]"))
    }

    func test_renderTask_completedHasCheckedBox() {
        let t = ObsidianMarkdownRenderer.TaskInput(
            id: fixedID, taskID: "T-0099",
            description: "Done thing",
            createdAt: fixedDate, dueAt: nil,
            completed: true,
            assignee: "Sam", priority: nil, project: nil,
            conversationId: nil, sourceApp: nil
        )
        let out = ObsidianMarkdownRenderer.renderTask(t)
        XCTAssertTrue(out.contains("completed: true"))
        XCTAssertTrue(out.contains("# [x] T-0099: Done thing"))
        XCTAssertTrue(out.contains("**Assignee:** Sam"))
        XCTAssertFalse(out.contains("**Due:**"))
    }

    // MARK: - Memory

    func test_renderMemory_structured() {
        let m = ObsidianMarkdownRenderer.MemoryInput(
            id: fixedID,
            content: "Sam prefers async updates",
            headline: "Sam — async pref",
            reasoning: "Mentioned during Q1 standup",
            category: "system",
            kind: "person", subject: "Sam Smith",
            characterization: "Prefers async-first comms.",
            project: "MetaWhisp",
            sourceApp: "Slack",
            confidence: 0.92,
            createdAt: fixedDate,
            tagsCSV: "team, comms",
            conversationId: fixedConvID
        )
        let out = ObsidianMarkdownRenderer.renderMemory(m)
        XCTAssertTrue(out.contains("type: memory"))
        XCTAssertTrue(out.contains("kind: person"))
        XCTAssertTrue(out.contains("subject: \"Sam Smith\""))
        XCTAssertTrue(out.contains("project: \"MetaWhisp\""))
        XCTAssertTrue(out.contains("confidence: 0.92"))
        XCTAssertTrue(out.contains("tags: [memory, metawhisp, team, comms]"))
        XCTAssertTrue(out.contains("# Sam — async pref"))
        XCTAssertTrue(out.contains("Prefers async-first comms."))
        XCTAssertTrue(out.contains("## Reasoning"))
        XCTAssertTrue(out.contains("[[Conversations/\(fixedConvID.uuidString)]]"))
    }

    func test_renderMemory_minimal() {
        let m = ObsidianMarkdownRenderer.MemoryInput(
            id: fixedID,
            content: "User drinks coffee in the morning",
            headline: nil, reasoning: nil, category: "system",
            kind: nil, subject: nil, characterization: nil,
            project: nil, sourceApp: "MetaWhisp",
            confidence: 0.7, createdAt: fixedDate,
            tagsCSV: nil, conversationId: nil
        )
        let out = ObsidianMarkdownRenderer.renderMemory(m)
        XCTAssertTrue(out.contains("tags: [memory, metawhisp]"))
        XCTAssertFalse(out.contains("kind:"))
        XCTAssertFalse(out.contains("subject:"))
        XCTAssertFalse(out.contains("project:"))
        XCTAssertTrue(out.contains("# User drinks coffee in the morning"))
        XCTAssertFalse(out.contains("## Reasoning"))
    }

    // MARK: - Insight

    func test_renderInsight_full() {
        let i = ObsidianMarkdownRenderer.InsightInput(
            id: fixedID,
            body: "You stashed changes 2 hours ago — run git stash pop",
            headline: "Stashed changes 2h ago",
            reasoning: "Terminal shows old stash entry from earlier today",
            category: "productivity",
            sourceApp: "Terminal",
            confidence: 0.95,
            createdAt: fixedDate
        )
        let out = ObsidianMarkdownRenderer.renderInsight(i)
        XCTAssertTrue(out.contains("type: insight"))
        XCTAssertTrue(out.contains("category: productivity"))
        XCTAssertTrue(out.contains("tags: [insight, metawhisp, productivity]"))
        XCTAssertTrue(out.contains("# Stashed changes 2h ago"))
        XCTAssertTrue(out.contains("You stashed changes 2 hours ago"))
        XCTAssertTrue(out.contains("## Why"))
        XCTAssertTrue(out.contains("confidence: 0.95"))
    }

    func test_renderInsight_noHeadlineFallsBackToGenericTitle() {
        let i = ObsidianMarkdownRenderer.InsightInput(
            id: fixedID,
            body: "Wrong year — double-check",
            headline: nil, reasoning: nil,
            category: "communication", sourceApp: "Mail",
            confidence: 0.8, createdAt: fixedDate
        )
        let out = ObsidianMarkdownRenderer.renderInsight(i)
        XCTAssertTrue(out.contains("# Insight"))
        XCTAssertTrue(out.contains("Wrong year — double-check"))
    }

    // MARK: - YAML escaping

    func test_yamlString_escapesQuotes() {
        let out = ObsidianMarkdownRenderer.yamlString("Project \"Phoenix\"")
        XCTAssertEqual(out, "\"Project \\\"Phoenix\\\"\"")
    }

    func test_yamlString_collapsesNewlines() {
        let out = ObsidianMarkdownRenderer.yamlString("line one\nline two")
        XCTAssertEqual(out, "\"line one line two\"")
    }
}
