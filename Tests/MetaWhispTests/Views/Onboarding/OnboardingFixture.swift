import XCTest
@testable import MetaWhisp

/// What the onboarding suites give the flow instead of macOS: a defaults suite of their own, permissions they set,
/// a prompt and System Settings that only count, a practice on a fake microphone and the shared practice engine,
/// and an account page that opens or not as told. Nothing here can show a prompt, open a pane or a browser.
@MainActor
final class OnboardingFixture {
    let suite = "mw-onboarding-\(UUID().uuidString)"
    let defaults: UserDefaults
    var permissions = OnboardingPermissions(microphone: .notAsked, accessibility: false)
    private(set) var panes: [OnboardingPermission] = []
    private(set) var microphoneAsks = 0
    var answerMicrophone: (@MainActor (Bool) -> Void)?
    private(set) var endings: [OnboardingFlow.Ending] = []
    /// The account page: how often it was opened, and whether the browser opens.
    private(set) var accountPageOpens = 0
    var browserOpens = true

    let microphone = FakeMicrophone()
    let engine = PracticeEngine()
    var busyElsewhere = false
    lazy var arbiter = CaptureArbiter(busyElsewhere: { [unowned self] in busyElsewhere })

    init() throws {
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    func tearDown() {
        engine.finish()
        defaults.removePersistentDomain(forName: suite)
    }

    func flow(_ store: UserDefaults? = nil) -> OnboardingFlow {
        let microphone = microphone, engine = engine, arbiter = arbiter
        return OnboardingFlow(
            defaults: store ?? defaults,
            environment: .init(
                permissions: { [unowned self] in permissions },
                askForMicrophone: { [unowned self] answered in
                    microphoneAsks += 1
                    answerMicrophone = answered
                },
                makePractice: {
                    PracticeRecorder(microphone: microphone, engine: { engine }, arbiter: arbiter, language: { nil })
                },
                openPane: { [unowned self] in panes.append($0) },
                openAccountPage: { [unowned self] in
                    accountPageOpens += 1
                    return browserOpens
                }),
            finish: { [unowned self] in endings.append($0) })
    }

    /// Lets a transcription that answers at once land.
    func settle(_ practice: PracticeRecorder?) {
        let deadline = Date().addingTimeInterval(2)
        while practice?.phase == .transcribing, !engine.isWaiting, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
}
