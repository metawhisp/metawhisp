import AppKit
import XCTest
@testable import MetaWhisp

/// A3 (owner, 2026-10-25) — a `metawhisp://auth` link signs the app in only when the app expects one. Expected means
/// Sign in or Get Pro was pressed in the app within the last hour (`SignInExpectation.mark()`): such a link goes
/// through as before. Any other link is first looked up — the token's account, read without signing in — and then the
/// app asks "Sign in as s•••@…?" with Sign in and Cancel. The app used to keep the token of any link as its session.
/// On a defaults suite of the test's own, with fakes for the server, the question and the sign-in.
@MainActor
final class SignInLinkTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suite = "mw-sign-in-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    /// What the link did: whom it asked, whether it signed in, what it said.
    private final class Seen {
        var lookedUp = 0
        var questions: [SignInLink.Question] = []
        var signIns = 0
        var refusals: [String] = []
    }

    private func link(account: SignInLink.Account = .email("sam@example.com"), signedInAs: String? = nil,
                      confirms: Bool = true, signInWorks: Bool = true, _ seen: Seen) -> SignInLink {
        SignInLink(defaults: defaults, line: line,
                   account: { _ in seen.lookedUp += 1; return account },
                   signedInEmail: { signedInAs },
                   confirm: { question in seen.questions.append(question); return confirms },
                   signIn: { _ in seen.signIns += 1; return signInWorks },
                   refuse: { seen.refusals.append($0) })
    }

    /// The test's own line of links, so no test waits on another's.
    private let line = SignInLinkLine()

    /// Sign-ins the server has not answered yet: each waits until the test answers it.
    @MainActor
    private final class HeldSignIns {
        private var pending: [CheckedContinuation<Bool, Never>] = []
        private(set) var tokens: [String] = []
        var waiting: Int { pending.count }

        func signIn(_ token: String) async -> Bool {
            tokens.append(token)
            return await withCheckedContinuation { pending.append($0) }
        }

        func answerAll(_ signedIn: Bool) {
            let answered = pending
            pending = []
            answered.forEach { $0.resume(returning: signedIn) }
        }
    }

    /// A link whose sign-ins are `held`; an unexpected one is looked up as another account's and asked about.
    private func heldLink(_ held: HeldSignIns, _ seen: Seen, confirms: Bool) -> SignInLink {
        SignInLink(defaults: defaults, line: line,
                   account: { _ in seen.lookedUp += 1; return .email("alex@example.org") },
                   signedInEmail: { nil },
                   confirm: { question in seen.questions.append(question); return confirms },
                   signIn: { token in await held.signIn(token) },
                   refuse: { seen.refusals.append($0) })
    }

    private func until(_ done: () -> Bool) async {
        for _ in 0..<400 where !done() { try? await Task.sleep(for: .milliseconds(5)) }
    }

    private func settle() async {
        try? await Task.sleep(for: .milliseconds(50))
    }

    // MARK: - The expectation

    /// Sign in or Get Pro pressed: a link is expected for the next hour.
    func testAPressMarksASignInAsExpectedForAnHour() {
        let pressed = Date()
        XCTAssertFalse(SignInExpectation.isExpected(now: pressed, defaults: defaults), "nothing pressed yet")
        SignInExpectation.mark(now: pressed, defaults: defaults)
        XCTAssertTrue(SignInExpectation.isExpected(now: pressed.addingTimeInterval(59 * 60), defaults: defaults))
        XCTAssertFalse(SignInExpectation.isExpected(now: pressed.addingTimeInterval(60 * 60 + 1), defaults: defaults),
                       "the ceiling: an hour")
    }

    /// The app wasn't running (case 6): the link opens it, and the same rules apply — the deadline is kept in the
    /// app's defaults, so a launch reads it.
    func testTheExpectationOutlivesARelaunch() throws {
        let pressed = Date()
        SignInExpectation.mark(now: pressed, defaults: defaults)
        let relaunched = try XCTUnwrap(UserDefaults(suiteName: suite))
        XCTAssertTrue(SignInExpectation.isExpected(now: pressed.addingTimeInterval(5 * 60), defaults: relaunched))
    }

    /// A deadline further away than an hour is none this app set — a clock moved back: no expectation.
    func testADeadlineBeyondTheHourIsNoExpectation() {
        let pressed = Date()
        SignInExpectation.mark(now: pressed, defaults: defaults)
        XCTAssertFalse(SignInExpectation.isExpected(now: pressed.addingTimeInterval(-2 * 60 * 60), defaults: defaults))
    }

    // MARK: - An expected link

    /// Expected (case 1): it signs in as before — no lookup, no question.
    func testAnExpectedLinkSignsInWithoutAQuestion() async {
        let seen = Seen()
        SignInExpectation.mark(defaults: defaults)
        await link(seen).handle(token: "t")
        XCTAssertEqual(seen.signIns, 1)
        XCTAssertEqual(seen.lookedUp, 0)
        XCTAssertTrue(seen.questions.isEmpty)
    }

    /// The gate's release: the press is spent by the sign-in it asked for, so the next link — within the hour — asks
    /// anyway.
    func testTheNextLinkAfterTheExpectedSignInAsksAnyway() async {
        let seen = Seen()
        SignInExpectation.mark(defaults: defaults)
        await link(seen).handle(token: "t")
        XCTAssertFalse(SignInExpectation.isExpected(defaults: defaults), "spent")
        await link(seen).handle(token: "u")
        XCTAssertEqual(seen.questions.count, 1, "the second link asks")
    }

    /// A sign-in that didn't go through spends nothing: opening the link again from the site still needs no question.
    func testAFailedExpectedSignInKeepsTheExpectation() async {
        let seen = Seen()
        SignInExpectation.mark(defaults: defaults)
        await link(signInWorks: false, seen).handle(token: "t")
        XCTAssertTrue(SignInExpectation.isExpected(defaults: defaults))
    }

    // MARK: - Two links at once

    /// Two links while the expected one's sign-in is still out (Codex P1, 1.4.0 review): the press is taken before
    /// that sign-in is awaited, and links are handled one at a time, so the second finds nothing expected and asks.
    /// It used to go through on the same press — two sign-ins without a question, the last one's account kept.
    func testASecondLinkDuringAnExpectedSignInAsks() async {
        SignInExpectation.mark(defaults: defaults)
        let seen = Seen()
        let held = HeldSignIns()
        let link = heldLink(held, seen, confirms: false)
        let first = Task { await link.handle(token: "a") }
        await until { held.waiting == 1 }                 // the expected sign-in is out
        let second = Task { await link.handle(token: "b") }
        await settle()                                    // the second link goes as far as it can
        held.answerAll(true)
        await first.value
        await settle()
        held.answerAll(true)                              // a second sign-in, if one went out
        await second.value
        XCTAssertEqual(held.tokens, ["a"], "the second link did not sign in on the same press")
        XCTAssertEqual(seen.questions.count, 1, "it asked")
        XCTAssertFalse(SignInExpectation.isExpected(defaults: defaults))
    }

    /// The release: the expected sign-in fails — refused, or no answer — so the press comes back, and the link the
    /// user opens again from the site goes through without a question, as before.
    func testAFailedExpectedSignInGivesThePressBackToTheNextLink() async {
        SignInExpectation.mark(defaults: defaults)
        let seen = Seen()
        let held = HeldSignIns()
        let link = heldLink(held, seen, confirms: false)
        let first = Task { await link.handle(token: "a") }
        await until { held.waiting == 1 }
        let second = Task { await link.handle(token: "b") }
        await settle()
        held.answerAll(false)                             // the first one did not sign in
        await first.value
        await until { held.waiting == 1 }
        held.answerAll(true)
        await second.value
        XCTAssertEqual(held.tokens, ["a", "b"])
        XCTAssertTrue(seen.questions.isEmpty, "the press was given back, so no question")
        XCTAssertFalse(SignInExpectation.isExpected(defaults: defaults), "and spent by the one that signed in")
    }

    /// A press given back keeps its own deadline, and never replaces a newer one.
    func testAPressGivenBackKeepsItsDeadlineAndNeverReplacesANewerOne() throws {
        let pressed = Date()
        SignInExpectation.mark(now: pressed, defaults: defaults)
        let taken = try XCTUnwrap(SignInExpectation.reserve(now: pressed, defaults: defaults))
        XCTAssertFalse(SignInExpectation.isExpected(now: pressed, defaults: defaults), "taken")
        SignInExpectation.restore(taken, defaults: defaults)
        XCTAssertTrue(SignInExpectation.isExpected(now: pressed.addingTimeInterval(59 * 60), defaults: defaults))
        XCTAssertFalse(SignInExpectation.isExpected(now: pressed.addingTimeInterval(60 * 60 + 1), defaults: defaults),
                       "the same hour, not a new one")
        let again = try XCTUnwrap(SignInExpectation.reserve(now: pressed, defaults: defaults))
        SignInExpectation.mark(now: pressed.addingTimeInterval(30 * 60), defaults: defaults)   // pressed again meanwhile
        SignInExpectation.restore(again, defaults: defaults)
        XCTAssertTrue(SignInExpectation.isExpected(now: pressed.addingTimeInterval(80 * 60), defaults: defaults),
                      "the newer press stands")
    }

    // MARK: - Any other link

    /// Unexpected (case 2): the token's account is looked up, then the app asks; Cancel stores nothing.
    func testAnUnexpectedLinkAsksAndCancelStoresNothing() async {
        let seen = Seen()
        await link(confirms: false, seen).handle(token: "t")
        XCTAssertEqual(seen.lookedUp, 1)
        XCTAssertEqual(seen.questions, [SignInLink.Question(title: "Sign in as s•••@example.com?", confirm: "Sign in")])
        XCTAssertEqual(seen.signIns, 0, "nothing stored")
    }

    /// …and Sign in signs in.
    func testAnUnexpectedLinkSignsInOnceConfirmed() async {
        let seen = Seen()
        await link(seen).handle(token: "t")
        XCTAssertEqual(seen.signIns, 1)
    }

    /// A bad or expired token (case 3): a clear error, nothing stored, no question.
    func testABadOrExpiredTokenIsRefusedPlainly() async {
        let seen = Seen()
        await link(account: .rejected, seen).handle(token: "t")
        XCTAssertEqual(seen.refusals, [SignInLink.rejected])
        XCTAssertTrue(seen.questions.isEmpty)
        XCTAssertEqual(seen.signIns, 0)
    }

    /// The server could not be asked: said so, nothing stored.
    func testALinkThatCannotBeCheckedStoresNothing() async {
        let seen = Seen()
        await link(account: .unreachable, seen).handle(token: "t")
        XCTAssertEqual(seen.refusals, [SignInLink.unreachable])
        XCTAssertEqual(seen.signIns, 0)
    }

    /// Already signed in to that account (case 4): no question.
    func testTheAccountAlreadySignedInNeedsNoQuestion() async {
        let seen = Seen()
        await link(signedInAs: "Sam@Example.com", seen).handle(token: "t")
        XCTAssertTrue(seen.questions.isEmpty)
        XCTAssertEqual(seen.signIns, 1)
    }

    /// Signed in to another account (case 5): "Switch to s•••@…?".
    func testAnotherAccountAsksToSwitch() async {
        let seen = Seen()
        await link(signedInAs: "alex@example.org", confirms: false, seen).handle(token: "t")
        XCTAssertEqual(seen.questions, [SignInLink.Question(title: "Switch to s•••@example.com?", confirm: "Switch")])
        XCTAssertEqual(seen.signIns, 0)
    }

    func testTheAddressIsShownMasked() {
        XCTAssertEqual(SignInLink.masked("sam@example.com"), "s•••@example.com")
        XCTAssertEqual(SignInLink.masked("s@example.com"), "s•••@example.com")
        XCTAssertEqual(SignInLink.masked("not an address"), "•••")
        XCTAssertEqual(SignInLink.masked("@example.com"), "•••")
    }

    // MARK: - The question on screen

    /// Sign in and Cancel, on the Space the user is on, a full-screen one included (case 7).
    func testTheQuestionIsAnAlertOnTheCurrentSpace() {
        let alert = SignInLink.alert(for: SignInLink.Question(title: "Sign in as s•••@example.com?", confirm: "Sign in"))
        XCTAssertEqual(alert.messageText, "Sign in as s•••@example.com?")
        XCTAssertEqual(alert.buttons.map(\.title), ["Sign in", "Cancel"])
        XCTAssertEqual(alert.window.collectionBehavior, MWWindowBehavior.main)
    }

    // MARK: - The lookup

    /// The account is read from the session answer; a token the server refuses is a bad or expired one; anything
    /// else could not be checked.
    func testTheLookupReadsTheServersAnswer() {
        let body = Data(#"{"email":"sam@example.com","license":null,"subscription":null}"#.utf8)
        XCTAssertEqual(LicenseService.signInAccount(status: 200, data: body), .email("sam@example.com"))
        for refused in [400, 401, 403, 404] {
            XCTAssertEqual(LicenseService.signInAccount(status: refused, data: Data()), .rejected, "\(refused)")
        }
        XCTAssertEqual(LicenseService.signInAccount(status: 500, data: Data()), .unreachable)
        XCTAssertEqual(LicenseService.signInAccount(status: 200, data: Data("{}".utf8)), .unreachable)
    }

    // MARK: - The app's wiring

    /// Every Get Pro and Sign in — the onboarding's and Settings' — opens the site through AccountPage.open, which
    /// marks the sign-in as expected before anything else (AccountPageTests pins the order; OnboardingEntryTests that
    /// no other code opens the account page). The link handler goes through SignInLink — never straight to
    /// activation. The lookup sends no machine id, so it binds no licence to this Mac. Read from the source: neither
    /// has a test harness here.
    func testTheAppMarksItsPressesAndHandlesEveryLinkThroughTheRules() throws {
        let page = try codeLines(of: "Services/License/AccountPage.swift")
        let open = body(of: "static func open(", in: page)
        let firstStatement = open.dropFirst().first { !$0.trimmingCharacters(in: .whitespaces).isEmpty
            && !$0.contains("with openURL:") && !$0.contains("-> Bool {") }
        XCTAssertTrue(firstStatement?.contains("SignInExpectation.mark(") == true, "marked first: \(firstStatement ?? "nothing")")
        // The address holds "//", which the comment stripping cuts: looked for in the raw lines.
        let raw = try String(contentsOf: repoRoot.appendingPathComponent("Views/Windows/MainSettingsView.swift"),
                             encoding: .utf8)
        XCTAssertFalse(raw.contains("metawhisp.com/account"), "Settings opens the account page only through AccountPage")
        let settings = try codeLines(of: "Views/Windows/MainSettingsView.swift")
        XCTAssertGreaterThanOrEqual(settings.filter { $0.contains("AccountPage.open()") }.count, 2, "Get Pro and Sign in")
        let delegate = try codeLines(of: "App/AppDelegate.swift")
        // Every link reaches it through the link inbox (ApplicationsMoveTests pins the launch's order).
        let handler = body(of: "private func handle(link url: URL)", in: delegate)
        XCTAssertTrue(handler.contains { $0.contains("SignInLink(") }, "the handler builds the rules")
        XCTAssertTrue(handler.contains { $0.contains(".handle(token:") }, "and hands them every link")
        // The press is spent by the server's answer, never by whether the keychain kept it (Codex, 1.4.0 review):
        // the sign-in returns the activation's own answer (LicenseActivationTests pins that answer).
        XCTAssertTrue(handler.contains { $0.contains("let authenticated = await LicenseService.shared.activate(token: token)") })
        XCTAssertTrue(handler.contains { $0.contains("return authenticated") })
        XCTAssertFalse(handler.contains { $0.contains("lastError == nil") }, "not from the keychain's outcome")
        let license = try codeLines(of: "Services/License/LicenseService.swift")
        let lookup = body(of: "func account(ofSignInToken token: String)", in: license)
        XCTAssertFalse(lookup.isEmpty, "the lookup is there")
        XCTAssertFalse(lookup.contains { $0.contains("machine_id") }, "no machine id: nothing is bound")
    }

    // MARK: - Helpers

    /// …/Tests/MetaWhispTests/Services/License/SignInLinkTests.swift → the repository's root.
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// A source file's lines with line comments stripped: only code counts.
    private func codeLines(of path: String) throws -> [String] {
        try String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8).components(separatedBy: "\n")
            .map { raw in raw.range(of: "//").map { String(raw[..<$0.lowerBound]) } ?? raw }
    }

    /// A declaration's lines, from the one that declares it to the brace that closes it; braces in strings don't
    /// count.
    private func body(of declaration: String, in lines: [String]) -> [String] {
        guard let start = lines.firstIndex(where: { $0.contains(declaration) }) else { return [] }
        var depth = 0
        var opened = false
        var out: [String] = []
        for line in lines[start...] {
            out.append(line)
            var inString = false
            var escaped = false
            for character in line {
                if inString {
                    if escaped { escaped = false } else if character == "\\" { escaped = true } else if character == "\"" { inString = false }
                } else if character == "\"" {
                    inString = true
                } else if character == "{" {
                    depth += 1
                    opened = true
                } else if character == "}" {
                    depth -= 1
                }
            }
            if opened, depth == 0 { break }
        }
        return out
    }
}
