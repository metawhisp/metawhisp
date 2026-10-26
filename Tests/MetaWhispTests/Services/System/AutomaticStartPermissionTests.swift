import SwiftData
import XCTest
@testable import MetaWhisp

/// Step-1 review #1 — an automatic start (launch, a timer, a meeting the
/// calendar or a call window starts, a mid-meeting join) only reads a
/// permission; when it is missing it stays off with its existing reason, and
/// nothing is asked. Only an explicit user action — it holds a `PermissionAsk`
/// — may ask. Every permission here is the test's own: no test can show a
/// prompt, capture the screen, read a calendar or start Notes.
@MainActor
final class AutomaticStartPermissionTests: XCTestCase {
    private var saved: (calendar: Bool, notes: Bool, key: String, provider: String)!

    override func setUpWithError() throws {
        let settings = AppSettings.shared
        saved = (settings.calendarReaderEnabled, settings.appleNotesEnabled, settings.openaiKey, settings.llmProvider)
        settings.calendarReaderEnabled = true
        settings.appleNotesEnabled = true
        settings.llmProvider = "openai"
        settings.openaiKey = "sk-test"          // the readers' LLM gate
    }

    override func tearDownWithError() throws {
        let settings = AppSettings.shared
        settings.calendarReaderEnabled = saved.calendar
        settings.appleNotesEnabled = saved.notes
        settings.openaiKey = saved.key
        settings.llmProvider = saved.provider
    }

    private func spin() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    }

    private func store() throws -> ModelContainer {
        try ModelContainer(for: Schema(versionedSchema: MetaWhispSchemaV9.self),
                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    // MARK: - Screen Recording: screen context

    func testScreenContextStartedAtLaunchWithoutPermissionAsksNothing() {
        let screen = ScreenContextService()
        var asks = 0
        screen.screenRecordingGranted = { false }
        screen.askForScreenRecording = { _ in asks += 1; return false }
        screen.startMonitoring(interval: 30)       // what setupServices does when it is enabled
        spin()
        XCTAssertEqual(asks, 0)
        XCTAssertFalse(screen.isActive)
        XCTAssertEqual(screen.lastCaptureOutcome, .permissionDenied, "off, with its reason")
    }

    /// The release: the grant, whenever it comes, starts what launch left off.
    func testAScreenContextLeftOffAtLaunchStartsOnceGranted() {
        let screen = ScreenContextService()
        screen.screenRecordingGranted = { false }
        screen.askForScreenRecording = { _ in XCTFail("nothing asks"); return false }
        screen.startMonitoring(interval: 30)
        var starts = 0
        let reactions = PermissionReactions(rearmGlobalKeys: {}, rearmLayoutFix: { "" }, refreshSettings: {},
                                            screenContextShouldStart: { !screen.isActive },
                                            startScreenContext: { starts += 1 })
        reactions.screenRecording(.granted)
        XCTAssertEqual(starts, 1)
    }

    func testTheSettingsSwitchAsks() {
        let screen = ScreenContextService()
        var asks = 0
        screen.screenRecordingGranted = { false }
        screen.askForScreenRecording = { _ in asks += 1; return false }
        screen.startMonitoring(interval: 30, ask: PermissionAsk())
        spin()
        XCTAssertEqual(asks, 1)
        XCTAssertFalse(screen.isActive, "refused: it stays off")
    }

    // MARK: - Screen Recording: meetings

    func testAnAutomaticMeetingStartAsksForNoScreenRecording() {
        let system = SystemAudioCaptureService()
        var asks = 0
        system.screenRecordingGranted = { false }
        system.askForScreenRecording = { _ in asks += 1; return false }
        try? system.start()                         // an auto-started meeting
        spin()
        try? system.start(leadingSilenceSeconds: 30)  // a mid-meeting join
        spin()
        XCTAssertEqual(asks, 0)
        XCTAssertFalse(system.isStarting)
        XCTAssertNotNil(system.lastError, "it stays off with its reason")
    }

    func testTheUsersRecordAsks() {
        let system = SystemAudioCaptureService()
        var asks = 0
        system.screenRecordingGranted = { false }
        system.askForScreenRecording = { _ in asks += 1; return false }
        try? system.start(leadingSilenceSeconds: 0, ask: PermissionAsk())
        spin()
        XCTAssertEqual(asks, 1)
    }

    // MARK: - Calendar

    func testATimedCalendarScanAsksForNoAccess() async throws {
        let calendar = CalendarReaderService()
        calendar.configure(modelContainer: try store())
        var asks = 0
        calendar.accessGranted = { false }
        calendar.askForAccess = { _ in asks += 1; return false }
        await calendar.scanNow()                    // what the periodic timer runs
        XCTAssertEqual(asks, 0)
        XCTAssertNotNil(calendar.lastError)
    }

    func testScanNowAsks() async throws {
        let calendar = CalendarReaderService()
        calendar.configure(modelContainer: try store())
        var asks = 0
        calendar.accessGranted = { false }
        calendar.askForAccess = { _ in asks += 1; return false }   // refused, so nothing is read
        await calendar.scanNow(ask: PermissionAsk())
        XCTAssertEqual(asks, 1)
    }

    // MARK: - Automation: Notes

    func testATimedNotesScanRunsNoScriptWithoutPermission() async throws {
        let notes = AppleNotesReaderService()
        notes.configure(modelContainer: try store())
        var runs = 0
        notes.automationAllowed = { false }
        notes.runScript = { _ in runs += 1; return "" }
        await notes.scanNow()                       // what the periodic timer runs
        XCTAssertEqual(runs, 0)
        XCTAssertNotNil(notes.lastError)
    }

    func testATimedNotesScanRunsWhenNotesAccessIsConfirmed() async throws {
        let notes = AppleNotesReaderService()
        notes.configure(modelContainer: try store())
        var runs = 0
        notes.automationAllowed = { true }
        notes.runScript = { _ in runs += 1; return "" }
        await notes.scanNow()
        XCTAssertEqual(runs, 1)
    }

    func testNotesScanNowRunsTheScript() async throws {
        let notes = AppleNotesReaderService()
        notes.configure(modelContainer: try store())
        var runs = 0
        notes.automationAllowed = { false }
        notes.runScript = { _ in runs += 1; return "" }
        await notes.scanNow(ask: PermissionAsk())
        XCTAssertEqual(runs, 1, "the user pressed SCAN NOW: the script may ask")
    }

    // MARK: - Notes: one scan at a time

    /// Round-2 N2: SCAN NOW while a timed scan is still asking whether Notes
    /// access is confirmed. The timed scan, answered yes after the manual one
    /// started, must not start a second scan beside it — both would read the
    /// same notes and save the same memories twice.
    func testATimedScanWhoseAccessCheckOutlastsAManualScanStartsNoSecond() async throws {
        let notes = AppleNotesReaderService()
        notes.configure(modelContainer: try store())
        let access = Held<Bool>()
        let script = Held<String>()
        var runs = 0
        notes.automationAllowed = { await access.wait() }
        notes.runScript = { _ in runs += 1; return await script.wait() }

        var timedEnded = false
        let timed = Task { await notes.scanNow(); timedEnded = true }
        await until { access.isWaiting }
        let manual = Task { await notes.scanNow(ask: PermissionAsk()) }
        await until { runs == 1 }               // the manual scan is reading Notes
        access.open(true)                       // the timed scan's answer comes in
        await until { timedEnded || runs == 2 }
        script.open("")
        await timed.value
        await manual.value
        XCTAssertEqual(runs, 1, "one scan ran")
        XCTAssertFalse(notes.isRunning)

        // Nothing stays claimed: the next timed scan runs.
        await notes.scanNow()
        XCTAssertEqual(runs, 2)
    }

    /// The release: a timed scan refused at the access check claims nothing,
    /// so the next scan runs.
    func testAfterARefusedAccessCheckTheNextScanRuns() async throws {
        let notes = AppleNotesReaderService()
        notes.configure(modelContainer: try store())
        var runs = 0
        var allowed = false
        notes.automationAllowed = { allowed }
        notes.runScript = { _ in runs += 1; return "" }
        await notes.scanNow()
        XCTAssertEqual(runs, 0)
        XCTAssertFalse(notes.isRunning)
        allowed = true
        await notes.scanNow()
        XCTAssertEqual(runs, 1, "the next timed scan runs")
        await notes.scanNow(ask: PermissionAsk())
        XCTAssertEqual(runs, 2, "and so does SCAN NOW")
    }

    /// Spins until the condition holds, for at most two seconds.
    private func until(_ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(2)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}

/// An answer the test gives when it chooses; every wait before then is held,
/// and every wait after it gets the answer at once.
private final class Held<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [CheckedContinuation<T, Never>] = []
    private var answer: T?

    var isWaiting: Bool { lock.withLock { !waiters.isEmpty } }

    func wait() async -> T {
        await withCheckedContinuation { continuation in
            let now: T? = lock.withLock {
                if let answer { return answer }
                waiters.append(continuation)
                return nil
            }
            if let now { continuation.resume(returning: now) }
        }
    }

    func open(_ value: T) {
        let held: [CheckedContinuation<T, Never>] = lock.withLock {
            answer = value
            defer { waiters = [] }
            return waiters
        }
        held.forEach { $0.resume(returning: value) }
    }
}
