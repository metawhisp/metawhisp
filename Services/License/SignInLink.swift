import AppKit

/// A3 (owner, 2026-10-25): a sign-in link signs the app in only when the app expects one.
///
/// The app used to keep the token of any `metawhisp://auth` link as its session, whatever page opened it. Now a
/// link is expected when Sign in or Get Pro was pressed in the app within the last hour (`SignInExpectation`); such a
/// link goes through as before. Any other link is first looked up — its token's account, read without signing in —
/// and the app asks "Sign in as s•••@…?" (or "Switch to s•••@…?" while another account is signed in) with Sign in and
/// Cancel. A link of the account already signed in needs no question; a token the server refuses is said plainly;
/// nothing is stored unless the sign-in goes ahead.

/// That the app asked for a sign-in: Sign in or Get Pro was pressed in it. A link that comes back within the hour is
/// the one it asked for. The deadline is kept in the app's defaults, so a link that opens the app after a quit is
/// expected too. The link it was asked for takes it before its sign-in is awaited, so any other link meanwhile asks;
/// it is given back only when that sign-in does not go through.
enum SignInExpectation {
    /// The deadline's key in the app's defaults.
    static let key = "signInExpectedUntil"
    /// How long a press keeps a link expected: the gate's ceiling.
    static let window: TimeInterval = 60 * 60

    /// Sign in or Get Pro was pressed: the sign-in link that comes back within the hour is expected. Every button that
    /// sends the user to the site to sign in calls this first.
    static func mark(now: Date = Date(), defaults: UserDefaults = .standard) {
        defaults.set(now.addingTimeInterval(window), forKey: key)
    }

    /// Whether a link arriving `now` was asked for. A deadline further away than the window — a clock moved back —
    /// is none this app set.
    static func isExpected(now: Date = Date(), defaults: UserDefaults = .standard) -> Bool {
        guard let until = defaults.object(forKey: key) as? Date else { return false }
        return now < until && until.timeIntervalSince(now) <= window
    }

    /// Takes the press for the link handled now, before its sign-in is awaited: a link that comes meanwhile finds
    /// nothing expected and asks (Codex, 1.4.0 review: both used to go through on one press). Its deadline, for
    /// `restore`; nil when no link is expected.
    static func reserve(now: Date = Date(), defaults: UserDefaults = .standard) -> Date? {
        guard isExpected(now: now, defaults: defaults), let until = defaults.object(forKey: key) as? Date else {
            return nil
        }
        defaults.removeObject(forKey: key)
        return until
    }

    /// The sign-in it was taken for did not go through: the press is given back with its own deadline — opening the
    /// link again from the site needs no question — unless a newer press has been marked since.
    static func restore(_ until: Date, defaults: UserDefaults = .standard) {
        if let newer = defaults.object(forKey: key) as? Date, newer >= until { return }
        defaults.set(until, forKey: key)
    }
}

/// One sign-in link at a time (A3): a link that comes while another is handled waits until that one is done — its
/// lookup, its question, its sign-in — so two links never take the press, ask or sign in at once, and one sign-in's
/// answer cannot land over another's. The wait's ceiling is the link before it: its lookup and its sign-in time out
/// on their own, and its question waits for the user's answer.
@MainActor
final class SignInLinkLine {
    /// The app's: every link the app is handed goes through this one.
    nonisolated static let shared = SignInLinkLine()

    private var last: Task<Void, Never>?

    nonisolated init() {}

    /// Runs `work` once every link handed in before it is done.
    func run(_ work: @escaping @MainActor () async -> Void) async {
        let before = last
        let mine = Task { @MainActor in
            await before?.value
            await work()
        }
        last = mine
        await mine.value
    }
}

/// What the app does with a sign-in link's token.
@MainActor
struct SignInLink {
    /// The account a token belongs to, as the server says.
    enum Account: Equatable {
        case email(String)
        /// The server refused the token: a bad or expired link.
        case rejected
        /// The server could not be asked, or gave no answer to read.
        case unreachable
    }

    /// The question asked before a link the app did not expect signs in.
    struct Question: Equatable {
        let title: String
        /// The button that signs in; the other is Cancel.
        let confirm: String
    }

    static let rejected = "This sign-in link has expired or isn't valid. Nothing was changed."
    static let unreachable = "Couldn't check this sign-in link. Check your internet and open it again."

    /// Where the expectation is kept: the app's defaults; a test's own in tests.
    var defaults: UserDefaults = .standard
    /// Where links wait their turn: the app's one line; a test's own in tests.
    var line: SignInLinkLine = .shared
    /// The token's account, read without signing in.
    let account: (String) async -> Account
    /// The account signed in now, if any.
    let signedInEmail: () -> String?
    /// Asks the question; true for the sign-in button.
    let confirm: (Question) async -> Bool
    /// Signs in with the token as before (the activation, then its banner); true when the server signed the account
    /// in — whether or not the keychain kept it — so the press is spent; false gives it back.
    let signIn: (String) async -> Bool
    /// Says why nothing was stored.
    let refuse: (String) -> Void

    /// Handles a link once every link before it is done (`line`).
    func handle(token: String) async {
        await line.run { await handleInTurn(token: token) }
    }

    private func handleInTurn(token: String) async {
        if let taken = SignInExpectation.reserve(defaults: defaults) {
            NSLog("[DeepLink] a sign-in the app asked for — signing in")
            if !(await signIn(token)) {
                NSLog("[DeepLink] the expected sign-in did not go through — the press is given back")
                SignInExpectation.restore(taken, defaults: defaults)
            }
            return
        }
        switch await account(token) {
        case .rejected:
            NSLog("[DeepLink] an unexpected link with a refused token — nothing stored")
            refuse(Self.rejected)
        case .unreachable:
            NSLog("[DeepLink] an unexpected link that could not be checked — nothing stored")
            refuse(Self.unreachable)
        case .email(let email):
            let current = signedInEmail()
            if let current, current.caseInsensitiveCompare(email) == .orderedSame {
                NSLog("[DeepLink] an unexpected link of the account signed in — signing in")
                _ = await signIn(token)
                return
            }
            let question = current == nil
                ? Question(title: "Sign in as \(Self.masked(email))?", confirm: "Sign in")
                : Question(title: "Switch to \(Self.masked(email))?", confirm: "Switch")
            guard await confirm(question) else {
                NSLog("[DeepLink] an unexpected link, cancelled — nothing stored")
                return
            }
            _ = await signIn(token)
        }
    }

    /// The address as the question shows it: its first letter and its domain.
    static func masked(_ email: String) -> String {
        let parts = email.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let first = parts[0].first, !parts[1].isEmpty else { return "•••" }
        return "\(first)•••@\(parts[1])"
    }

    /// The question as an alert: Sign in (or Switch) and Cancel, on the Space the user is on, a full-screen one
    /// included.
    static func alert(for question: Question) -> NSAlert {
        CurrentSpaceAlert.make(question.title, buttons: [question.confirm, "Cancel"])
    }

    /// Asks with the alert, in front of the browser the link came from: true for the sign-in button.
    static func ask(_ question: Question) -> Bool {
        CurrentSpaceAlert.ask(alert(for: question)) == 0
    }
}
