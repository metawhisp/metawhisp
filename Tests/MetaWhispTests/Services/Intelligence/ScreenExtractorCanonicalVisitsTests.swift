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
            // The production normalizer, not a hand-rolled lowercase: the
            // fixture must describe what the writer actually stores.
            rawTitle: title, normalizedTitle: WindowTitleNormalizer.normalize(title),
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

    /// The honesty rule: a slice reports the time it actually saw. A visit
    /// that began before this hour, with one frame inside it, must not claim
    /// the earlier minutes — the day report sums these.
    func testASliceReportsOnlyTheTimeItSaw() {
        let seen = context("Docs", "Draft", "draft v2", at: 10_005)
        let r = record(app: "Docs", title: "Draft", startedAt: 9_950, frames: [UUID(), seen.id])
        r.lastObservedAt = Date(timeIntervalSince1970: 10_005)
        let visits = ScreenExtractor().canonicalVisits(for: [seen], records: [r])
        XCTAssertEqual(visits.count, 1)
        XCTAssertEqual(visits.first?.startedAt, seen.timestamp,
                       "the fifteen minutes before this page began were not observed here")
        XCTAssertEqual(visits.first?.endedAt, seen.timestamp)
    }

    /// The frame list holds 32; a longer visit drops its oldest ids. Those
    /// rows must stay part of the visit, not reappear as a second one.
    func testAVisitLongerThanTheFrameCapStaysOneVisit() {
        let frames = (0 ..< 40).map { context("Mail", "Inbox", "msg \($0)", at: 1000 + Double($0) * 30) }
        let r = record(app: "Mail", title: "Inbox", startedAt: 1000,
                       frames: Array(frames.suffix(32).map(\.id)))
        r.lastObservedAt = Date(timeIntervalSince1970: 1000 + 39 * 30)
        let visits = ScreenExtractor().canonicalVisits(for: frames, records: [r])
        XCTAssertEqual(visits.count, 1,
                       "the evicted frames belong to this visit, not to a second one")
        XCTAssertEqual(visits.first?.startedAt, frames.first?.timestamp)
    }

    /// ITER-071.3 — an ordered page: the batch is the OLDEST visits and the
    /// checkpoint is the last moment consumed, so what does not fit is the
    /// next page rather than something quietly dropped.
    func testTheBatchIsTheOldestVisitsSoNothingIsSkipped() throws {
        let cap = ScreenExtractor.maxVisitsPerBatchForTests
        // cap + 3 visits, each its own window, one minute apart.
        let contexts = (0 ..< (cap + 3)).map {
            context("App\($0)", "Window \($0)", "text \($0)", at: 1000 + Double($0) * 60)
        }
        let records = contexts.enumerated().map { i, c in
            record(app: "App\(i)", title: "Window \(i)",
                   startedAt: 1000 + Double(i) * 60, frames: [c.id])
        }
        let visits = ScreenExtractor().canonicalVisits(for: contexts, records: records)
        XCTAssertEqual(visits.count, cap + 3)

        let batch = Array(visits.prefix(cap))
        XCTAssertEqual(batch.first?.appName, "App0",
                       "the oldest visit must be in the batch, not stranded behind the checkpoint")
        let checkpoint = try XCTUnwrap(batch.last?.endedAt)
        for visit in visits.dropFirst(cap) {
            XCTAssertGreaterThan(visit.startedAt, checkpoint,
                                 "a deferred visit must still be ahead of the checkpoint")
        }
    }

    // MARK: - one fact, one row

    /// The live store holds three identical copies of the same sentence and
    /// several rewordings of it. Both paths are closed by the rule the
    /// director already uses for headlines.
    func testTheSameFactInDifferentWordsIsOneFact() {
        let pairs = [
            ("User tracks launches in Linear", "User uses Linear to track launches"),
            ("User conducts SEO analysis for sigmabrowser.com",
             "User does SEO analysis for sigmabrowser.com"),
            ("Пользователь готовит презентацию к запуску",
             "Пользователь готовит презентацию для запуска"),
        ]
        for (a, b) in pairs {
            XCTAssertTrue(ScreenAgentDirector.isNearDuplicate(a, b),
                          "«\(a)» and «\(b)» are the same fact")
        }
    }

    /// And genuinely different facts stay separate — a dedup that swallows
    /// everything is worse than none.
    func testDifferentFactsAreNotMerged() {
        XCTAssertFalse(ScreenAgentDirector.isNearDuplicate(
            "User tracks launches in Linear",
            "User pays for Linear with the company card"))
        XCTAssertFalse(ScreenAgentDirector.isNearDuplicate(
            "User conducts SEO audits for Atomic Wallet",
            "User conducts SEO analysis for sigmabrowser.com"))
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
