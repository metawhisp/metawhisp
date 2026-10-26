import Foundation

/// What an action visibly did, from the look before it to the look after it, as a reference browser agent tells it
/// (`effects.py` `effect`, MIT): the address it went to, each control whose words, value or tick changed,
/// and the controls shown or removed. Told only "click Apple -> executed", the verifier could not tell a filter
/// ticked from one unticked, and named a requirement the steps had met missing again and again (2026-10-16).
enum StepEffect {
    /// Controls named in one change list or one list of controls shown or removed.
    static let shown = 4
    /// The longest a name or a value is shown.
    static let textLimit = 60

    static func summary(from before: ObservedPage, to after: ObservedPage) -> String {
        var parts: [String] = []
        if before.url != after.url { parts.append("went to " + short(after.url)) }
        // A control keeps its key for its document's life; another document numbers its own from the start. A
        // report made by hand has neither keys nor the address its document came from.
        let sameDocument = before.loadedFrom == after.loadedFrom
        let old = sameDocument ? keyed(before.elements) : [:]
        let new = sameDocument ? keyed(after.elements) : [:]
        // A control redrawn as another element is compared with the one earlier control sharing its role and
        // name, if exactly one did and it is gone.
        var namesakes: [String: [ObservedElement]] = [:]
        for element in before.elements { namesakes[namesake(element), default: []].append(element) }
        var changes: [String] = []
        for now in after.elements {
            let was: ObservedElement
            if let id = identity(now), let earlier = old[id], earlier.role == now.role {
                was = earlier
            } else if let alike = namesakes[namesake(now)], alike.count == 1,
                      identity(alike[0]).map({ new[$0] == nil }) ?? true {
                was = alike[0]
            } else {
                continue
            }
            if plain(was.name) != plain(now.name) {
                changes.append("\(short(was.name)) label: \(short(was.name)) -> \(short(now.name))")
            }
            if was.value != now.value {
                changes.append("\(short(was.name)) value: \(short(was.value)) -> \(short(now.value))")
            }
            if was.checked != now.checked {
                changes.append("\(short(was.name)) checked: \(short(was.checked)) -> \(short(now.checked))")
            }
        }
        if !changes.isEmpty {
            parts.append("changed " + changes.prefix(shown).joined(separator: "; ")
                         + (changes.count > shown ? " and \(changes.count - shown) more" : ""))
        }
        // Without one document's keys on both sides, every control is new and every earlier one gone.
        let appeared = sameDocument ? after.elements.filter { identity($0).map { old[$0] == nil } ?? false }
            : after.elements
        let gone = sameDocument ? before.elements.filter { identity($0).map { new[$0] == nil } ?? false }
            : before.elements
        if !appeared.isEmpty { parts.append("showed " + listed(appeared)) }
        if !gone.isEmpty { parts.append("removed " + listed(gone)) }
        return parts.isEmpty ? "nothing visible changed" : parts.joined(separator: "; ")
    }

    /// A control's key within its frame, when the page reports one.
    private static func identity(_ element: ObservedElement) -> String? {
        element.key.map { "\(element.frame ?? "")#\($0)" }
    }

    /// The controls by their keys, leaving out a key two controls share.
    private static func keyed(_ elements: [ObservedElement]) -> [String: ObservedElement] {
        var found: [String: [ObservedElement]] = [:]
        for element in elements { if let id = identity(element) { found[id, default: []].append(element) } }
        return found.compactMapValues { $0.count == 1 ? $0[0] : nil }
    }

    private static func namesake(_ element: ObservedElement) -> String {
        element.role + "\u{1F}" + element.name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func plain(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }

    private static func short(_ value: Bool?) -> String {
        value.map { $0 ? "true" : "false" } ?? "empty"
    }

    private static func short(_ value: String?) -> String {
        let text = (value ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !text.isEmpty else { return "empty" }
        return text.count <= textLimit ? text : String(text.prefix(textLimit - 1)) + "…"
    }

    private static func listed(_ controls: [ObservedElement]) -> String {
        let count = "\(controls.count) control\(controls.count == 1 ? "" : "s")"
        let names = controls.prefix(shown).map { short($0.name) }.joined(separator: ", ")
        return count + ": " + names + (controls.count > shown ? " and \(controls.count - shown) more" : "")
    }
}
