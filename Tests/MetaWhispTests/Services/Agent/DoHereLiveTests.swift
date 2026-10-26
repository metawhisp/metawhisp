import AppKit
import ApplicationServices
import WebKit
import XCTest
@testable import MetaWhisp

/// ITER-076 stage 11, live — "fill this page" on a window of the test's own: an `NSWindow` with a `WKWebView` that
/// shows a profile form whose fields are controlled in its script, React-style (each value lives in the page's
/// state and changes only on an `input` event). `doHere` reads that window through the Accessibility API and fills
/// it with its own hands — the borrowed clipboard and one ⌘V to the window's process — so the page's state holding
/// the values proves real input events. No app of the user's is touched: every key goes to this process alone, and
/// the test never takes the user's keyboard — its process keeps the test runner's policy, which macOS never lets
/// become the active app, and its window lets every click through. (2026-10-07: versions that let the process be
/// the active app took the owner's own typing — a ⌘V, a Shift+Enter, letters — into the test's form.) The hands are
/// told the test's window is the one in front; bringing an app forward is the unit tests' (`HereHandsTests`).
///
/// The window gets an Edit menu whose Paste goes to the web view, as a browser's does: in a test process WebKit's
/// own check of Paste reads an editor state the page has not sent there yet (the stage's spike, 2026-10-07).
@MainActor
final class DoHereLiveTests: XCTestCase, WKNavigationDelegate {

    /// The form: labeled fields, a text area, a combobox whose list has no exact entry for its text, a field the
    /// model knows nothing for, an unlabeled combobox named by the text before its wrapper, a password, a field
    /// already filled, a disabled one, a select, a box, a field named only by `aria-label`, one named only by its
    /// placeholder, and Save. The page counts its sends and keeps every key, click and input it sees.
    static let form = """
    <!doctype html><html><head><meta charset="utf-8"><title>Edit your profile</title></head><body>
    <h1>Edit your profile</h1>
    <form id="profile">
      <label for="first">First Name</label> <input id="first" type="text"><br>
      <label for="last">Last Name</label> <input id="last" type="text"><br>
      <label for="bio">Bio</label> <textarea id="bio"></textarea><br>
      <label for="company">Company</label>
      <input id="company" role="combobox" aria-autocomplete="list" aria-controls="company-list" aria-expanded="false">
      <ul id="company-list" role="listbox" hidden></ul><br>
      <label for="job">Job Title</label> <input id="job" type="text"><br>
      <div><span>Country</span>
        <div><input id="country" role="combobox" aria-autocomplete="list" aria-controls="country-list"
                    aria-expanded="false"></div>
        <ul id="country-list" role="listbox" hidden></ul>
      </div>
      <label for="pw">Password</label> <input id="pw" type="password"><br>
      <label for="nick">Nickname</label> <input id="nick" type="text"><br>
      <label for="off">Disabled</label> <input id="off" type="text" disabled><br>
      <label for="lang">Language</label> <select id="lang"><option value="">Choose</option><option>English</option></select><br>
      <label><input id="agree" type="checkbox"> I agree</label><br>
      <input id="twitter" type="text" aria-label="Twitter"><br>
      <input id="site" type="text" placeholder="Website"><br>
      <button type="submit" id="save">Save</button>
    </form>
    <script>
    window.submits = 0; window.keys = []; window.clicks = []; window.inputs = [];
    window.state = { first: "", last: "", bio: "", company: "", job: "", country: "", pw: "", nick: "Already here",
                     off: "", twitter: "", site: "" };
    const lists = { company: ["Acme Corp", "Acme Labs"], country: ["Germany", "Georgia", "Ghana"] };
    document.getElementById('profile').addEventListener('submit', (e) => { e.preventDefault(); window.submits++; });
    for (const kind of ['keydown', 'keyup']) {
      document.addEventListener(kind, (e) => window.keys.push(kind + ':' + e.key + ':' + e.metaKey), true);
    }
    document.addEventListener('click', (e) => window.clicks.push(e.target.tagName + '#' + (e.target.id || e.target.textContent)), true);
    const render = (id) => { const el = document.getElementById(id); if (el.value !== window.state[id]) el.value = window.state[id]; };
    for (const id of Object.keys(window.state)) {
      render(id);
      document.getElementById(id).addEventListener('input', (e) => {
        window.inputs.push(id + ':' + e.inputType);
        window.state[id] = e.target.value;
        render(id);
        if (!lists[id]) return;
        const list = document.getElementById(id + '-list');
        list.innerHTML = '';
        const typed = e.target.value.toLowerCase();
        const shown = lists[id].filter((entry) => typed && entry.toLowerCase().startsWith(typed.slice(0, 2)));
        for (const entry of shown) {
          const option = document.createElement('li');
          option.setAttribute('role', 'option');
          option.textContent = entry;
          option.addEventListener('click', () => { window.state[id] = entry; render(id); window.inputs.push(id + ':picked:' + entry); list.hidden = true; });
          list.appendChild(option);
        }
        list.hidden = shown.length === 0;
      });
    }
    </script></body></html>
    """

    private var loaded = false

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated { loaded = true }
    }

    /// The test's own answers for text 16, by the field's name: one for every field it may be asked about, the Job
    /// Title not known.
    nonisolated private static let texts: [String: String?] = [
        "First Name": "Sam", "Last Name": "Example", "Bio": "Builds voice tools.", "Company": "Acme",
        "Job Title": nil, "Country": "Germany", "Twitter": "@sam", "Website": "https://example.test",
    ]

    func testFillsTheTestsOwnFormThroughRealInputEventsAndSendsNothing() async throws {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any] ?? [:]
        try XCTSkipIf(NSScreen.main == nil || CGDisplayIsAsleep(CGMainDisplayID()) != 0
                      || session["CGSSessionScreenIsLocked"] as? Bool == true, "needs a screen that is awake and unlocked")
        try XCTSkipUnless(AXIsProcessTrusted(), "needs the Accessibility permission")

        let window = try await HereTestWindow.open(Self.form, delegate: self, loaded: { [unowned self] in loaded })
        defer { window.close() }
        let pasteboard = NSPasteboard.general
        let clipboard = (pasteboard.string(forType: .string), pasteboard.types ?? [])

        let model = RecordedModel { asked, _ in
            let user = asked.contents.last.flatMap { $0 } ?? ""
            let input = (try? JSONSerialization.jsonObject(with: Data(user.utf8))) as? [String: Any] ?? [:]
            let label = (input["field"] as? [String: Any])?["label"] as? String ?? ""
            guard let known = Self.texts[label] else { return .status(400) }
            return .text(known.map { #"{"text": "\#($0)"}"# } ?? #"{"text": null}"#)
        }
        let facts = FormFacts.collect(memories: [FormFacts.Memory(content: "My name is Sam Example", toldMetaChat: true,
                                                                  createdAt: .now)], proEmail: "sam@example.test")
        let here = DoHere(app: { getpid() }, look: DoHere.read, facts: { _ in facts }, model: model.model,
                          hands: AXHands(frontmost: { $0 == getpid() }))
        let result = await window.whilePumping { await here.run(goal: "fill this page") }

        XCTAssertEqual(result, HereResult(filled: ["First Name", "Last Name", "Bio", "Country", "Twitter", "Website"],
                                          unknown: ["Job Title"], pick: ["Company"]))
        XCTAssertEqual(Set(model.requests("field_text").map { asked -> String in
            let user = asked.contents.last.flatMap { $0 } ?? ""
            let input = (try? JSONSerialization.jsonObject(with: Data(user.utf8))) as? [String: Any] ?? [:]
            return (input["field"] as? [String: Any])?["label"] as? String ?? ""
        }), Set(Self.texts.keys), "every field the eyes should see, and no other")

        // The page's own state holds what was put in — input events, not a value set from outside.
        let state = try await window.json("window.state")
        XCTAssertEqual(state["first"] as? String, "Sam")
        XCTAssertEqual(state["last"] as? String, "Example")
        XCTAssertEqual(state["bio"] as? String, "Builds voice tools.")
        XCTAssertEqual(state["company"] as? String, "Acme", "the text stays for the user to pick")
        XCTAssertEqual(state["country"] as? String, "Germany")
        XCTAssertEqual(state["twitter"] as? String, "@sam")
        XCTAssertEqual(state["site"] as? String, "https://example.test", "a field named only by its placeholder")
        // Left alone: not known, secret, already filled, disabled.
        XCTAssertEqual(state["job"] as? String, "")
        XCTAssertEqual(state["pw"] as? String, "")
        XCTAssertEqual(state["nick"] as? String, "Already here")
        XCTAssertEqual(state["off"] as? String, "")
        let inputs = try await window.list("window.inputs")
        for id in ["first", "last", "bio", "company", "country", "twitter", "site"] {
            XCTAssertTrue(inputs.contains("\(id):insertFromPaste"), "\(id): \(inputs)")
        }
        XCTAssertTrue(inputs.contains("country:picked:Germany"), "the option titled the text was pressed")

        // Nothing sent, no button, no box: the only click is the option's, the only keys ⌘V.
        let submits = try await window.number("window.submits")
        let clicks = try await window.list("window.clicks")
        let ticked = try await window.number("document.getElementById('agree').checked ? 1 : 0")
        XCTAssertEqual(submits, 0)
        XCTAssertEqual(clicks, ["LI#Germany"])
        XCTAssertEqual(ticked, 0)
        // Every key event the process got: one ⌘V, down and up, for each of the seven texts put in — no Return, no
        // Enter, nothing else. The page itself saw no key: its window never takes them.
        XCTAssertTrue(window.keysSeen.allSatisfy { $0.code == 9 && $0.command }, "\(window.keysSeen)")
        XCTAssertEqual(window.keysSeen.map(\.down), Array(repeating: [true, false], count: 7).flatMap { $0 })
        let keys = try await window.list("window.keys")
        XCTAssertEqual(keys, [])
        XCTAssertFalse(window.wasActive, "the user's keyboard was never taken")

        // The clipboard is the user's again.
        XCTAssertEqual(pasteboard.string(forType: .string), clipboard.0)
        XCTAssertEqual(pasteboard.types ?? [], clipboard.1)
    }
}

/// The test's own window with its own page, shown without taking the user's keyboard: the test runner made an app
/// that is never the active one (`.prohibited`, its own policy, kept), with an Edit menu whose Paste goes to the page,
/// and every key event the process gets kept — and whether it ever was the active app.
@MainActor
final class HereTestWindow: NSObject, NSMenuItemValidation {
    struct Key: Equatable, CustomStringConvertible {
        let code: UInt16
        let command: Bool
        let down: Bool
        var description: String { "\(code)\(command ? "+cmd" : "")\(down ? "↓" : "↑")" }
    }

    let window: NSWindow
    let web: WKWebView
    /// Every key event this process got while the window pumped them, in order.
    private(set) var keysSeen: [Key] = []
    /// The process was the active app at some moment while the window pumped: the user's keys could reach it.
    private(set) var wasActive = false
    private let menu: NSMenu?
    private static var launched = false

    private init(window: NSWindow, web: WKWebView, menu: NSMenu?) {
        self.window = window
        self.web = web
        self.menu = menu
    }

    static func open(_ html: String, delegate: WKNavigationDelegate, loaded: @escaping () -> Bool) async throws
        -> HereTestWindow {
        let app = NSApplication.shared
        guard app.activationPolicy() == .prohibited else { throw XCTSkip("the test runner's app could be activated") }
        if !launched {
            app.finishLaunching()
            launched = true
        }
        let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 700, height: 760), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "MetaWhisp test form"
        // A click of the user's goes through it, to whatever is behind: it never brings the test to the front.
        window.ignoresMouseEvents = true
        let web = WKWebView(frame: window.contentView?.bounds ?? .zero)
        web.navigationDelegate = delegate
        window.contentView = web
        let opened = HereTestWindow(window: window, web: web, menu: app.mainMenu)
        let edit = NSMenu(title: "Edit")
        let paste = NSMenuItem(title: "Paste", action: #selector(HereTestWindow.pasteIntoPage(_:)), keyEquivalent: "v")
        paste.target = opened
        edit.addItem(paste)
        let bar = NSMenu()
        let item = NSMenuItem()
        item.submenu = edit
        bar.addItem(item)
        app.mainMenu = bar
        web.loadHTMLString(html, baseURL: URL(string: "https://profile.example.test/edit"))
        let deadline = Date().addingTimeInterval(10)
        while !loaded(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        guard loaded() else {
            opened.close()
            throw XCTSkip("the test page did not load")
        }
        window.orderFrontRegardless()
        window.makeFirstResponder(web)
        await opened.pump(for: .milliseconds(300))
        return opened
    }

    @objc func pasteIntoPage(_ sender: Any?) {
        NSApp.sendAction(#selector(NSText.paste(_:)), to: web, from: sender)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { true }

    /// Runs `work` while the process's events are handed out, as an app's run loop would.
    func whilePumping<T>(_ work: () async -> T) async -> T {
        let pumping = Task { @MainActor in
            while !Task.isCancelled { await pump(for: .milliseconds(20)) }
        }
        let value = await work()
        pumping.cancel()
        _ = await pumping.value
        return value
    }

    private func pump(for span: Duration) async {
        let until = Date().addingTimeInterval(Double(span.components.seconds) + Double(span.components.attoseconds) / 1e18)
        while Date() < until {
            if NSApp.isActive { wasActive = true }
            if let event = NSApp.nextEvent(matching: .any, until: Date(timeIntervalSinceNow: 0.005), inMode: .default,
                                           dequeue: true) {
                if event.type == .keyDown || event.type == .keyUp {
                    keysSeen.append(Key(code: event.keyCode, command: event.modifierFlags.contains(.command),
                                        down: event.type == .keyDown))
                }
                NSApp.sendEvent(event)
            }
            await Task.yield()
        }
    }

    func json(_ expression: String) async throws -> [String: Any] {
        let text = try await evaluate("JSON.stringify(\(expression))")
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    func list(_ expression: String) async throws -> [String] {
        let text = try await evaluate("JSON.stringify(\(expression))")
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String])
    }

    func number(_ expression: String) async throws -> Int {
        let text = try await evaluate("String(\(expression))")
        return try XCTUnwrap(Int(text))
    }

    private func evaluate(_ script: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            web.evaluateJavaScript(script) { value, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: "\(value ?? "")") }
            }
        }
    }

    /// The window gone, the menu as it was.
    func close() {
        window.orderOut(nil)
        window.close()
        NSApp.mainMenu = menu
    }
}
