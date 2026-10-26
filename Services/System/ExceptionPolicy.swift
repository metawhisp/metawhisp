import Foundation

/// What the app does with an exception that reaches AppKit after all: end at the throw. Running on, the main queue is
/// stopped and the next main-actor check crashes somewhere unrelated, hours later; ended at once, the crash report has
/// the right time and AppKit first logs what raised (`log show --predicate 'process == "MetaWhisp" AND category ==
/// "General"'`).
enum ExceptionPolicy {
    static let crashOnExceptionsKey = "NSApplicationCrashOnExceptions"

    /// A registered default: a value the user set explicitly still wins.
    static func register(in defaults: UserDefaults) {
        defaults.register(defaults: [crashOnExceptionsKey: true])
    }
}
