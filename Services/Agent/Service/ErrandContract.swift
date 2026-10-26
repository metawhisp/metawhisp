import Foundation

// The errand contract (ITER-076 B0): how `AgentService` talks to one errand's
// run. The run — the agent's loop — changes on its own schedule; the service
// owns everything around it: the queue, the browser connection, the Mac kept
// awake, Stop, the lid, the Yes/No questions, the record, and the events the
// Island and MetaChat show.

/// Where an errand was asked for.
enum ErrandOrigin: Codable, Equatable {
    case chat(messageID: UUID)
    case voice(questionID: UUID)
}

/// What the user asked an errand to give (ITER-076 stage 6, № 50, 168): its
/// answer in MetaChat — the default — or that answer and a new Google Sheet of
/// what it found, when the user asked for a table. MetaChat's model says which
/// as it starts the errand; no code guesses it from the user's words.
enum ErrandOutput: String, Codable, Equatable {
    case answer, sheet
}

/// What `AgentService.start` answers. A refused errand gets no id: nothing
/// of it exists.
enum ErrandAdmission: Equatable {
    case started(id: UUID)
    /// 1 is next.
    case queued(id: UUID, position: Int)
    case refused(Refusal)

    enum Refusal: Equatable {
        /// Errands are Pro-only (owner decision 10 of 2026-09-26).
        case notPro
        case emptyGoal
        /// This build has no run to give an errand — or the owner's switch on
        /// the server is off (ITER-076 stage 9d, № 27).
        case unavailable
        /// Three errands already wait (`AgentQueue.maxWaiting`).
        case queueFull
        /// An update waits to be installed.
        case updateWaiting
        /// The Mac is going to sleep, or asleep: nothing starts until it wakes.
        case macAsleep
        /// The app is quitting.
        case appQuitting
    }
}

/// A part of an errand that only the user may do in the browser — the agent
/// never types a password, solves a CAPTCHA, grants access or pays (owner
/// decision 6 of 2026-09-26), nor picks a file from the user's disk (ITER-076
/// I-08).
struct ErrandHandover: Equatable {
    /// Kept in the errand's record by its name (ITER-076 I-06a). `file`: a
    /// file from the user's disk that a form needs (ITER-076 I-08).
    /// `cookies`: a cookie window that blocks the page and offers no least
    /// consent — reject, necessary only, a save with only necessary switches
    /// on, close — nor the way to it (ITER-076 stage 3, owner default 3.1;
    /// 2026-10-21).
    enum Kind: String, Codable, Equatable, CaseIterable {
        case signIn, captcha, grant, payment, file, cookies

        /// Whether the errand waits for the user to do it (ITER-076 stage 3,
        /// owner decision 6): every kind but a payment, which ends the
        /// errand at once (L4).
        var waits: Bool { self != .payment }
    }
    let kind: Kind
    /// The site's host.
    let host: String
}

/// The user's part, waited for (ITER-076 stage 3): the errand stays, its tab
/// open and the user's, until they say Continue — or its window ends, or
/// Stop. An answer names this pause (`AgentService.proceed(_:after:)`), and
/// counts only while it is open: the first one counts.
struct ErrandPause: Equatable {
    let id: UUID
    let handover: ErrandHandover
}

/// What a run reports while it works. Every other event is the service's, so
/// a run cannot end an errand twice or ask outside the service's question.
enum ErrandProgress: Equatable {
    /// `done` of `wanted` rows; no `wanted` when the errand answers in words.
    case working(title: String, done: Int, wanted: Int?)
    case needsUser(ErrandHandover)
    /// A form on `host` is being read and its values found (ITER-076 stage 7).
    case readingForm(host: String)
}

/// What an errand shows, in order. Each errand ends with `.finished`, once;
/// only `.amended` may follow it.
enum ErrandEvent: Equatable {
    case queued(position: Int)
    /// Waiting for the browser; the link's state says where that stands.
    case connecting(ChromeLink.State)
    case working(title: String, done: Int, wanted: Int?)
    /// A form on `host` is being read and its values found (ITER-076 stage
    /// 7): its preview comes next.
    case readingForm(host: String)
    /// A Yes/No question about one action — or a form's (ITER-076 stage 7):
    /// its preview, or its Send. An answer names this request
    /// (`AgentService.answer(_:to:_:)`), and counts only while it is open; the
    /// first answer counts; silence for `ConfirmationRequest.answerWindow` is
    /// No — but a form's preview has no window: it waits for the user.
    case needsYes(ConfirmationRequest)
    /// The user's part, when it ends the errand at once: a payment (L4), or
    /// a wall on a page that could not be read.
    case needsUser(ErrandHandover)
    /// The user's part, waited for: Continue goes on, its window ending ends
    /// the errand (ITER-076 stage 3).
    case paused(ErrandPause)
    case finished(ErrandOutcome)
    /// The errand's outcome after its end, amended (ITER-076 I-05, review
    /// round 2): a Sheet its run made before the end, known only after it —
    /// `.finished`'s outcome with that Sheet.
    case amended(ErrandOutcome)
}

/// How an errand ended.
struct ErrandOutcome: Codable, Equatable {
    /// Why an errand ended without running, when something other than a Stop
    /// of that one errand ended it.
    enum NotRun: String, Codable, Equatable, CaseIterable {
        /// It waited 30 minutes in the queue (`AgentQueue.maxWait`).
        case expired
        /// An update was ready.
        case updateWaiting
        /// Stop all, while it waited.
        case stoppedAll
        /// The Mac went to sleep while it waited.
        case macSlept
        /// The app quit while it waited.
        case appQuit
        /// No browser this link knows runs.
        case browserNotRunning
        /// Google Chrome is not on this Mac: the agent's own could not start.
        case browserNotInstalled
        /// "Allow remote debugging" is off at `chrome://inspect/#remote-debugging`.
        case remoteDebuggingOff
        /// The browser did not let the errand in: declined, or no answer in time.
        case notAllowed
    }

    /// How the Sheet the user asked for failed (ITER-076 stage 6, № 174): it
    /// ends nothing — the errand keeps its ending and its answer — and is
    /// named beside them.
    enum SheetFailure: String, Codable, Equatable, CaseIterable {
        /// No Sheet was made.
        case notMade
        /// Google asked for a sign-in on the way, and none came in time.
        case signIn
        /// The Sheet exists, but it does not show what was pasted — or it
        /// could not be read back to tell.
        case mismatch
    }

    let ending: ErrandRecord.Ending
    let answer: String?
    let sources: [URL]
    let sheet: URL?
    let rows: Int
    let notRun: NotRun?
    /// Why it failed, when a failure ended it (ITER-076 I-05).
    let failure: ErrandRecord.Failure?
    /// When the agent's service may be asked again, when it said: the day's
    /// limit resetting, or the service back.
    let retryAt: Date?
    /// How the Sheet the user asked for failed, when it did.
    let sheetFailure: SheetFailure?
    /// How a form's errand ended (ITER-076 stage 7, № 183): what MetaChat
    /// says and the card shows in place of the ending's own line; nil for
    /// any other errand, and in an outcome kept before.
    let form: FormEnding?

    init(ending: ErrandRecord.Ending, answer: String?, sources: [URL], sheet: URL?, rows: Int, notRun: NotRun? = nil,
         failure: ErrandRecord.Failure? = nil, retryAt: Date? = nil, sheetFailure: SheetFailure? = nil,
         form: FormEnding? = nil) {
        self.ending = ending
        self.answer = answer
        self.sources = sources
        self.sheet = sheet
        self.rows = rows
        self.notRun = notRun
        self.failure = failure
        self.retryAt = retryAt
        self.sheetFailure = sheetFailure
        self.form = form
    }

    /// This outcome with the errand's Sheet, when it names none.
    func withSheet(_ made: URL?) -> ErrandOutcome {
        guard sheet == nil, let made else { return self }
        return ErrandOutcome(ending: ending, answer: answer, sources: sources, sheet: made, rows: rows,
                             notRun: notRun, failure: failure, retryAt: retryAt, sheetFailure: sheetFailure, form: form)
    }
}

/// One errand's run, made for it by the service's factory once the browser is
/// connected. `AgentRun` adopts it (ITER-076 I-05).
@MainActor
protocol ErrandRunner: AnyObject {
    /// What the errand did so far: its steps, the rows collected so far and
    /// the Sheet. The service saves it, under `ErrandSetup.id`, when the
    /// errand ends — also when it ends the errand before `run` returns (Stop,
    /// stop all, the Mac going to sleep, the app quitting, the service's
    /// ceiling) — so it holds everything done up to that moment; and again,
    /// final, when a stopped run returns.
    var record: ErrandRecord { get }
    /// Runs the errand to its own end — done, stuck, a ceiling, a failure, or
    /// the user's part — within its absolute expiry, reporting what it does
    /// as it changes.
    func run(report: @escaping @MainActor (ErrandProgress) -> Void) async -> ErrandOutcome
    /// Stop (ITER-074 §7.4): the run starts nothing new — no step, no call,
    /// no question. It may still check an action it had already sent and
    /// close its own tab, and `run` returns within one call's deadline. The
    /// service ends the errand at once and does not wait: what `run` returns
    /// or reports after that is dropped, and its final record is saved over
    /// the one saved at Stop.
    func stop()
}

/// What the factory gets to make an errand's run.
struct ErrandSetup {
    let id: UUID
    /// The user's own words.
    let goal: String
    let bridge: any BrowserBridge
    /// Asks the user about one action (ITER-074 §7.1), the shape of
    /// `AgentRun.Collaborators.confirm`: the first answer, or nil — No — after
    /// `ConfirmationRequest.answerWindow`, at Stop, or once the errand has
    /// ended. One question at a time: a new one ends the one before as No.
    let confirm: @MainActor @Sendable (ConfirmationRequest) async -> ConfirmationRequest.Answer?
    /// The run says here that the errand's Sheet exists, as soon as it does —
    /// also once the service has ended the errand (Stop, sleep, quit, the
    /// ceiling): the service then adds the Sheet to what it kept and sends
    /// `.amended` (ITER-076 I-05, review round 2).
    var sheetMade: @MainActor @Sendable (URL) -> Void = { _ in }
    /// Where the run says each event of the errand as it keeps it (ITER-076
    /// I-06a): the service's own log.
    var log: @MainActor @Sendable (String) -> Void = { NSLog("%@", $0) }
    /// Waits for the user to do their part in the errand's tab (ITER-076
    /// stage 3), shown as `.paused`: true once they said Continue; false when
    /// the window — the run's own, passed here — ran out, at Stop, or once
    /// the errand has ended. One pause at a time. Without a service to wait
    /// with, no one says Continue.
    var waitForUser: @MainActor @Sendable (ErrandHandover, BrowserTab, Duration) async -> Bool = { _, _, _ in false }
    /// What the user asked the errand to give (ITER-076 stage 6).
    var output: ErrandOutput = .answer
    /// The run heard the server say the owner switched the agent off
    /// (ITER-076 stage 9d, № 27): the service keeps errands off a while.
    var switchedOff: @MainActor @Sendable () -> Void = {}
    /// Where the run begins when its goal names no address: the address the
    /// user named, when MetaChat's goal lost it (2026-10-12); nil — the start
    /// page.
    var start: URL? = nil
}

typealias ErrandRunnerFactory = @MainActor (ErrandSetup) -> any ErrandRunner
