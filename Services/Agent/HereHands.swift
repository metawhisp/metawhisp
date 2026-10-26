import AppKit
import ApplicationServices
import Carbon

/// An entry of a list the page shows, as the hands may press it: its title, and its element — or, in a test, a
/// number of its own. Two are one when they are the same element of the page.
struct HereOption: Equatable, @unchecked Sendable {
    let title: String
    var element: AXUIElement? = nil
    var id = 0

    static func == (lhs: HereOption, rhs: HereOption) -> Bool {
        if let left = lhs.element, let right = rhs.element { return CFEqual(left, right) }
        return lhs.element == nil && rhs.element == nil && lhs.title == rhs.title && lhs.id == rhs.id
    }
}

/// What the hands can do in the user's window, one seam (ITER-076 stage 11, design 4): bring its app forward, give
/// a field the focus, paste a text into it, see a list's entries, press one. Nothing else — no key but the paste's,
/// no button, no box. The app's is `AXHands`; a test's keeps what is asked of it.
@MainActor
protocol HereWorld: AnyObject {
    func isFrontmost(_ pid: pid_t) -> Bool
    /// Whether the app is in front after.
    func bringForward(_ pid: pid_t) async -> Bool
    /// Whether the field has the focus after.
    func focus(_ field: HereField) async -> Bool
    /// The text into the field that has the focus, as dictation puts text in; whether the field held it after.
    func paste(_ text: String, into field: HereField, of pid: pid_t) async -> Bool
    /// The entries of the page's lists titled exactly `text`.
    func options(titled text: String, in pid: pid_t) async -> [HereOption]
    func press(_ option: HereOption) async -> Bool
}

/// The hands in the window the user looks at (ITER-076 stage 11, design 4): each text in its field, in the page's
/// order — the app brought forward when it is not in front, the field given the focus, the text pasted and read
/// back. A combobox: once its text is in, an entry of a list titled exactly its text that was not there before is
/// pressed; with none, the text stays and the list is the user's to pick from. Never Return or Enter, never a
/// button, a box, a radio or a file; nothing is sent. An app that does not come forward gets nothing more, and
/// nothing more goes in once the send that asked is stopped.
enum HereHands {
    enum Outcome: Equatable, Sendable {
        /// The text is in its field — for a combobox, its option pressed.
        case filled
        /// A combobox's text is in, and no option titled it appeared: the user picks from the list.
        case pick
        case notFilled
    }

    /// How long a combobox's list is given to show an entry for its text: a site may ask its server first.
    static let optionWait: Duration = .milliseconds(1_500)

    @MainActor
    static func fill(_ work: [(field: HereField, text: String)], of pid: pid_t, in world: HereWorld,
                     optionWait: Duration = HereHands.optionWait) async -> [Outcome] {
        var done: [Outcome] = []
        for (field, text) in work {
            guard !Task.isCancelled else { break }
            if !world.isFrontmost(pid) {
                guard await world.bringForward(pid) else { break }
            }
            guard !Task.isCancelled else { break }
            guard await world.focus(field) else {
                done.append(.notFilled)
                continue
            }
            guard !Task.isCancelled else { break }
            let combobox = field.role == "AXComboBox"
            let before = combobox ? await world.options(titled: text, in: pid) : []
            guard !Task.isCancelled else { break }
            guard await world.paste(text, into: field, of: pid) else {
                done.append(.notFilled)
                continue
            }
            guard combobox else {
                done.append(.filled)
                continue
            }
            if let option = await appeared(text, besides: before, in: pid, world: world, within: optionWait),
               !Task.isCancelled,
               await world.press(option) {
                done.append(.filled)
            } else {
                done.append(.pick)
            }
        }
        return done + Array(repeating: .notFilled, count: work.count - done.count)
    }

    /// An entry titled `text` that was not among `before`, looked for every 100 ms within `limit`.
    @MainActor
    private static func appeared(_ text: String, besides before: [HereOption], in pid: pid_t, world: HereWorld,
                                 within limit: Duration) async -> HereOption? {
        let clock = ContinuousClock()
        let end = clock.now + limit
        repeat {
            guard !Task.isCancelled else { return nil }
            if let new = await world.options(titled: text, in: pid).first(where: { !before.contains($0) }) { return new }
            guard !Task.isCancelled else { return nil }
            await rest(.milliseconds(100))
        } while clock.now < end
        return nil
    }

    /// A pause that a stopped send does not cut short: a wait that bounds itself, kept whole.
    static func rest(_ span: Duration) async {
        let seconds = Double(span.components.seconds) + Double(span.components.attoseconds) / 1e18
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { done.resume() }
        }
    }
}

/// The app's hands (ITER-076 stage 11): the Accessibility API, and text put in as dictation puts it in
/// (`TextInsertionService`): the clipboard borrowed — every representation kept, given back on every path, never
/// over a copy someone made meanwhile (`PasteboardReplacementTransaction`) — for one ⌘V, sent to the window's own
/// app and no other, so a key never lands where the user went meanwhile.
@MainActor
final class AXHands: HereWorld {
    /// How long the app is given to come forward, a field to take the focus, a paste to land.
    static let forwardWait: Duration = .seconds(1)
    static let focusWait: Duration = .milliseconds(500)
    static let landWait: Duration = .seconds(2)
    /// A field with the focus is given this long before the paste: the app checks its Paste against what its page
    /// says has the focus (the stage's probe: 100 ms).
    static let settle: Duration = .milliseconds(100)

    /// The only keys the hands send: ⌘V, down and up.
    static func pasteKeys() -> [CGEvent] {
        let source = CGEventSource(stateID: .hidSystemState)
        let keys = [true, false].compactMap {
            CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: $0)
        }
        for key in keys { key.flags = .maskCommand }
        return keys
    }

    /// Whether a process is the one in front: the system's frontmost app — a test's own window, never brought to
    /// the front, says so of itself.
    private let frontmost: (pid_t) -> Bool

    init(frontmost: @escaping (pid_t) -> Bool = { NSWorkspace.shared.frontmostApplication?.processIdentifier == $0 }) {
        self.frontmost = frontmost
    }

    func isFrontmost(_ pid: pid_t) -> Bool { frontmost(pid) }

    func bringForward(_ pid: pid_t) async -> Bool {
        guard !Task.isCancelled, let app = NSRunningApplication(processIdentifier: pid),
              app.activate(options: []) else { return false }
        return await Self.until(Self.forwardWait) { self.isFrontmost(pid) }
    }

    func focus(_ field: HereField) async -> Bool {
        guard let element = field.element else { return false }
        let set = await Self.mutate { AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue) }
        guard set == .success, await Self.until(Self.focusWait, { await Self.focused(element) }) else { return false }
        await HereHands.rest(Self.settle)
        return !Task.isCancelled
    }

    /// The text goes in only while the app is in front, the field has the focus and still holds nothing; it is in
    /// once the field holds anything — what a mask makes of it too — read back within `landWait`. The clipboard is
    /// given back after that, so a paste that lands late never takes the user's own clipboard.
    func paste(_ text: String, into field: HereField, of pid: pid_t) async -> Bool {
        guard let element = field.element else { return false }
        return await Self.pasteWhenReady(text, pasteboard: .general, ready: {
            guard await Self.focused(element), (await Self.value(of: element) ?? "").isEmpty else { return false }
            return self.isFrontmost(pid)
        }, send: {
            for key in Self.pasteKeys() { key.postToPid(pid) }
        }, landed: {
            await Self.until(Self.landWait) { !(await Self.value(of: element) ?? "").isEmpty }
        })
    }

    /// Owns the borrowed clipboard until the target has consumed the paste. The readiness read may suspend.
    static func pasteWhenReady(_ text: String, pasteboard: NSPasteboard, ready: () async -> Bool,
                               send: () -> Void, landed: () async -> Bool) async -> Bool {
        guard !Task.isCancelled else { return false }
        let borrowed = PasteboardReplacementTransaction(pasteboard: pasteboard)
        defer { borrowed.restoreIfOwned() }
        guard borrowed.prepare(replacement: text), await ready(), !Task.isCancelled,
              borrowed.stillOwns(contents: text) else { return false }
        send()
        return await landed()
    }

    func options(titled text: String, in pid: pid_t) async -> [HereOption] {
        await Self.off {
            guard let window = HereEyes.read(pid: pid) else { return [] }
            return HereEyes.options(titled: text, in: window).map { HereOption(title: text, element: $0.element) }
        }
    }

    func press(_ option: HereOption) async -> Bool {
        guard let element = option.element else { return false }
        return await Self.mutate { AXUIElementPerformAction(element, kAXPressAction as CFString) } == .success
    }

    // MARK: - Helpers

    /// Cancel queued Accessibility mutations before they begin. An action already sent is allowed to settle.
    private static func mutate(_ work: @escaping @Sendable () -> AXError) async -> AXError {
        guard !Task.isCancelled else { return .cannotComplete }
        let action = Task.detached(priority: .userInitiated) {
            guard !Task.isCancelled else { return AXError.cannotComplete }
            return work()
        }
        return await withTaskCancellationHandler(operation: { await action.value }, onCancel: { action.cancel() })
    }

    /// Accessibility work runs off the main thread: the window may be this process's own, whose main thread
    /// answers for it.
    private static func off<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await Task.detached(priority: .userInitiated) { work() }.value
    }

    private static func focused(_ element: AXUIElement) async -> Bool {
        await off {
            var value: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, kAXFocusedAttribute as CFString, &value) == .success
                && value as? Bool == true
        }
    }

    private static func value(of element: AXUIElement) async -> String? {
        await off {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success else {
                return nil
            }
            return value as? String
        }
    }

    /// Whether `check` says yes within `limit`, asked every 20 ms — the whole time, a stopped send or not: a key
    /// already sent is waited out before the clipboard goes back.
    private static func until(_ limit: Duration, _ check: () async -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let end = clock.now + limit
        while true {
            if await check() { return true }
            guard clock.now < end else { return false }
            await HereHands.rest(.milliseconds(20))
        }
    }
}
