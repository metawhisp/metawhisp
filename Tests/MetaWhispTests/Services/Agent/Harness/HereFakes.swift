import Foundation
@testable import MetaWhisp

/// The user's window as the hands meet it, for tests (ITER-076 stage 11): every act asked of it is kept, in order;
/// a field takes the focus and a paste unless the test says otherwise; a text, once pasted, shows the options the
/// test set for it. Reads — whether the app is in front, which options show — are not acts and are not kept.
@MainActor
final class FakeHereWorld: HereWorld {
    enum Act: Equatable {
        case bringForward
        case focus(String)
        case paste(String, into: String)
        case press(String)
    }

    private(set) var acts: [Act] = []
    var frontmost = true
    var comesForward = true
    var refusesFocus: Set<String> = []
    var refusesPaste: Set<String> = []
    /// The options the page shows for a text before it is pasted, and once it is.
    var optionsBefore: [String: [HereOption]] = [:]
    var optionsAfter: [String: [HereOption]] = [:]
    /// Runs as each paste is made, once it is on record.
    var onPaste: (() -> Void)?
    var onBringForward: (() -> Void)?
    var onFocus: (() -> Void)?
    var onOptions: (() -> Void)?
    private var pasted: Set<String> = []

    func isFrontmost(_ pid: pid_t) -> Bool { frontmost }

    func bringForward(_ pid: pid_t) async -> Bool {
        acts.append(.bringForward)
        onBringForward?()
        if comesForward { frontmost = true }
        return comesForward
    }

    func focus(_ field: HereField) async -> Bool {
        acts.append(.focus(field.label))
        onFocus?()
        return !refusesFocus.contains(field.label)
    }

    func paste(_ text: String, into field: HereField, of pid: pid_t) async -> Bool {
        acts.append(.paste(text, into: field.label))
        onPaste?()
        guard !refusesPaste.contains(field.label) else { return false }
        pasted.insert(text)
        return true
    }

    func options(titled text: String, in pid: pid_t) async -> [HereOption] {
        onOptions?()
        return pasted.contains(text) ? optionsAfter[text] ?? optionsBefore[text] ?? [] : optionsBefore[text] ?? []
    }

    func press(_ option: HereOption) async -> Bool {
        acts.append(.press(option.title))
        return true
    }
}
