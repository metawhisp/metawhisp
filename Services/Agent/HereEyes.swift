import AppKit
import ApplicationServices

/// One element of the window the user looks at, as the eyes read it through the Accessibility API (ITER-076
/// stage 11): what it is, the words that name it and what it holds, whether it takes input or a press, and what is
/// inside it. The app reads one with `HereEyes.read`; a test builds one by hand.
struct HereNode: @unchecked Sendable {
    var role: String
    var subrole: String? = nil
    var title: String? = nil
    var description: String? = nil
    var value: String? = nil
    /// The words of the element its `AXTitleUIElement` names: that element's value, else its title.
    var titleElement: String? = nil
    /// The words a field shows while it is empty (`AXPlaceholderValue`).
    var placeholder: String? = nil
    var enabled = true
    /// It can be pressed: the press is among its actions.
    var pressable = false
    var children: [HereNode] = []
    /// The live element; nil in a node made by hand.
    var element: AXUIElement? = nil
}

/// A field the hands may fill: the words that name it, its role, and its element.
struct HereField: @unchecked Sendable {
    let label: String
    let role: String
    var element: AXUIElement? = nil
}

/// What the eyes saw of a window: the fields to fill, in the page's order, and the page as a field's writer reads
/// it — its title and its words.
struct HereLook: @unchecked Sendable {
    let fields: [HereField]
    let title: String
    let text: String
}

/// What the eyes turn on in an app to see its pages, and turn off again after the fill (2026-10-13): asked with
/// `AXManualAccessibility`, Chrome 154 showed no web area for 10 s and the eyes took its toolbar's pop-ups for the
/// page's fields; asked as an assistive technology asks — `AXEnhancedUserInterface`, what VoiceOver sets — it showed
/// every field at once. An app where it is on already (VoiceOver's own) is left as it is.
final class HerePages: @unchecked Sendable {
    static let shared = HerePages()
    static let attribute = "AXEnhancedUserInterface" as CFString

    private let lock = NSLock()
    private var turnedOn: Set<pid_t> = []

    /// Turns the app's pages on for the Accessibility API when they are off. Never on the main thread: the app may
    /// be this process, whose main thread answers for it.
    func show(_ pid: pid_t) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, HereEyes.messagingTimeout)
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(app, Self.attribute, &value) == .success, (value as? Bool) == false else {
            return
        }
        // Chrome answers the set with an error yet turns the pages on (measured 2026-10-13).
        _ = AXUIElementSetAttributeValue(app, Self.attribute, kCFBooleanTrue)
        lock.lock()
        turnedOn.insert(pid)
        lock.unlock()
    }

    /// Turns off what `show` turned on in the app; nothing else. Off the main thread, as `show`.
    func restore(_ pid: pid_t) {
        lock.lock()
        let mine = turnedOn.remove(pid) != nil
        lock.unlock()
        guard mine else { return }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, HereEyes.messagingTimeout)
        _ = AXUIElementSetAttributeValue(app, Self.attribute, kCFBooleanFalse)
    }
}

/// The eyes on the window the user looks at (ITER-076 stage 11, design 2): inside its web area only — never the
/// browser's own address bar or toolbar, never a window without a page (2026-10-13) — they see each text field, text area, combobox and
/// pop-up button that is enabled, is not a secret field and holds nothing yet, named by its title, else its
/// description, else the words of the element that titles it, else the nearest text before it, else its
/// placeholder. A field nothing names is left alone: nothing could be asked of it or said back about it.
enum HereEyes {
    static let fieldRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXPopUpButton"]
    /// The most of the page's words a field's writer reads, as of any page (`ObservedPage.text`).
    static let maxText = 6_000
    /// How far up from a field its nearest text is looked for: a field alone in a wrapper, or a few, is named by
    /// the text before the wrapper (WebKit's unlabeled combobox, the stage's probe of 2026-10-07).
    static let maxClimb = 4
    /// What a list shows as an entry, and what a list is — as WebKit shows a `role=option` in a `role=listbox`.
    static let optionRoles: Set<String> = ["AXStaticText", "AXMenuItem", "AXCell", "AXRow"]
    static let listRoles: Set<String> = ["AXList", "AXMenu", "AXTable", "AXOutline"]

    /// The read is bounded (design 2): at most this many elements, this deep, this long, and so many characters of
    /// any one attribute's words.
    static let maxNodes = 4_000
    static let maxDepth = 64
    static let readTime: TimeInterval = 3
    static let maxWords = 500
    /// How long one question to the app may take before it is no answer.
    static let messagingTimeout: Float = 1

    // MARK: - What the eyes see

    /// The fields of `window`'s page. A window with no web area offers none (2026-10-13): read whole, it gave the
    /// eyes Chrome's own toolbar pop-ups before Chrome showed its page — so the read never waited for the page — and
    /// it would give them a chat's composer or a search box of any app in front.
    static func look(at window: HereNode) -> HereLook {
        guard let area = webArea(in: window) else { return HereLook(fields: [], title: words(window.title) ?? "", text: "") }
        var fields: [HereField] = []
        var texts: [String] = []
        func visit(_ node: HereNode, chain: [(parent: HereNode, index: Int)]) {
            if fieldRoles.contains(node.role) {
                if takes(node), let label = label(of: node, chain: chain) {
                    fields.append(HereField(label: label, role: node.role, element: node.element))
                }
                return
            }
            if node.role == "AXStaticText", let shown = words(node.value) ?? words(node.title) {
                texts.append(shown)
                return
            }
            for (index, child) in node.children.enumerated() { visit(child, chain: chain + [(node, index)]) }
        }
        visit(area, chain: [])
        let title = words(area.title) ?? words(area.description) ?? words(window.title) ?? ""
        return HereLook(fields: fields, title: title, text: String(texts.joined(separator: "\n").prefix(maxText)))
    }

    /// A field the hands may fill: enabled, no secret field, holding nothing yet.
    static func takes(_ node: HereNode) -> Bool {
        node.enabled && node.subrole != "AXSecureTextField" && (node.value ?? "").isEmpty
    }

    /// The words that name a field: its title, its description, the element that titles it — else the nearest
    /// text before it among its parent's children, an image looked past; when nothing comes before it there, its
    /// parent's own nearest one, up to `maxClimb` levels. The nearest thing before it being anything but a text — a
    /// control, a heading — names nothing: that text is another's. Else its placeholder: many forms write their
    /// fields' names only there (2026-10-07).
    static func label(of node: HereNode, chain: [(parent: HereNode, index: Int)]) -> String? {
        if let named = words(node.title) ?? words(node.description) ?? words(node.titleElement) { return named }
        return nearestText(before: chain) ?? words(node.placeholder)
    }

    /// The nearest text before a field, as `label(of:chain:)` reads it.
    private static func nearestText(before chain: [(parent: HereNode, index: Int)]) -> String? {
        for level in chain.indices.reversed().prefix(maxClimb) {
            let (parent, index) = chain[level]
            guard let nearest = parent.children[..<index].last(where: { $0.role != "AXImage" }) else { continue }
            return nearest.role == "AXStaticText" ? words(nearest.value) ?? words(nearest.title) : nil
        }
        return nil
    }

    /// The window of the app the hands work in: its focused window, else its main window — a window on another
    /// full-screen Space is not in its `kAXWindows` list but is its main one (the brief, measured 2026-10-07) — else
    /// the frontmost of its windows: an app whose panel had just closed answered neither, its window listed
    /// (measured 2026-10-07).
    static func window<T>(focused: T?, main: T?, windows: [T]) -> T? { focused ?? main ?? windows.first }

    /// The first web area of `window`, nearest its top.
    static func webArea(in window: HereNode) -> HereNode? {
        var queue = [window]
        var next = 0
        while next < queue.count {
            let node = queue[next]
            next += 1
            if node.role == "AXWebArea" { return node }
            queue += node.children
        }
        return nil
    }

    /// The entries of the page's lists titled exactly `text`, spaces around it aside, that can be pressed — never a
    /// button, a link, a box or a field, nothing outside a list and nothing inside a field: what a combobox's text
    /// may have opened.
    static func options(titled text: String, in window: HereNode) -> [HereNode] {
        guard let wanted = words(text) else { return [] }
        var found: [HereNode] = []
        func visit(_ node: HereNode, in list: Bool) {
            guard !fieldRoles.contains(node.role) else { return }
            if list, node.pressable, optionRoles.contains(node.role), words(node.title) == wanted { found.append(node) }
            for child in node.children { visit(child, in: listRoles.contains(node.role)) }
        }
        visit(webArea(in: window) ?? window, in: false)
        return found
    }

    /// Words as a person reads them: spaces and line breaks around them dropped; none when nothing is left.
    static func words(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    // MARK: - Reading a window

    /// The window of the app `pid` the user looks at, read whole within the bounds; nil when it has none. The app
    /// is first asked to show its pages' elements (`AXManualAccessibility`, the brief's design 6) — an app with no
    /// such attribute says so; Chrome 154 did (measured 2026-10-07), and showed its page's fields only after a few
    /// reads, which `DoHere.read` makes. Never on the main thread: the window may be this process's own, whose main
    /// thread answers for it.
    static func read(pid: pid_t) -> HereNode? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        _ = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        guard let window = window(focused: element(app, kAXFocusedWindowAttribute),
                                  main: element(app, kAXMainWindowAttribute), windows: elements(app, kAXWindowsAttribute))
        else { return nil }
        var left = maxNodes
        return node(window, depth: 0, left: &left, until: Date().addingTimeInterval(readTime))
    }

    private static let attributesRead: [String] = [kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute,
                                         kAXDescriptionAttribute, kAXValueAttribute, kAXTitleUIElementAttribute,
                                         kAXEnabledAttribute, kAXChildrenAttribute,
                                         kAXPlaceholderValueAttribute as String]

    private static func node(_ element: AXUIElement, depth: Int, left: inout Int, until end: Date) -> HereNode {
        left -= 1
        var values: CFArray?
        _ = AXUIElementCopyMultipleAttributeValues(element, attributesRead as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0),
                                                   &values)
        let got = (values as? [AnyObject]) ?? []
        func at(_ index: Int) -> AnyObject? { index < got.count ? got[index] : nil }
        var node = HereNode(role: at(0) as? String ?? "")
        node.subrole = at(1) as? String
        node.title = bounded(at(2) as? String)
        node.description = bounded(at(3) as? String)
        node.value = bounded(at(4) as? String)
        if let titled = at(5), CFGetTypeID(titled) == AXUIElementGetTypeID() {
            let titler = titled as! AXUIElement
            node.titleElement = bounded(string(titler, kAXValueAttribute) ?? string(titler, kAXTitleAttribute))
        }
        node.enabled = at(6) as? Bool ?? true
        node.placeholder = bounded(at(8) as? String)
        if optionRoles.contains(node.role) {
            var actions: CFArray?
            _ = AXUIElementCopyActionNames(element, &actions)
            node.pressable = ((actions as? [String]) ?? []).contains(kAXPressAction)
        }
        node.element = element
        guard depth < maxDepth, let children = at(7) as? [AXUIElement] else { return node }
        for child in children {
            guard left > 0, Date() < end else { break }
            node.children.append(self.node(child, depth: depth + 1, left: &left, until: end))
        }
        return node
    }

    private static func element(_ of: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(of, attribute as CFString, &value) == .success, let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func elements(_ of: AXUIElement, _ attribute: String) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(of, attribute as CFString, &value) == .success else { return [] }
        return (value as? [AXUIElement]) ?? []
    }

    private static func string(_ of: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(of, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func bounded(_ text: String?) -> String? { text.map { String($0.prefix(maxWords)) } }
}
