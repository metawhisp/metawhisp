import AppKit
import ApplicationServices
import Carbon

/// ITER-085 — where a Target dictation is pasted, as Accessibility names it when recording starts: the app, its focused
/// window's title, the focused field's label and the web site's host. Only these names are read, never the field's
/// text or anything else on screen. The server cleans each string and caps it at 200 characters.
struct PlaceAddress: Equatable, Sendable {
    var app: String?
    var bundle: String?
    var window: String?
    var field: String?
    var site: String?
    /// A password field, or secure input on: Target asks no model, and the words go as spoken.
    var isSecure = false

    /// The longest name sent; the server caps at the same length.
    static let nameLimit = 200

    /// What the server reads as `place`: the names that are there, and nothing else — each on one line (control
    /// characters and line breaks become spaces) and at most `nameLimit` characters.
    var payload: [String: String] {
        var out: [String: String] = [:]
        for (key, value) in [("app", app), ("bundle", bundle), ("window", window), ("field", field), ("site", site)] {
            guard let value else { continue }
            let line = value.unicodeScalars
                .map { CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) ? " " : String($0) }
                .joined()
                .split(whereSeparator: \.isWhitespace)
                .joined(separator: " ")
            if !line.isEmpty { out[key] = String(line.prefix(Self.nameLimit)) }
        }
        return out
    }

    /// MetaChat, where a voice question goes whatever window had focus.
    static let metaChat = PlaceAddress(app: "MetaWhisp", window: "MetaChat", field: "Ask the AI assistant")
}

/// Reads a `PlaceAddress` from the app a dictation is pasted into.
enum PlaceReader {
    /// The deadline the caller keeps, whatever the Accessibility calls do.
    static let deadline: TimeInterval = 0.3

    /// The place of `app`, read off the main thread.
    @MainActor
    static func read(_ app: NSRunningApplication?) async -> PlaceAddress {
        guard let app else { return PlaceAddress() }
        let pid = app.processIdentifier
        return await read(name: app.localizedName, bundle: app.bundleIdentifier, within: deadline) { [name = app.localizedName, bundle = app.bundleIdentifier] in
            read(pid: pid, name: name, bundle: bundle)
        }
    }

    /// `reader` on a background thread, waited for at most `within` seconds: past it the place is the app's name and
    /// bundle alone, and the reader's late answer is dropped (its own budget ends it soon after).
    static func read(name: String?, bundle: String?, within seconds: TimeInterval,
                     reader: @escaping @Sendable () -> PlaceAddress) async -> PlaceAddress {
        let appOnly = PlaceAddress(app: name, bundle: bundle)
        return await withCheckedContinuation { continuation in
            let answer = FirstAnswer(continuation)
            DispatchQueue.global(qos: .userInitiated).async { answer.give(reader()) }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + seconds) { answer.give(appOnly) }
        }
    }

    /// Resumes its continuation with the first answer given; later ones are dropped.
    private final class FirstAnswer: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<PlaceAddress, Never>?

        init(_ continuation: CheckedContinuation<PlaceAddress, Never>) {
            self.continuation = continuation
        }

        func give(_ place: PlaceAddress) {
            lock.lock()
            let waiting = continuation
            continuation = nil
            lock.unlock()
            waiting?.resume(returning: place)
        }
    }

    /// Every Accessibility call waits at most `perCall` (set on each element read), and no call starts after `budget`:
    /// the read ends by `budget + perCall` (0.28 s), inside the caller's `deadline`, with what was read by then (its
    /// name at least). The secure check comes first.
    nonisolated static func read(pid: pid_t, name: String?, bundle: String?,
                                 perCall: Float = 0.08, budget: TimeInterval = 0.2) -> PlaceAddress {
        var place = PlaceAddress(app: name, bundle: bundle, isSecure: IsSecureEventInputEnabled())
        let deadline = Date().addingTimeInterval(budget)
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, perCall)

        func value(_ attribute: String, of element: AXUIElement) -> CFTypeRef? {
            guard Date() < deadline else { return nil }
            var raw: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success else { return nil }
            return raw
        }
        /// Every element read gets the same short timeout: one set on the app's element does not reach its children.
        func element(_ attribute: String, of parent: AXUIElement) -> AXUIElement? {
            guard let raw = value(attribute, of: parent), CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
            let child = raw as! AXUIElement
            AXUIElementSetMessagingTimeout(child, perCall)
            return child
        }
        func text(_ attribute: String, of element: AXUIElement) -> String? {
            value(attribute, of: element) as? String
        }

        let focused = element(kAXFocusedUIElementAttribute, of: app)
        if let focused {
            let protected = value(NSAccessibility.Attribute.containsProtectedContent.rawValue, of: focused) as? NSNumber
            if text(kAXSubroleAttribute, of: focused) == "AXSecureTextField" || protected?.boolValue == true {
                place.isSecure = true
            }
        }
        if let window = element(kAXFocusedWindowAttribute, of: app) {
            place.window = text(kAXTitleAttribute, of: window)
        }
        guard let focused else { return place }
        let titleElement = element(kAXTitleUIElementAttribute, of: focused)
        place.field = fieldLabel(title: text(kAXTitleAttribute, of: focused),
                                 description: text(kAXDescriptionAttribute, of: focused),
                                 placeholder: text(kAXPlaceholderValueAttribute, of: focused),
                                 titleElement: titleElement.flatMap { text(kAXValueAttribute, of: $0) ?? text(kAXTitleAttribute, of: $0) })
        // The site: the web area the field sits in names its URL.
        var node: AXUIElement? = focused
        for _ in 0..<25 {
            guard let current = node, Date() < deadline else { break }
            if text(kAXRoleAttribute, of: current) == "AXWebArea" {
                place.site = site(fromAttribute: value(kAXURLAttribute, of: current))
                    ?? site(fromAttribute: value("AXDocument", of: current))
                break
            }
            node = element(kAXParentAttribute, of: current)
        }
        return place
    }

    /// The field's label: the first of its title, description, placeholder and the text of the element that titles it.
    nonisolated static func fieldLabel(title: String?, description: String?, placeholder: String?,
                                       titleElement: String?) -> String? {
        [title, description, placeholder, titleElement]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    /// The host of a URL an Accessibility attribute gives, as a URL or as its string.
    nonisolated static func site(fromAttribute value: Any?) -> String? {
        if let url = value as? URL { return site(from: url) }
        if let string = value as? String { return site(from: URL(string: string)) }
        return nil
    }

    /// A web page's host, and only that: no path, no query.
    nonisolated static func site(from url: URL?) -> String? {
        guard let url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url.host
    }
}
