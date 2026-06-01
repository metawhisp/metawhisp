import XCTest
@testable import MetaWhisp

/// Pure-function tests for `ObsidianPath` helpers (ITER-035).
///
/// The exporter writes user content to disk — the slug/path computation is
/// where the worst bugs hide (path injection, lost Cyrillic codepoints, mid-
/// codepoint truncation). Tests pin behaviour so we can't accidentally regress
/// when we tweak.
final class ObsidianPathTests: XCTestCase {

    // Fixed test calendar (UTC) so dateFolder/timestampPrefix are deterministic.
    private var utcCal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func date(_ iso: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: iso)!
    }

    // AUD-043 — fixed UUIDs so id-suffixed paths are deterministic in tests.
    // shortID = first 8 hex chars of the uuidString, lowercased.
    private let id1 = UUID(uuidString: "A1B2C3D4-0000-0000-0000-000000000000")!  // → "a1b2c3d4"
    private let id2 = UUID(uuidString: "FFEEDDCC-1111-2222-3333-444455556666")!  // → "ffeeddcc"

    // MARK: - dateFolder

    func test_dateFolder_returnsISODate() {
        let d = date("2026-05-12T14:00:00Z")
        XCTAssertEqual(ObsidianPath.dateFolder(for: d, calendar: utcCal), "2026-05-12")
    }

    func test_dateFolder_padsSingleDigitMonthAndDay() {
        let d = date("2026-01-03T00:00:00Z")
        XCTAssertEqual(ObsidianPath.dateFolder(for: d, calendar: utcCal), "2026-01-03")
    }

    // MARK: - timestampPrefix

    func test_timestampPrefix_usesHFormat() {
        let d = date("2026-05-12T14:30:00Z")
        XCTAssertEqual(ObsidianPath.timestampPrefix(for: d, calendar: utcCal), "14h30")
    }

    func test_timestampPrefix_padsZeroMinute() {
        let d = date("2026-05-12T09:05:00Z")
        XCTAssertEqual(ObsidianPath.timestampPrefix(for: d, calendar: utcCal), "09h05")
    }

    // MARK: - slugForFilename — Latin happy path

    func test_slug_simpleLatin() {
        XCTAssertEqual(ObsidianPath.slugForFilename("Standup with Sam"), "standup-with-sam")
    }

    func test_slug_punctuationCollapses() {
        XCTAssertEqual(ObsidianPath.slugForFilename("What's up?!"), "what-s-up")
    }

    func test_slug_dotsBecomeDashes() {
        XCTAssertEqual(ObsidianPath.slugForFilename("metawhisp.com"), "metawhisp-com")
    }

    func test_slug_trimsLeadingTrailingDashes() {
        XCTAssertEqual(ObsidianPath.slugForFilename("---hello---"), "hello")
    }

    // MARK: - slugForFilename — Cyrillic preserved

    func test_slug_cyrillicPreserved() {
        XCTAssertEqual(ObsidianPath.slugForFilename("Купить продукты"), "купить-продукты")
    }

    func test_slug_mixedLanguages() {
        XCTAssertEqual(ObsidianPath.slugForFilename("Sam встретил Машу"), "sam-встретил-машу")
    }

    func test_slug_cyrillicWithPunctuation() {
        XCTAssertEqual(ObsidianPath.slugForFilename("Привет, мир!"), "привет-мир")
    }

    // MARK: - slugForFilename — emoji stripped

    func test_slug_emojiStripped() {
        XCTAssertEqual(ObsidianPath.slugForFilename("🚀 Launch v1.3.4 🎉"), "launch-v1-3-4")
    }

    func test_slug_onlyEmojisFallback() {
        XCTAssertEqual(ObsidianPath.slugForFilename("🎉🔥💀"), "untitled")
    }

    func test_slug_emptyStringFallback() {
        XCTAssertEqual(ObsidianPath.slugForFilename(""), "untitled")
    }

    func test_slug_whitespaceOnlyFallback() {
        XCTAssertEqual(ObsidianPath.slugForFilename("   \n\t "), "untitled")
    }

    // MARK: - slugForFilename — length cap

    func test_slug_capsAtMaxLength() {
        let long = String(repeating: "abc-", count: 50) // ~200 chars
        let slug = ObsidianPath.slugForFilename(long, maxLength: 60)
        XCTAssertLessThanOrEqual(slug.count, 60)
        XCTAssertFalse(slug.hasSuffix("-"))  // не оставляет хвостовой dash
    }

    func test_slug_capsAtMaxLengthCyrillic() {
        let long = String(repeating: "тест-", count: 40)
        let slug = ObsidianPath.slugForFilename(long, maxLength: 40)
        XCTAssertLessThanOrEqual(slug.count, 40)
        XCTAssertFalse(slug.hasSuffix("-"))
    }

    // MARK: - slugForFilename — keepingCase

    func test_slug_keepingCasePreservesCapitalization() {
        XCTAssertEqual(
            ObsidianPath.slugForFilename("MetaWhisp Project", keepingCase: true),
            "MetaWhisp-Project"
        )
    }

    // MARK: - projectFolderName

    func test_projectFolderName_nilReturnsGeneral() {
        XCTAssertEqual(ObsidianPath.projectFolderName(nil), "General")
    }

    func test_projectFolderName_emptyReturnsGeneral() {
        XCTAssertEqual(ObsidianPath.projectFolderName(""), "General")
        XCTAssertEqual(ObsidianPath.projectFolderName("   "), "General")
    }

    func test_projectFolderName_preservesCase() {
        XCTAssertEqual(ObsidianPath.projectFolderName("MetaWhisp"), "MetaWhisp")
    }

    func test_projectFolderName_sanitizesSpecialChars() {
        XCTAssertEqual(ObsidianPath.projectFolderName("acme.com / production"), "acme-com-production")
    }

    // MARK: - conversationProjectFolderName

    func test_conversationProjectFolderName_nilReturnsUntagged() {
        XCTAssertEqual(ObsidianPath.conversationProjectFolderName(nil), "Untagged")
    }

    func test_conversationProjectFolderName_preservesCase() {
        XCTAssertEqual(ObsidianPath.conversationProjectFolderName("MetaWhisp"), "MetaWhisp")
    }

    // MARK: - meetingPath

    func test_meetingPath_assembledCorrectly() {
        let d = date("2026-05-12T14:00:00Z")
        let p = ObsidianPath.meetingPath(date: d, title: "Standup with Sam", id: id1, calendar: utcCal)
        XCTAssertEqual(p, "MetaWhisp/2026-05-12/meetings/14h00--standup-with-sam--a1b2c3d4.md")
    }

    func test_meetingPath_emojiInTitleStrippedFromSlug() {
        let d = date("2026-05-12T09:00:00Z")
        let p = ObsidianPath.meetingPath(date: d, title: "🚀 Launch retrospective", id: id1, calendar: utcCal)
        XCTAssertEqual(p, "MetaWhisp/2026-05-12/meetings/09h00--launch-retrospective--a1b2c3d4.md")
    }

    // MARK: - voicePath

    func test_voicePath_withProject() {
        let d = date("2026-05-12T09:15:00Z")
        let p = ObsidianPath.voicePath(date: d, project: "MetaWhisp", id: id1, calendar: utcCal)
        XCTAssertEqual(p, "MetaWhisp/2026-05-12/voices/09h15--MetaWhisp--a1b2c3d4.md")
    }

    func test_voicePath_nilProjectGetsUntagged() {
        let d = date("2026-05-12T11:22:00Z")
        let p = ObsidianPath.voicePath(date: d, project: nil, id: id1, calendar: utcCal)
        XCTAssertEqual(p, "MetaWhisp/2026-05-12/voices/11h22--Untagged--a1b2c3d4.md")
    }

    // MARK: - taskPath

    func test_taskPath_includesIDAndSlug() {
        let d = date("2026-05-12T10:00:00Z")
        let p = ObsidianPath.taskPath(date: d, taskID: "T-0001", description: "Починить окно", calendar: utcCal)
        XCTAssertEqual(p, "MetaWhisp/2026-05-12/tasks/T-0001--починить-окно.md")
    }

    func test_taskPath_longDescriptionTruncated() {
        let d = date("2026-05-12T10:00:00Z")
        let longDesc = String(repeating: "fix the bug ", count: 20)
        let p = ObsidianPath.taskPath(date: d, taskID: "T-0042", description: longDesc, calendar: utcCal)
        XCTAssertTrue(p.hasPrefix("MetaWhisp/2026-05-12/tasks/T-0042--"))
        // Filename portion shouldn't blow the cap.
        XCTAssertTrue(p.count < 150, "path too long: \(p.count) chars")
    }

    // MARK: - memoryPath

    func test_memoryPath_projectFolderUsed() {
        let d = date("2026-05-12T09:15:00Z")
        let p = ObsidianPath.memoryPath(
            date: d, project: "MetaWhisp",
            content: "user prefers bullets",
            id: id1,
            calendar: utcCal
        )
        XCTAssertEqual(p, "MetaWhisp/Memories/MetaWhisp/2026-05-12--user-prefers-bullets--a1b2c3d4.md")
    }

    func test_memoryPath_nilProjectGetsGeneral() {
        let d = date("2026-05-12T11:22:00Z")
        let p = ObsidianPath.memoryPath(
            date: d, project: nil,
            content: "купил молоко",
            id: id1,
            calendar: utcCal
        )
        XCTAssertEqual(p, "MetaWhisp/Memories/General/2026-05-12--купил-молоко--a1b2c3d4.md")
    }

    // MARK: - insightPath

    func test_insightPath_prefersHeadline() {
        let d = date("2026-05-12T09:22:00Z")
        let p = ObsidianPath.insightPath(
            date: d,
            headline: "Credentials visible",
            body: "Some longer body that we don't want in filename",
            id: id1,
            calendar: utcCal
        )
        XCTAssertEqual(p, "MetaWhisp/Insights/2026-05-12/09h22--credentials-visible--a1b2c3d4.md")
    }

    func test_insightPath_fallsBackToBodyWhenNoHeadline() {
        let d = date("2026-05-12T09:22:00Z")
        let p = ObsidianPath.insightPath(
            date: d, headline: nil,
            body: "Wrong year — double-check",
            id: id1,
            calendar: utcCal
        )
        XCTAssertEqual(p, "MetaWhisp/Insights/2026-05-12/09h22--wrong-year-double-check--a1b2c3d4.md")
    }

    // MARK: - AUD-043 — stable id suffix prevents path collisions

    func test_shortID_isEightLowercaseHexChars() {
        XCTAssertEqual(ObsidianPath.shortID(id1), "a1b2c3d4")
        XCTAssertEqual(ObsidianPath.shortID(id2), "ffeeddcc")
    }

    /// The exact scenario from the audit: two dictations in the same minute for
    /// the same project. Before AUD-043 these resolved to ONE path and the second
    /// silently overwrote the first. The id suffix must keep them apart.
    func test_voicePath_sameMinuteSameProject_distinctIDs_giveDistinctPaths() {
        let d = date("2026-05-12T09:15:30Z")
        let p1 = ObsidianPath.voicePath(date: d, project: "MetaWhisp", id: id1, calendar: utcCal)
        let p2 = ObsidianPath.voicePath(date: d, project: "MetaWhisp", id: id2, calendar: utcCal)
        XCTAssertNotEqual(p1, p2, "same minute + project must not collide once the id is in the filename")
        XCTAssertTrue(p1.hasSuffix("--a1b2c3d4.md"))
        XCTAssertTrue(p2.hasSuffix("--ffeeddcc.md"))
    }

    func test_meetingPath_sameMinuteSameTitle_distinctIDs_giveDistinctPaths() {
        let d = date("2026-05-12T14:00:00Z")
        let p1 = ObsidianPath.meetingPath(date: d, title: "Standup", id: id1, calendar: utcCal)
        let p2 = ObsidianPath.meetingPath(date: d, title: "Standup", id: id2, calendar: utcCal)
        XCTAssertNotEqual(p1, p2)
    }

    func test_memoryPath_sameDaySameContent_distinctIDs_giveDistinctPaths() {
        let d = date("2026-05-12T09:15:00Z")
        let p1 = ObsidianPath.memoryPath(date: d, project: "MetaWhisp", content: "ship it", id: id1, calendar: utcCal)
        let p2 = ObsidianPath.memoryPath(date: d, project: "MetaWhisp", content: "ship it", id: id2, calendar: utcCal)
        XCTAssertNotEqual(p1, p2)
    }

    /// The hub FILE path and the wikilink TARGET that voices/tasks/memories point
    /// at must resolve to the same note — the wikilink is exactly the path minus
    /// `.md`. Both carry the same conversation id, so they must stay in lockstep.
    func test_conversationHub_pathAndWikilink_agreeForSameID() {
        let d = date("2026-05-12T14:32:00Z")
        let path = ObsidianPath.conversationHubPath(date: d, title: "Deploy discussion", id: id1, calendar: utcCal)
        let link = ObsidianPath.conversationHubWikilink(date: d, title: "Deploy discussion", id: id1, calendar: utcCal)
        XCTAssertEqual(path, link + ".md", "wikilink must be the hub file path without the .md extension")
    }

    /// Tasks already carried a stable taskID, so AUD-043 must NOT add a second id.
    func test_taskPath_unchangedByAUD043() {
        let d = date("2026-05-12T10:00:00Z")
        let p = ObsidianPath.taskPath(date: d, taskID: "T-0001", description: "Fix it", calendar: utcCal)
        XCTAssertEqual(p, "MetaWhisp/2026-05-12/tasks/T-0001--fix-it.md")
    }
}
