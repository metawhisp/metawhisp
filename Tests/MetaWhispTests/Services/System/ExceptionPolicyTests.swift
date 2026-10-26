import XCTest
@testable import MetaWhisp

/// An exception that reaches AppKit is not caught anywhere near where it was raised; AppKit then runs the app on with
/// a stopped main queue. The app ends at the throw instead, with AppKit's report of what raised.
final class ExceptionPolicyTests: XCTestCase {

    func testAnExceptionThatReachesAppKitEndsTheApp() throws {
        let suite = "ExceptionPolicyTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertFalse(defaults.bool(forKey: "NSApplicationCrashOnExceptions"))
        ExceptionPolicy.register(in: defaults)
        XCTAssertTrue(defaults.bool(forKey: "NSApplicationCrashOnExceptions"))
    }

    /// A registered default: a value set explicitly still wins.
    func testAnExplicitSettingStillWins() throws {
        let suite = "ExceptionPolicyTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "NSApplicationCrashOnExceptions")
        ExceptionPolicy.register(in: defaults)
        XCTAssertFalse(defaults.bool(forKey: "NSApplicationCrashOnExceptions"))
    }
}
