import Foundation
import IOKit.pwr_mgt

/// Keeps the Mac from sleeping on idle while an errand runs (owner decision
/// 12 of 2026-09-26): one IOKit assertion, from the errand's start to its end.
/// A closed lid or a sleep the user asks for still sleeps the Mac, and that
/// stops the errand.
@MainActor
final class KeepAwake {
    /// Makes the assertion; nil when the system refused it.
    typealias Create = () -> IOPMAssertionID?
    typealias Release = (IOPMAssertionID) -> Void

    private let createAssertion: Create
    private let releaseAssertion: Release
    private var held: IOPMAssertionID?

    init(create: @escaping Create = KeepAwake.systemCreate, release: @escaping Release = KeepAwake.systemRelease) {
        createAssertion = create
        releaseAssertion = release
    }

    var isHeld: Bool { held != nil }

    /// Holds the assertion, unless it is held already. A refused one is not
    /// held, and the next hold asks again.
    func hold() {
        guard held == nil else { return }
        held = createAssertion()
        if let held { NSLog("[KeepAwake] held %u", held) }
    }

    func release() {
        guard let id = held else { return }
        held = nil
        releaseAssertion(id)
        NSLog("[KeepAwake] released %u", id)
    }

    nonisolated static func systemCreate() -> IOPMAssertionID? {
        var id = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                                 IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                 "MetaWhisp is running an errand" as CFString, &id)
        guard result == kIOReturnSuccess else {
            NSLog("[KeepAwake] ❌ not held — IOReturn %d", result)
            return nil
        }
        return id
    }

    nonisolated static func systemRelease(_ id: IOPMAssertionID) {
        IOPMAssertionRelease(id)
    }
}
