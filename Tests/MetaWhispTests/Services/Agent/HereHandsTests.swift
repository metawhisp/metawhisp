import AppKit
import Carbon
import CoreGraphics
import XCTest
@testable import MetaWhisp

/// ITER-076 stage 11 — the hands in the window the user looks at: each text goes in as dictation puts text in —
/// the field focused, the clipboard borrowed for one ⌘V and given back, the field read back — in the page's
/// order; a combobox's option is pressed only when one titled exactly its text appears; nothing else is ever done:
/// no Return, no Enter, no button, no box, nothing sent.
@MainActor
final class HereHandsTests: XCTestCase {
    private let pid: pid_t = 4_242

    private func field(_ label: String, _ role: String = "AXTextField") -> HereField {
        HereField(label: label, role: role)
    }

    private func fill(_ work: [(HereField, String)], in world: FakeHereWorld) async -> [HereHands.Outcome] {
        await HereHands.fill(work.map { (field: $0.0, text: $0.1) }, of: pid, in: world, optionWait: .milliseconds(60))
    }

    /// Each field in the page's order: focused, then its text pasted — and read back holding it, which the world
    /// says by the paste's answer.
    func testEachFieldIsFocusedThenItsTextPastedInThePagesOrder() async {
        let world = FakeHereWorld()
        let done = await fill([(field("First Name"), "Sam"), (field("Last Name"), "Example")], in: world)
        XCTAssertEqual(world.acts, [.focus("First Name"), .paste("Sam", into: "First Name"),
                                    .focus("Last Name"), .paste("Example", into: "Last Name")])
        XCTAssertEqual(done, [.filled, .filled])
    }

    /// The window's app comes forward first when it is not in front — once.
    func testTheAppIsBroughtForwardWhenItIsNotInFront() async {
        let world = FakeHereWorld()
        world.frontmost = false
        let done = await fill([(field("First Name"), "Sam"), (field("Last Name"), "Example")], in: world)
        XCTAssertEqual(world.acts.first, .bringForward)
        XCTAssertEqual(world.acts.filter { $0 == .bringForward }.count, 1)
        XCTAssertEqual(done, [.filled, .filled])
    }

    /// An app that does not come forward gets nothing: no focus moved, nothing pasted.
    func testNothingGoesInWhenTheAppDoesNotComeForward() async {
        let world = FakeHereWorld()
        world.frontmost = false
        world.comesForward = false
        let done = await fill([(field("First Name"), "Sam")], in: world)
        XCTAssertEqual(world.acts, [.bringForward])
        XCTAssertEqual(done, [.notFilled])
    }

    /// A field that does not take the focus gets nothing; the next one goes on.
    func testAFieldThatTakesNoFocusGetsNothing() async {
        let world = FakeHereWorld()
        world.refusesFocus = ["First Name"]
        let done = await fill([(field("First Name"), "Sam"), (field("Last Name"), "Example")], in: world)
        XCTAssertEqual(world.acts, [.focus("First Name"), .focus("Last Name"), .paste("Example", into: "Last Name")])
        XCTAssertEqual(done, [.notFilled, .filled])
    }

    /// A paste the field does not hold afterwards is no fill.
    func testAPasteTheFieldDoesNotHoldIsNoFill() async {
        let world = FakeHereWorld()
        world.refusesPaste = ["First Name"]
        let done = await fill([(field("First Name"), "Sam")], in: world)
        XCTAssertEqual(done, [.notFilled])
    }

    /// A combobox: once its text is in, an option titled exactly its text that appeared is pressed — the field is
    /// filled.
    func testAComboboxPressesTheOptionTitledItsTextThatAppears() async {
        let world = FakeHereWorld()
        world.optionsAfter["Germany"] = [HereOption(title: "Germany", id: 1)]
        let done = await fill([(field("Country", "AXComboBox"), "Germany")], in: world)
        XCTAssertEqual(world.acts, [.focus("Country"), .paste("Germany", into: "Country"), .press("Germany")])
        XCTAssertEqual(done, [.filled])
    }

    /// No such option: the text stays, and the list is the user's to pick from.
    func testAComboboxWithNoSuchOptionIsTheUsersToPick() async {
        let world = FakeHereWorld()
        let done = await fill([(field("Company", "AXComboBox"), "Acme")], in: world)
        XCTAssertEqual(world.acts, [.focus("Company"), .paste("Acme", into: "Company")])
        XCTAssertEqual(done, [.pick])
    }

    /// An option the page showed before the text went in did not appear for it — a site's own menu entry of the
    /// same words — and is never pressed.
    func testAnOptionShownBeforeThePasteIsNeverPressed() async {
        let world = FakeHereWorld()
        world.optionsBefore["Germany"] = [HereOption(title: "Germany", id: 7)]
        let done = await fill([(field("Country", "AXComboBox"), "Germany")], in: world)
        XCTAssertFalse(world.acts.contains(.press("Germany")))
        XCTAssertEqual(done, [.pick])
        let another = FakeHereWorld()
        another.optionsBefore["Germany"] = [HereOption(title: "Germany", id: 7)]
        another.optionsAfter["Germany"] = [HereOption(title: "Germany", id: 7), HereOption(title: "Germany", id: 8)]
        let again = await fill([(field("Country", "AXComboBox"), "Germany")], in: another)
        XCTAssertEqual(again, [.filled], "the one that appeared")
        XCTAssertEqual(another.acts.last, .press("Germany"))
    }

    /// Stopped — the send closed — nothing more goes in.
    func testNothingMoreGoesInOnceStopped() async {
        let world = FakeHereWorld()
        let work: [(field: HereField, text: String)] = [(field("First Name"), "Sam"), (field("Last Name"), "Example")]
        let task = Task { @MainActor in await HereHands.fill(work, of: pid, in: world, optionWait: .milliseconds(60)) }
        world.onPaste = { task.cancel() }
        let done = await task.value
        XCTAssertEqual(world.acts, [.focus("First Name"), .paste("Sam", into: "First Name")])
        XCTAssertEqual(done, [.filled, .notFilled])
    }

    func testStopWhileBringingTheAppForwardDoesNotFocusOrPaste() async {
        let world = FakeHereWorld()
        world.frontmost = false
        let task = Task { await fill([(field("Name"), "Sam")], in: world) }
        world.onBringForward = { task.cancel() }
        let done = await task.value
        XCTAssertEqual(world.acts, [.bringForward])
        XCTAssertEqual(done, [.notFilled])
    }

    func testStopWhileFocusingDoesNotPaste() async {
        let world = FakeHereWorld()
        let task = Task { await fill([(field("Name"), "Sam")], in: world) }
        world.onFocus = { task.cancel() }
        let done = await task.value
        XCTAssertEqual(world.acts, [.focus("Name")])
        XCTAssertEqual(done, [.notFilled])
    }

    func testStopWhileReadingInitialOptionsDoesNotPaste() async {
        let world = FakeHereWorld()
        let task = Task { await fill([(field("Country", "AXComboBox"), "Germany")], in: world) }
        world.onOptions = { task.cancel() }
        let done = await task.value
        XCTAssertEqual(world.acts, [.focus("Country")])
        XCTAssertEqual(done, [.notFilled])
    }

    func testStopWhileWaitingForAnOptionDoesNotPressIt() async {
        let world = FakeHereWorld()
        world.optionsAfter["Germany"] = [HereOption(title: "Germany", id: 1)]
        let task = Task { await fill([(field("Country", "AXComboBox"), "Germany")], in: world) }
        world.onPaste = { world.onOptions = { task.cancel() } }
        let done = await task.value
        XCTAssertEqual(world.acts, [.focus("Country"), .paste("Germany", into: "Country")])
        XCTAssertEqual(done, [.pick])
    }

    // MARK: - The one key the hands send

    func testACopyMadeDuringReadinessIsNeverPastedOrOverwritten() async {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("original", forType: .string)
        var sent = false
        let done = await AXHands.pasteWhenReady("Sam", pasteboard: board, ready: {
            board.clearContents()
            board.setString("new unrelated copy", forType: .string)
            return true
        }, send: { sent = true }, landed: { true })
        XCTAssertFalse(sent)
        XCTAssertFalse(done)
        XCTAssertEqual(board.string(forType: .string), "new unrelated copy")
    }

    func testStopDuringPasteReadinessRestoresClipboardWithoutSending() async {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("original", forType: .string)
        var sent = false
        let task = Task { await AXHands.pasteWhenReady("Sam", pasteboard: board, ready: {
            withUnsafeCurrentTask { $0?.cancel() }
            return true
        }, send: { sent = true }, landed: { true }) }
        let done = await task.value
        XCTAssertFalse(sent)
        XCTAssertFalse(done)
        XCTAssertEqual(board.string(forType: .string), "original")
    }

    func testAnAlreadySentPasteSettlesBeforeClipboardRestorationAfterStop() async {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("original", forType: .string)
        var landed = false
        let task = Task { await AXHands.pasteWhenReady("Sam", pasteboard: board, ready: { true }, send: {
            XCTAssertEqual(board.string(forType: .string), "Sam")
            withUnsafeCurrentTask { $0?.cancel() }
        }, landed: {
            XCTAssertEqual(board.string(forType: .string), "Sam")
            landed = true
            return true
        }) }
        let done = await task.value
        XCTAssertTrue(done)
        XCTAssertTrue(landed)
        XCTAssertEqual(board.string(forType: .string), "original")
    }

    /// The only key events the hands ever send: ⌘V, down then up — the paste dictation makes. No Return, no
    /// Enter, no Tab, nothing else.
    func testThePasteIsOneCommandVAndNothingElse() {
        let keys = AXHands.pasteKeys()
        XCTAssertEqual(keys.count, 2)
        XCTAssertEqual(keys.map { $0.getIntegerValueField(.keyboardEventKeycode) }, [Int64(kVK_ANSI_V), Int64(kVK_ANSI_V)])
        XCTAssertEqual(keys.map { $0.type }, [.keyDown, .keyUp])
        XCTAssertTrue(keys.allSatisfy { $0.flags.contains(.maskCommand) })
    }

    /// The hands' source names no key but V, posts nothing system-wide, and performs no accessibility action but
    /// the press of an option — a key, a post or an action added fails here.
    func testTheHandsSourceHoldsNoOtherKeyPostOrAction() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../../Services/Agent").standardizedFileURL
        for name in ["HereHands.swift", "HereEyes.swift", "DoHere.swift"] {
            let source = try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
            let keys = Set(source.matches(of: #/kVK_[A-Za-z0-9_]+/#).map { String($0.output) })
            XCTAssertTrue(keys.isSubset(of: ["kVK_ANSI_V"]), "\(name): \(keys)")
            XCTAssertFalse(source.contains(".post(tap:"), "\(name): nothing posted system-wide")
            XCTAssertFalse(source.contains("CGEvent(mouseEventSource"), "\(name): no click")
            let actions = Set(source.matches(of: #/kAX[A-Za-z]+Action/#).map { String($0.output) })
            XCTAssertTrue(actions.isSubset(of: ["kAXPressAction"]), "\(name): \(actions)")
        }
        let hands = try String(contentsOf: root.appendingPathComponent("HereHands.swift"), encoding: .utf8)
        XCTAssertEqual(hands.matches(of: #/kAXPressAction/#).count, 1, "one press: an option's")
        XCTAssertEqual(hands.matches(of: #/postToPid/#).count, 1, "one post: the paste's, to the window's app")
    }
}
