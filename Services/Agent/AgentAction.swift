import Foundation

/// What the agent can do in one step (ITER-074 §6.2).
enum AgentOperation: String, Equatable, CaseIterable {
    case open, click, type, select, scroll, wait, back, done, stuck
    /// Show the next candidates of a page with more than fit (§6.2).
    case more
}

/// One complete action: the operation, the element it acts on, and its
/// parameters. The app builds these; a model only picks one (§6.2).
struct AgentAction: Equatable {
    let operation: AgentOperation
    /// The element acted on; nil for scroll, wait, back, done, stuck and a
    /// planned search.
    let target: ObservedElement?
    /// For `open`: the address — a link's own href or a search built from the
    /// plan's queries, never text a model wrote.
    let destination: String?
    /// For `type`: the text; for `select`: the option.
    let payload: String?
    /// The destination was built by the app from the plan's own queries.
    let isPlannedSearch: Bool
}

extension AgentAction {
    /// What an action does, whatever draws it (ITER-076 I-05): the identity a
    /// No is kept by. The operation; its control's role, name, visible words
    /// and row; where it goes — the address it opens, or the one a clicked
    /// control's own link goes to, and its form's, as a request makes them;
    /// and its option, the made-up dropdown an option is of, and the frame it
    /// is in (ITER-076 I-08, I-09). The heading above it and its place on the
    /// page are left out: a page that draws the same control again does not
    /// make it another action. A fingerprint finds a control again; this
    /// tells whether it does the same thing.
    struct Effect: Hashable {
        let operation: AgentOperation
        let role: String?
        let name: String?
        let text: String?
        let context: String?
        let destination: String?
        let formAction: String?
        let formMethod: String?
        let payload: String?
        /// The made-up dropdown an option is of (Codex review 1 of I-08,
        /// P1-2): another dropdown's option is another action. Read as every
        /// control is here, without its heading (Codex review 2 of I-08, P2-1),
        /// its addresses as every address is (Codex review 3 of I-08, P2-1).
        let listOwner: ObservedElement.ListOwner?
        /// Who the frame its control is in is — the same after a reload
        /// (ITER-076 I-09; review of I-09, F5).
        let frame: String?
    }

    var effect: Effect {
        Effect(operation: operation, role: target?.role, name: target?.name, text: target?.text,
               context: target?.context, destination: (destination ?? target?.href).map(Self.effectAddress),
               formAction: target?.formAction.map(Self.effectAddress), formMethod: target?.formMethod,
               payload: payload, listOwner: target?.listOwnerEffect.map { owner in
                   ObservedElement.ListOwner(role: owner.role, name: owner.name, context: owner.context,
                                             href: owner.href.map(Self.effectAddress),
                                             formAction: owner.formAction.map(Self.effectAddress),
                                             formMethod: owner.formMethod)
               }, frame: target?.frameIdentity)
    }

    /// An address as far as it decides what opening it does: the scheme and
    /// the host in lower case, and no fragment — an anchor on the page
    /// requests nothing — unless the fragment is a client-side route
    /// (`#/…`, `#!/…`), which is a place of its own.
    static func effectAddress(_ address: String) -> String {
        guard var parts = URLComponents(string: address) else { return address }
        parts.scheme = parts.scheme?.lowercased()
        parts.host = parts.host?.lowercased()
        if let fragment = parts.fragment, !(fragment.hasPrefix("/") || fragment.hasPrefix("!/")) {
            parts.fragment = nil
        }
        return parts.string ?? address
    }
}
