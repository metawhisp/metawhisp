import XCTest

/// ITER-083 I1 — the save of a meeting reads only the recording's own
/// snapshot. The two AppDelegate fields it used to read (the call name and the
/// event id) were overwritten by the next recording before the earlier one was
/// saved; they are gone, and nothing on the save path reads live state.
final class MeetingIdentityGuardTests: XCTestCase {

    private func appDelegateSource() throws -> String {
        // …/Tests/MetaWhispTests/Guards/MeetingIdentityGuardTests.swift → repo root
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("App/AppDelegate.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func body(of signature: String, in source: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: signature), "\(signature) is gone — update the guard")
        // The function ends where the next member at the same indentation starts.
        let rest = source[start.upperBound...]
        let ends = ["\n    func ", "\n    private func ", "\n    @objc "].compactMap { rest.range(of: $0)?.lowerBound }
        return String(rest[..<(ends.min() ?? rest.endIndex)])
    }

    func testTheOverwrittenFieldsAreGone() throws {
        let source = try appDelegateSource()
        XCTAssertFalse(source.contains("currentMeetingCallContext"))
        XCTAssertFalse(source.contains("recordingCalendarEventID"))
    }

    func testTheSaveReadsNoLiveRecordingState() throws {
        let persist = try body(of: "private func persistMeetingTranscript(", in: try appDelegateSource())
        XCTAssertTrue(persist.contains("recording:"), "the snapshot is passed in")
        XCTAssertFalse(persist.contains("currentRecording"), "the live recording may already be the next one")
    }

    /// The stop freezes the recording before it clears anything, and every
    /// save path is handed that snapshot.
    func testTheStopSnapshotsBeforeItClearsAndEverySaveGetsIt() throws {
        let stop = try body(of: "private func stopMeetingRecording(", in: try appDelegateSource())
        let snapshot = try XCTUnwrap(stop.range(of: "let recording = currentRecording?.stopped(at: Date(), outcome: outcome)"))
        let clear = try XCTUnwrap(stop.range(of: "currentRecording = nil"))
        XCTAssertLessThan(snapshot.lowerBound, clear.lowerBound)
        XCTAssertEqual(stop.components(separatedBy: "self.persistMeetingTranscript(").count - 1, 3)
        XCTAssertEqual(stop.components(separatedBy: "recording: recording)").count - 1, 3,
                       "Deepgram, Gemini and the dual-stream save each pass the snapshot")
    }

    /// Every reader of a transcript reads its parts in recording order.
    func testEveryTranscriptReaderUsesRecordingOrder() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        for path in ["App/AppDelegate.swift", "Views/Windows/ConversationDetailView.swift",
                     "Views/Windows/ConversationsView.swift", "Services/Export/ObsidianExporter.swift",
                     "Services/Indexing/MeetingObsidianWriter.swift", "Services/Intelligence/StructuredGenerator.swift",
                     "Services/Intelligence/EmbeddingService.swift", "Services/Intelligence/DailySummaryService.swift"] {
            let source = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            XCTAssertTrue(source.contains("HistoryItem.inRecordingOrder"), path)
        }
    }

    /// Every guessing entry point (the close, the summary, the launch backfill)
    /// goes through `linkConversation`; it needs EventKit, so the call site is
    /// guarded here and the rule itself is tested in `MeetingRecordingAssignTests`.
    func testTheLinkerAsksBeforeGuessing() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Services/Indexing/CalendarReaderService.swift")
        let link = try body(of: "func linkConversation(", in: try String(contentsOf: url, encoding: .utf8))
        XCTAssertTrue(link.contains("guard Self.mayGuessEvent(for: conv) else { return }"))
    }

    /// The gate is told occurrences: one day's daily is not the next day's.
    func testTheGateIsToldOccurrences() throws {
        let source = try appDelegateSource()
        XCTAssertTrue(source.contains("startingOccurrence.map(\\.gateEvent)"))
        XCTAssertTrue(source.contains("runningOccurrence.map(\\.gateEvent)"))
        XCTAssertFalse(source.contains("(id: $0.eventID, title: $0.title)"))
    }
}
