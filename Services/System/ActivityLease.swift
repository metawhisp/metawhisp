import Foundation

/// ITER-075 step 0, US-0.2 — what the running app is busy with, in a small
/// file an installer can read. An install that kills the app mid-meeting loses
/// the call (2026-09-25); `hot-swap.sh` refuses while the lease says busy and
/// its process is alive. A lease whose process is gone releases itself, so a
/// crash can't block installs forever.
enum ActivityLease {
    enum State: String, Codable, Equatable {
        case idle, recording, transcribing
        /// ITER-076 B1. The install script says "MetaWhisp is <state> right
        /// now", so this one is written in words.
        case errand = "running an errand"
        /// C6 — the onboarding's practice is recording or transcribing.
        case practice = "running a practice dictation"
    }

    struct Record: Codable, Equatable {
        let pid: Int32
        /// The executable that owns the lease. After a crash the pid can be
        /// reused by another process; the script checks the pid still runs
        /// this executable before it treats the lease as busy.
        let executable: String
        let state: State
        let since: Date
    }

    /// The busiest thing going on: recording beats transcribing beats the
    /// practice beats an errand beats idle.
    static func state(isRecording: Bool, isStarting: Bool,
                      dictationStage: TranscriptionCoordinator.Stage, meetingsInFlight: Int,
                      errandRunning: Bool = false, practicing: Bool = false) -> State {
        if isRecording || isStarting || dictationStage == .recording { return .recording }
        if meetingsInFlight > 0 || dictationStage == .processing || dictationStage == .postProcessing {
            return .transcribing
        }
        if practicing { return .practice }
        return errandRunning ? .errand : .idle
    }

    /// `<support folder>/activity.json`.
    static func fileURL(in supportDirectory: URL) -> URL {
        supportDirectory.appendingPathComponent("activity.json")
    }

    /// Writes the record atomically, so a reader never sees half of it.
    static func write(_ record: Record, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(record).write(to: url, options: .atomic)
    }
}

/// The lease's bookkeeping, kept apart from AppDelegate so the order of its
/// writes is testable (ITER-075 step 0, US-0.2).
@MainActor
final class ActivityLeaseTracker {
    private let pid: Int32
    private let executable: String
    private let write: (ActivityLease.Record) throws -> Void
    private var isRecording = false
    private var isStarting = false
    private var stage: TranscriptionCoordinator.Stage = .idle
    private(set) var meetingsInFlight = 0
    private var errandRunning = false
    private var practicing = false
    /// The last state this process wrote; nil until its first successful
    /// write. A process that never wrote the lease never owns it.
    private(set) var written: ActivityLease.State?
    /// Called after every change, written or not — the capture arbiter's cue
    /// that a dictation or a meeting may have ended (C6).
    var onChange: (() -> Void)?

    /// What the app is busy with, from the values the last changes carried.
    var current: ActivityLease.State {
        ActivityLease.state(isRecording: isRecording, isStarting: isStarting,
                            dictationStage: stage, meetingsInFlight: meetingsInFlight,
                            errandRunning: errandRunning, practicing: practicing)
    }

    init(pid: Int32, executable: String, write: @escaping (ActivityLease.Record) throws -> Void) {
        self.pid = pid
        self.executable = executable
        self.write = write
    }

    /// The recorder's and the dictation's values as their publishers emit
    /// them; @Published emits before the property changes.
    func recorderAndDictation(isRecording: Bool, isStarting: Bool, stage: TranscriptionCoordinator.Stage) {
        self.isRecording = isRecording
        self.isStarting = isStarting
        self.stage = stage
        update()
    }

    /// Called before the recorder stops, so the lease goes from recording
    /// straight to transcribing and never reads idle in between.
    func meetingTranscriptionStarted() {
        meetingsInFlight += 1
        update()
    }

    func meetingTranscriptionFinished() {
        meetingsInFlight = max(0, meetingsInFlight - 1)
        update()
    }

    /// Whether an errand runs, as `AgentService` publishes it (ITER-076 B1):
    /// a swap must not quit the app in the middle of one.
    func errand(isRunning: Bool) {
        errandRunning = isRunning
        update()
    }

    /// Whether the onboarding practice records or transcribes (C6): an install
    /// must not quit the app in the middle of one.
    func practice(isBusy: Bool) {
        practicing = isBusy
        update()
    }

    /// At quit: idle, but only from a process that owns the lease. A second
    /// instance that quits at launch never wrote it and must not overwrite the
    /// first instance's "recording".
    func quitting() {
        guard written != nil else { return }
        store(.idle)
    }

    private func update() {
        let state = current
        if state != written { store(state) }
        onChange?()
    }

    /// `written` changes only after the write succeeded, so a failed write is
    /// tried again on the next change.
    private func store(_ state: ActivityLease.State) {
        do {
            try write(ActivityLease.Record(pid: pid, executable: executable, state: state, since: Date()))
            written = state
            NSLog("[ActivityLease] %@", state.rawValue)
        } catch {
            NSLog("[ActivityLease] ❌ write failed — %@", error.localizedDescription)
        }
    }
}
