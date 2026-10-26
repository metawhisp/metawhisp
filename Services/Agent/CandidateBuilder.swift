import Foundation

/// What the builder needs besides the page: the current subgoal's terms (in
/// both languages the planner wrote), and the option this errand chose in
/// each select on this page.
struct CandidateContext: Equatable {
    let subgoalTerms: [String]
    /// The option this errand chose in each select on the current page and
    /// saw held, by the select's fingerprint: what the loop did itself, beside
    /// the option the select reports as its value (owner decision 4).
    var chosenOptions: [String: String] = [:]
    /// What the actions the user said No to on this page, or let the
    /// question lapse on, do: never offered again (ITER-076 I-05).
    var refused: Set<AgentAction.Effect> = []
    /// The tab has an entry of its own history to go back to (ITER-076 I-10).
    var canGoBack = false
}

/// One option in a decision request: a complete action and its id.
struct Candidate: Equatable {
    let id: String
    let action: AgentAction
}

/// The candidates for one question: the page's actions, at most
/// `CandidateBuilder.maxActions`, then the page-level operations.
struct CandidateSet: Equatable {
    let candidates: [Candidate]
}

/// Turns what the observer saw into complete candidate actions (§6.2): the
/// operation, the element and every parameter come from the page, so a model
/// only ever picks one and never invents a parameter.
enum CandidateBuilder {
    /// Jev sees the whole visible page (owner decision 4, 2026-09-29; ITER-076
    /// stage 3, № 65): up to this many of its actions — what references
    /// working with Jev offer (a table of up to 240 visible controls).
    static let maxActions = 240

    /// Offered on every page, after the page's own actions — BACK only where
    /// the tab has an entry of its own history to go back to (ITER-076 I-10).
    static let pageLevelOperations: [AgentOperation] = [.scroll, .wait, .back, .done, .stuck]

    /// A select's first options — best match first — come with it; the rest
    /// wait behind every other action on the page.
    static let maxOptionsPerSelect = 5

    private static let clickRoles: Set<String> = ["button", "menuitem", "menuitemcheckbox", "menuitemradio", "tab",
                                                  "option", "checkbox", "radio", "switch", "treeitem"]
    private static let typeRoles: Set<String> = ["textbox", "searchbox", "spinbutton"]
    private static let selectRoles: Set<String> = ["combobox", "listbox"]
    /// Every role the builder offers an action for.
    static let actionableRoles: Set<String> = clickRoles.union(typeRoles).union(selectRoles).union(["link"])

    /// A field the agent types in: a text box, a search box, a number field,
    /// or a combobox that is a text field — an input, or one the observer
    /// reads as typed into, as a textarea is (ITER-076 I-08; brain: a search
    /// engine's own box is drawn so). D4 counts a search form's fields by it.
    static func takesTyping(_ element: ObservedElement) -> Bool {
        typeRoles.contains(element.role)
            || (element.role == "combobox" && element.options == nil
                && (element.inputType != nil || element.opens == false))
    }

    /// Every action of the page, in page order, then the page-level
    /// operations (ITER-076 stage 3, № 65, 68): a select's first options —
    /// best match first — with it, its others after every other action. A
    /// page with more than `maxActions` keeps the ones on screen first, as
    /// the observer keeps its controls (ITER-076 I-10, critic 17): what
    /// scrolling brings on screen is offered; then the ones the sub-goal
    /// names, most of its terms first — an option deep in a long list stays
    /// within reach (Codex review 1 of I-08, P2-4); then the rest, each part
    /// in page order. No «more», and no planned search.
    static func build(page: ObservedPage, context: CandidateContext) -> CandidateSet {
        let terms = Set(context.subgoalTerms.flatMap { tokens(in: $0) })
        var first: [(action: AgentAction, onScreen: Bool)] = []
        var waiting: [(action: AgentAction, onScreen: Bool)] = []
        var offeredFingerprints = Set<String>()
        for element in page.elements {
            let identity = page.identity(of: element)
            if identity.total > 1 {
                // Twins are offered only when they are one destination, and
                // then only once (§6.3).
                guard page.element(matching: identity) != nil,
                      !offeredFingerprints.contains(identity.fingerprint) else { continue }
            }
            offeredFingerprints.insert(identity.fingerprint)
            // An option of a made-up dropdown this errand chose there and saw
            // held is not offered again, as a native select's is not (ITER-076
            // I-08).
            if let list = element.listOf.flatMap({ index in page.elements.first { $0.index == index } }),
               context.chosenOptions[list.fingerprint] == element.name { continue }
            let chosen = context.chosenOptions[element.fingerprint]
            let offered = actions(for: element, on: page.address(of: element), terms: terms, chosen: chosen).filter {
                !context.refused.contains($0.effect)
            }
            for (position, action) in offered.enumerated() {
                let waits = action.operation == .select && position >= maxOptionsPerSelect
                if waits { waiting.append((action, element.inViewport)) } else { first.append((action, element.inViewport)) }
            }
        }
        let all = first + waiting
        var kept = Array(all.indices)
        if all.count > maxActions {
            let named = all.map { overlap($0.action.payload ?? $0.action.target?.name ?? "", terms) }
            let keptFirst = all.indices.sorted {
                (all[$0].onScreen ? 0 : 1, -named[$0], $0) < (all[$1].onScreen ? 0 : 1, -named[$1], $1)
            }
            let chosen = Set(keptFirst.prefix(maxActions))
            kept = all.indices.filter(chosen.contains)
        }
        let pageLevel = pageLevelOperations.filter { $0 != .back || context.canGoBack }.map {
            AgentAction(operation: $0, target: nil, destination: nil, payload: nil, isPlannedSearch: false)
        }
        let ordered = kept.map { all[$0].action } + pageLevel
        return CandidateSet(candidates: ordered.enumerated().map { Candidate(id: "c\($0.offset + 1)", action: $0.element) })
    }

    // MARK: - Private

    /// The actions one element offers. An element whose activation leads to a
    /// non-web address — its own, the link around it, or its form's
    /// destination — offers none, whatever role the page gives it: it is
    /// neither opened nor clicked (§6.2). A "button" inside a `mailto:` link,
    /// or in a form that sends to one, still leaves the browser. Nor does an
    /// address at the report's length limit, which may have been cut: where
    /// it goes and the words at its end are not known whole. `chosen` is the
    /// option this errand chose in it on this page, for a select; `address`,
    /// where its own document is.
    private static func actions(for element: ObservedElement, on address: String, terms: Set<String>,
                                chosen: String?) -> [AgentAction] {
        func action(_ operation: AgentOperation, destination: String? = nil, payload: String? = nil) -> AgentAction {
            AgentAction(operation: operation, target: element, destination: destination, payload: payload,
                        isPlannedSearch: false)
        }
        // A control with no name offers nothing: no check can judge what it
        // does, and nobody could say yes to it (ITER-076 2.3). Spaces,
        // invisible characters and blank-looking fillers alone are no name.
        guard element.name.unicodeScalars.contains(where: { !isBlank($0) }) else { return [] }
        let destinations = [element.href, element.formAction, element.listForm?.action].compactMap { $0 }
        guard destinations.allSatisfy({ $0.count < ObserverScript.maxURLLength
            && (URL(string: $0).map(DiaScript.isOpenable) ?? false) }) else { return [] }
        // A file field is never offered: a file from the user's disk is
        // theirs to pick (ITER-076 I-08).
        guard element.inputType != "file" else { return [] }
        let role = element.role
        // Only role "link" is opened by its own address; every other role is
        // clicked and runs the page's handlers — and so is a link to a place
        // on its own page, as owner default 3.3 clicks any other control's:
        // its page's script shows the place (2026-10-07). The observer ties
        // the form around an element to it by the same rule (ITER-076 2.1).
        if role == "link" {
            guard let href = element.href else { return [] }
            if isPlace(href, onPageAt: address) { return [action(.click)] }
            return [action(.open, destination: href)]
        }
        // Owner default 3.3 (ITER-076 stage 3, № 100): any other control that
        // is, or sits in, an anchor with a real web address opens by going to
        // it — no form is sent and no script runs — but for one whose address
        // is a place on its own page, a tab's panel, which its script shows.
        if clickRoles.contains(role), let href = element.href, !isPlace(href, onPageAt: address) {
            return [action(.open, destination: href)]
        }
        if clickRoles.contains(role) { return [action(.click)] }
        // A made-up dropdown, or a field that takes no typing, is opened by a
        // click; its options or its picker come on the next look (ITER-076
        // I-08).
        if element.opens == true { return [action(.click)] }
        if typeRoles.contains(role) { return [action(.type)] }
        if selectRoles.contains(role) {
            // A combobox that is a text field is typed into, and its suggestion
            // then clicked (ITER-076 I-08).
            if takesTyping(element) { return [action(.type)] }
            // Every option but the one the select shows — its reported value
            // (owner decision 4), as jev-ultrafast offers only the others — and
            // the one this errand chose here and saw held: the ones that match
            // the subgoal first, then the list's own order.
            let others = (element.options ?? []).filter { $0 != chosen && $0 != element.value }.enumerated()
            let ordered = others.sorted { first, second in
                let (a, b) = (overlap(first.element, terms), overlap(second.element, terms))
                return a != b ? a > b : first.offset < second.offset
            }
            return ordered.map { action(.select, payload: $0.element) }
        }
        return []
    }

    /// Whether `href` is a place on the page at `address`: that page's own
    /// address with a fragment.
    private static func isPlace(_ href: String, onPageAt address: String) -> Bool {
        guard var place = URLComponents(string: href), place.fragment != nil,
              var page = URLComponents(string: address) else { return false }
        place.fragment = nil
        page.fragment = nil
        return place.string == page.string
    }

    /// How many of the subgoal's terms the text contains.
    private static func overlap(_ text: String, _ terms: Set<String>) -> Int {
        Set(tokens(in: text)).intersection(terms).count
    }

    /// A text's words, and its numbers, whole: "Size 250" is "size" and
    /// "250", never "25" — so the option a subgoal names by its number ranks
    /// first in a long list (Codex review 1 of I-08, P2-4).
    private static func tokens(in text: String) -> [String] {
        SafetyGuard.words(in: text) + text.split { !$0.isNumber }.map(String.init)
    }

    /// A character that shows nothing a person could read: a space, a format
    /// or default-ignorable character (a zero-width space, a Hangul filler),
    /// or the blank Braille pattern.
    private static func isBlank(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isWhitespace || scalar.properties.generalCategory == .format
            || scalar.properties.isDefaultIgnorableCodePoint || scalar.value == 0x2800
    }
}
