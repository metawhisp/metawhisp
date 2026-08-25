import SwiftData
import XCTest
@testable import MetaWhisp

/// ITER-071.2 — batch analysis consumes the canonical visits the live agent
/// writes; it does not rebuild them from app names and five-minute gaps.
/// Required cases 1-3 of the iteration plus the no-silent-drop rule.
@MainActor
final class ScreenExtractorCanonicalVisitsTests: XCTestCase {

    private func context(_ app: String, _ title: String, _ ocr: String,
                         at t: TimeInterval) -> ScreenContext {
        let c = ScreenContext(appName: app, windowTitle: title, ocrText: ocr)
        c.timestamp = Date(timeIntervalSince1970: t)
        return c
    }

    private func record(id: UUID = UUID(), app: String, title: String,
                        startedAt t: TimeInterval, generation: Int = 0,
                        frames: [UUID]) -> ContextVisitRecord {
        let r = ContextVisitRecord(
            id: id, generation: generation, bundleID: "test.\(app)", appName: app,
            rawTitle: title, normalizedTitle: title.lowercased(),
            startedAt: Date(timeIntervalSince1970: t))
        for f in frames { r.appendFrameID(f) }
        return r
    }

    /// Case 1: two windows of one app remain separate visits — the exact
    /// merge that attributed one conversation's facts to another.
    func testTwoWindowsOfOneAppStaySeparate() {
        let c1 = context("Slack", "#launch", "deck due friday", at: 100)
        let c2 = context("Slack", "#random", "lunch plans", at: 130)
        let visits = ScreenExtractor().canonicalVisits(
            for: [c1, c2],
            records: [
                record(app: "Slack", title: "#launch", startedAt: 100, frames: [c1.id]),
                record(app: "Slack", title: "#random", startedAt: 130, frames: [c2.id]),
            ])
        XCTAssertEqual(visits.count, 2)
        XCTAssertFalse(visits[0].ocrPreview.contains("lunch"),
                       "one channel's text must not bleed into the other's visit")
    }

    /// Case 2: same title, changed accepted frames — ONE visit, frames in
    /// order, preview accumulated across generations.
    func testSameTitleWithChangedFramesIsOneVisit() {
        let c1 = context("Mail", "Inbox", "3 unread", at: 100)
        let c2 = context("Mail", "Inbox", "invoice 2210 arrived", at: 200)
        let visits = ScreenExtractor().canonicalVisits(
            for: [c1, c2],
            records: [record(app: "Mail", title: "Inbox", startedAt: 100,
                             generation: 1, frames: [c1.id, c2.id])])
        XCTAssertEqual(visits.count, 1)
        XCTAssertEqual(visits.first?.lastContextId, c2.id)
        XCTAssertTrue(visits.first?.ocrPreview.contains("2210") == true)
    }

    /// Case 3: the canonical reader cannot merge what the coordinator split —
    /// membership comes from the records, not from matching app names.
    func testAppNameAloneCannotMerge() {
        let c1 = context("Safari", "Docs — quarterly plan", "q3 goals", at: 100)
        let c2 = context("Safari", "Jira — PROJ-142", "reassigned to you", at: 130)
        let visits = ScreenExtractor().canonicalVisits(
            for: [c1, c2],
            records: [
                record(app: "Safari", title: "Docs — quarterly plan", startedAt: 100, frames: [c1.id]),
                record(app: "Safari", title: "Jira — PROJ-142", startedAt: 130, frames: [c2.id]),
            ])
        XCTAssertEqual(visits.count, 2)
    }

    /// Pre-cutover rows carry no visit membership; they take the legacy
    /// collapse EXPLICITLY — processed, never silently dropped.
    func testUncoveredContextsFallBackInsteadOfVanishing() {
        let legacy = context("Xcode", "Project.swift", "let x = 1", at: 50)
        let c1 = context("Mail", "Inbox", "3 unread", at: 100)
        let visits = ScreenExtractor().canonicalVisits(
            for: [legacy, c1],
            records: [record(app: "Mail", title: "Inbox", startedAt: 100, frames: [c1.id])])
        XCTAssertEqual(visits.count, 2)
        XCTAssertEqual(visits.first?.appName, "Xcode", "ordered by start, nothing lost")
    }

    /// A record whose frames were all retention-pruned contributes nothing —
    /// and must not crash or fabricate an empty visit.
    func testARecordWithNoLiveFramesIsSkipped() {
        let c1 = context("Mail", "Inbox", "3 unread", at: 100)
        let visits = ScreenExtractor().canonicalVisits(
            for: [c1],
            records: [
                record(app: "Ghost", title: "Gone", startedAt: 10, frames: [UUID(), UUID()]),
                record(app: "Mail", title: "Inbox", startedAt: 100, frames: [c1.id]),
            ])
        XCTAssertEqual(visits.count, 1)
        XCTAssertEqual(visits.first?.appName, "Mail")
    }
}
