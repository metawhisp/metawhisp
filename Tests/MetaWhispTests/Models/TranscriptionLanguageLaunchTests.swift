import XCTest
@testable import MetaWhisp

/// C7, step-1 review #3 — the transcription language across launches.
///
/// A launch-time pin moved installs with nothing stored to "ru". The defaults
/// cannot tell an install from before the "auto" default from one that
/// finished onboarding on an "auto" build and was updated before its second
/// launch — and an English speaker on "ru" gets broken dictation, while a
/// Russian speaker on "auto" gets detection. So nothing writes the language at
/// launch: the code default "auto" applies, a stored value is never changed,
/// and onboarding's completion writes the language the user runs on.
final class TranscriptionLanguageLaunchTests: XCTestCase {

    private let suite = "mw-language-launch-tests"
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
    }

    /// What dictation runs on: the stored value, or the code default.
    private var language: String {
        defaults.string(forKey: "transcriptionLanguage") ?? OnboardingLanguageDefault.freshInstallDefault
    }

    private var repoRoot: URL {
        // …/Tests/MetaWhispTests/Models/TranscriptionLanguageLaunchTests.swift → repo root
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    // MARK: - What an install runs on

    func testAFreshInstallRunsOnAuto() {
        XCTAssertEqual(OnboardingLanguageDefault.freshInstallDefault, "auto")
        XCTAssertEqual(language, "auto")
    }

    /// Finished onboarding with nothing stored — on 1.3.26–1.3.37, updated
    /// before a second launch, or a user from before August who never opened
    /// the setting: "auto", whatever the launches.
    func testAFinishedInstallWithNothingStoredStaysOnAuto() {
        defaults.set(true, forKey: "hasCompletedOnboarding")
        XCTAssertEqual(language, "auto")
    }

    // MARK: - Onboarding's completion

    func testCompletionWritesTheLanguageBeforeTheFlag() throws {
        let recorded = try XCTUnwrap(RecordingDefaults(suiteName: suite))
        AppSettings.recordOnboardingCompleted(in: recorded)
        XCTAssertEqual(recorded.keys, ["transcriptionLanguage", "hasCompletedOnboarding"])
        XCTAssertEqual(recorded.string(forKey: "transcriptionLanguage"), "auto")
        XCTAssertTrue(recorded.bool(forKey: "hasCompletedOnboarding"))
    }

    /// A choice made during onboarding — or "ru" pinned by an older build — is kept.
    func testAStoredValueIsNeverChanged() {
        for stored in ["de", "ru", "en", "auto"] {
            defaults.removePersistentDomain(forName: suite)
            defaults.set(stored, forKey: "transcriptionLanguage")
            AppSettings.recordOnboardingCompleted(in: defaults)
            XCTAssertEqual(language, stored)
            XCTAssertTrue(defaults.bool(forKey: "hasCompletedOnboarding"))
        }
    }

    // MARK: - Nothing else writes it

    /// The language changes only by the user's pick in Settings and by
    /// onboarding's completion — never at launch, and never to "ru" on its own.
    func testOnlyTheSettingsPickAndOnboardingCompletionWriteTheLanguage() throws {
        let writes = try NSRegularExpression(
            pattern: #"transcriptionLanguage\s*=[^=]|forKey:\s*"transcriptionLanguage""#)
        var writers: [String] = []
        for folder in ["App", "Services", "Models", "Views", "Helpers"] {
            let base = repoRoot.appendingPathComponent(folder)
            guard let files = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in files where url.pathExtension == "swift" {
                let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
                for raw in lines {
                    let code = raw.range(of: "//").map { String(raw[..<$0.lowerBound]) } ?? raw
                    let range = NSRange(code.startIndex..., in: code)
                    guard writes.firstMatch(in: code, range: range) != nil,
                          !code.contains("defaults.string(forKey:") else { continue }
                    writers.append("\(url.lastPathComponent): \(code.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        XCTAssertEqual(writers.count, 2, writers.joined(separator: "\n"))
        XCTAssertTrue(writers.contains { $0.hasPrefix("MainSettingsView.swift:") && $0.contains("lang.1") },
                      writers.joined(separator: "\n"))
        XCTAssertTrue(writers.contains { $0.hasPrefix("AppSettings.swift:") && $0.contains("defaults.set(language") },
                      writers.joined(separator: "\n"))
    }
}

/// A defaults suite that remembers the order of its writes. The typed setters
/// (`set(_: Bool, …)`) end up here too.
private final class RecordingDefaults: UserDefaults {
    private(set) var keys: [String] = []

    override func set(_ value: Any?, forKey defaultName: String) {
        keys.append(defaultName)
        super.set(value, forKey: defaultName)
    }
}
