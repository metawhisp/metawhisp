import Foundation

/// Typing that lands (ITER-076 I-07): a person's typing into the field a
/// person's click has just reached, ported from a reference browser agent's
/// `_fill` (`page.py` 753-846, MIT). The text goes where the focus went — the
/// field, or the editable field the page put at its point (a framework's
/// hydrated copy, an editor opened over it) — and is then checked to be in
/// it; an editor that took the focus a moment too late, and so never got the
/// text, is typed into once more, and no field more than that. A native date
/// or time input takes its ISO value through its setter. A field that lists
/// suggestions is given a bounded wait for them before the page is read.
///
/// The act is `type`, the check `finish`. No text goes in once `stopping`
/// says Stop; `finish` reads what landed once the page has settled — it runs
/// as an action's postcondition does, after Stop too. A secret field is never
/// typed into: the page scripts vet the field that has the focus as the
/// observer vets every field, and the text goes in in the same renderer task
/// as its field's last check (`ActionScript.typeText`), the date's value with
/// its own (Codex review of I-07, P2-1, round 2): no page code runs between.
@MainActor
enum TrustedTyping {
    /// Whether the text is in its field, and whether that field lists
    /// suggestions.
    struct Landing: Equatable {
        let held: Bool
        let suggests: Bool
    }

    /// What typing came to.
    enum Typed: Equatable {
        /// A secret field has the focus: the page is the user's part.
        case wall
        /// No text went in: no field of the page's holds the focus, or Stop
        /// came first.
        case notTyped
        /// The text went in; where it landed, or nil when Stop cut the check.
        case typed(Landing?)
    }

    /// Reads a page script's answer: nil when the page gave none. Throws what
    /// ends the errand — a lost browser, and Stop.
    typealias Read = (String) async throws -> String?

    /// Types `action`'s text after the click on its field: the field that has
    /// the focus is found and focused, the text inserted, and checked — each
    /// a script the page runs, read through `read`.
    static func type(_ action: AgentAction, on page: ObservedPage, approval: ActionScript.Approval?, read: Read,
                     stopping: () -> Bool) async throws -> Typed {
        guard action.payload != nil, !stopping(),
              let focus = ActionScript.focused(for: action, on: page, approval: approval) else { return .notTyped }
        var reply = try await read(focus).flatMap { try? ActionOutcome.decode($0) }
        var typedOnce = false
        for attempt in 0..<2 {
            switch reply?.outcome {
            case .ready?: break
            case .wall?: return .wall
            default: return typedOnce ? .typed(Landing(held: false, suggests: false)) : .notTyped
            }
            guard !stopping() else { return typedOnce ? .typed(nil) : .notTyped }
            if reply?.native == true {
                // The setter vets the field once more right before it writes
                // (Codex review of I-07, P2-1).
                guard let set = ActionScript.setDate(for: action, on: page, approval: approval) else { return .notTyped }
                switch try await read(set).flatMap({ try? ActionOutcome.decode($0) })?.outcome {
                case .wall?: return .wall
                case .held?: return .typed(Landing(held: true, suggests: false))
                case .differs?: return .typed(Landing(held: false, suggests: false))
                default: return typedOnce ? .typed(Landing(held: false, suggests: false)) : .notTyped
                }
            }
            // The field checked once more and the text written in one renderer
            // task (Codex review of I-07, round 2, P2-1): one turned secret is a
            // wall, and one that lost the focus gets nothing — no page code runs
            // between the check and the text.
            guard let insert = ActionScript.typeText(for: action, on: page, approval: approval) else { return .notTyped }
            switch try await read(insert).flatMap({ try? ActionOutcome.decode($0) })?.outcome {
            case .wall?: return .wall
            case .gone?: return typedOnce ? .typed(Landing(held: false, suggests: false)) : .notTyped
            default: break  // Written, or not, or no answer came: the check decides.
            }
            typedOnce = true
            guard !stopping(), let check = ActionScript.landed(action, on: page) else { return .typed(nil) }
            let landing = try await read(check).flatMap { try? ActionOutcome.decode($0) }
            if landing?.outcome == .held { return .typed(Landing(held: true, suggests: landing?.suggests == true)) }
            // The text went nowhere. Only another field that took the focus
            // since is typed into again, once, as a person would on seeing it.
            guard attempt == 0, !stopping(),
                  let again = ActionScript.focused(for: action, on: page, approval: approval, again: true) else { break }
            reply = try await read(again).flatMap { try? ActionOutcome.decode($0) }
        }
        return .typed(Landing(held: false, suggests: false))
    }

    /// Whether the typing held, judged once the page has settled (Codex
    /// review of I-07, P2-2): first, for a field that lists suggestions, a
    /// wait of at most 1.2 s for them, best effort — a search that sent itself
    /// has answered the question — then `settle`, then the check read again.
    /// A field the page emptied meanwhile is a failed step; none is typed into
    /// again here.
    static func finish(_ typed: Typed, action: AgentAction, on page: ObservedPage, read: Read,
                       settle: () async throws -> Void) async throws -> Bool {
        guard case .typed(let known) = typed else { return false }
        if known?.suggests == true, let wait = ActionScript.suggestions(action, on: page) {
            _ = try await read(wait)
        }
        try await settle()
        guard let check = ActionScript.landed(action, on: page) else { return false }
        return try await read(check).flatMap({ try? ActionOutcome.decode($0) })?.outcome == .held
    }
}
