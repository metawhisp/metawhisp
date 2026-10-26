import Foundation
import ObjCExceptionCatcher

/// An Objective-C exception, caught where our code calls a framework that raises one.
///
/// AppKit swallows an exception that reaches its run loop and runs the app on; but one that escaped a main-actor job
/// leaves the main queue stopped for good and the runtime's record of the current executor pointing at a dead frame —
/// the next main-actor check then crashes. On 2026-10-11 at 23:37 an AVFAudio exception escaped during a dark wake;
/// the app crashed at the wake ten hours later in `MainActor.assumeIsolated` (reproduced on macOS 26.5.1).
struct ObjCRaise: Error, CustomStringConvertible {
    let name: String
    let reason: String

    var description: String { "\(name): \(reason)" }

    /// Runs `body`; an Objective-C exception it raises comes back as a thrown `ObjCRaise`, a Swift error as itself.
    /// An exception skips the cleanup of the Swift frames it passes, so `body` holds only the framework call.
    static func catching<T>(_ body: () throws -> T) throws -> T {
        var result: Result<T, Error>?
        if let exception = MWCatchObjCException({ result = Result { try body() } }) {
            throw ObjCRaise(name: exception.name.rawValue, reason: exception.reason ?? "")
        }
        guard let result else { preconditionFailure("the catcher returned without running its block") }
        return try result.get()
    }
}
