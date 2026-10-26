import Foundation

/// What an action script reports (ITER-074 §6.3, §6.5).
struct ActionOutcome: Decodable, Equatable {
    enum Kind: String, Decodable {
        /// The action was sent to the page; its postcondition decides whether
        /// it took (§6.5).
        case done
        /// The element is gone or changed: decide again, nothing happened.
        case gone
        /// Twins that are not one destination: nothing happened.
        case ambiguous
        /// The element cannot take this action by script.
        case unsupported
        /// The control could now send a secret field, or the target turned
        /// into one: the user's part, and nothing happened (ITER-076 2.2, S3;
        /// owner decision 4).
        case wall
        /// `holds`: the field shows what was written, or it does not. The
        /// value itself never leaves the page (ITER-076 2.3).
        case held, differs
        /// `aim`: the element is on screen and nothing covers its centre,
        /// at `x`, `y` — where a trusted click goes (ITER-076 3.1).
        case aim
        /// `aim`: something covers the element's centre; nothing is clicked.
        case covered
        /// `focused`: the field the click was for holds the focus.
        case ready
        /// The step would send a form that needs a file from the user's disk:
        /// the user's part, and nothing happened (Codex review 1 of I-08,
        /// P2-2).
        case file
        /// `found`: the element is found again with every check its act
        /// makes, and nothing was done; `frames` says how many frames its
        /// document holds (ITER-076 I-09, round 5; Claude review c10, #14).
        case found
        /// A form's Send (ITER-076 stage 7, № 93): a field the Yes was bound
        /// to no longer holds what it held — or is gone — so the Yes is void
        /// and nothing was done; or the press's own check found that as it
        /// came, or found it on another control, and the page heard none of
        /// it (review round 1, C3).
        case changed
        /// `arm`: the press of a form's Send carries its check (review round
        /// 1, C3).
        case armed
    }

    let outcome: Kind
    /// For a scroll: whether the viewport moved.
    let moved: Bool?
    /// For `aim`: the element's centre, in the viewport's CSS pixels.
    let x: Double?
    let y: Double?
    /// For `aim` and `found`: how many frames a person can see the lookup
    /// found in its document (`frameOwners.shown`), so the look at the act reads what the
    /// act sees (review round 4, decision 12; Claude review c9 of I-09, #16;
    /// round 5, Claude review c10, #14). One that does not say is no aim.
    var frames: Int? = nil
    /// For `focused` (ITER-076 I-07): the field is a native date or time
    /// input, which takes its value through its setter, never keystrokes.
    var native: Bool? = nil
    /// For `landed`: the field lists suggestions, and they are waited for.
    var suggests: Bool? = nil
    /// For `wall` (2026-10-08): the check the hands met — "secret", the
    /// control could send a secret field; "turnedSecret", its target is one
    /// now; "foreignFrame", another site's sign-in or card form holds it;
    /// "paymentForm", a card that came since the look — on the log, so a
    /// hand-over names its cause.
    var why: String? = nil

    /// An action script answers in a few bytes; anything bigger is a page
    /// tampering with it, and is refused unread.
    static let maxReportBytes = 4_096

    static func decode(_ json: String) throws -> ActionOutcome {
        guard json.utf8.count <= maxReportBytes else { throw ObservationError.tooLarge }
        return try JSONDecoder().decode(ActionOutcome.self, from: Data(json.utf8))
    }
}

/// The agent's hands inside a page (ITER-074 §6.3, §6.5): one script per
/// action, built by the app from the candidate — no model writes or edits
/// them. An action on an element finds that element again with the
/// observer's own walk, in the same script run as the action, so nothing can
/// change between the look-up and the act. An element that is gone or
/// changed, or one of twins that are not one destination, is not touched,
/// and neither is a control that could now send a secret field or a target
/// that turned into one (ITER-076 2.2, S3; owner decision 4) — except a link
/// opened by its own address, which only leaves the page.
enum ActionScript {
    /// What the checks — and, for an irreversible action, the user — saw
    /// (§7.1). Every element action and every planned search is bound to it
    /// in the same script as the act: the page is still that page, and the
    /// element still shows the same words and submit label. Without an
    /// approval, the action is bound to what the checks saw on `page`.
    struct Approval: Equatable {
        var pageURL: String
        let text: String
        let formSubmitLabel: String?
        /// Whether it sends its form, and whether that form grants access:
        /// what the risk checks read (ITER-076 2.2).
        let submits: Bool?
        let formGrants: Bool?
        /// The payment evidence the checks saw: whether the page takes a
        /// payment — asks card details (owner decision of 2026-10-19). A card
        /// that is new at the act makes a step that commits the user's part, a
        /// Yes given or not (review of I-02, N3-P1-5). Left out, none was
        /// seen: any at the act stops it.
        var paymentForm: Bool = false
        /// For an option of a made-up dropdown: that dropdown's form as the
        /// checks saw it (Codex review 1 of I-08, P1-3).
        var listForm: ObservedElement.ListForm? = nil
        /// A form's Send (ITER-076 stage 7, № 93): every field of the form,
        /// each with a digest of exactly what it held when the user said Yes.
        /// The act reads them all again in the same script, and does nothing
        /// when any field changed: a Yes is bound to the values it showed.
        var formValues: [BoundValue]? = nil
    }

    /// A field a form's Send is bound to (ITER-076 stage 7, № 93): who it is
    /// on the page — its fingerprint's fields and which of its twins — and
    /// what it held: a digest of exactly its value (`ObservedElement.valueKey`),
    /// never the value, and whether it was on, for a box.
    struct BoundValue: Encodable, Equatable {
        let role: String
        let name: String
        let href: String?
        let heading: String?
        let context: String?
        let formAction: String?
        let formMethod: String?
        let occurrence: Int
        let total: Int
        let valueKey: String?
        let checked: Bool?

        /// `field` as `page` shows it now, bound to what it holds; nil for a
        /// control that holds nothing — a button.
        init?(_ field: ObservedElement, on page: ObservedPage) {
            guard field.valueKey != nil || field.checked != nil else { return nil }
            let identity = page.identity(of: field)
            role = field.role
            name = field.name
            href = field.href
            heading = field.heading
            context = field.context
            formAction = field.formAction
            formMethod = field.formMethod
            occurrence = identity.occurrence
            total = identity.total
            valueKey = field.valueKey
            checked = field.checked
        }
    }

    /// The script for `action`, chosen from candidates built on `page`. Nil
    /// for an operation with nothing to run in the page (wait, more, done,
    /// stuck), for back — which goes through the tab's own history
    /// (`BrowserBridge.goBack`, ITER-076 I-10) — and for an action that is
    /// not whole: a click without a target, a type or select without its
    /// text, an open whose address is not a web address, not the link's own,
    /// or at the report's length limit — where it may have been cut.
    /// `framesKnown`: how many frames the act's document held when the
    /// checks last looked at it (`found`): an act that commits finds more
    /// there at the act gone — a frame no check read — and the next step
    /// looks again (ITER-076 I-09, round 5; Claude review c10, #14).
    static func source(for action: AgentAction, on page: ObservedPage, approval: Approval? = nil,
                       framesKnown: Int? = nil) -> String? {
        switch action.operation {
        case .wait, .more, .done, .stuck, .back:
            return nil
        case .scroll:
            return scroll
        case .open:
            guard let destination = action.destination, let url = URL(string: destination),
                  DiaScript.isOpenable(url) else { return nil }
            guard let target = action.target else {
                return navigate(to: destination, approvedOn: approval?.pageURL ?? page.liveAddress)
            }
            guard target.href == destination, destination.count < ObserverScript.maxURLLength else { return nil }
            // A link in a frame is opened by its own address in the tab, as
            // a planned search is: bound to the page (ITER-076 I-09).
            if target.frame != nil {
                return navigate(to: destination, approvedOn: approval?.pageURL ?? page.liveAddress)
            }
            return onElement(target, on: page, operation: .open, payload: nil, destination: destination,
                             binding: approval ?? binding(of: target, on: page), commits: SafetyGuard.commits(action),
                             framesKnown: framesKnown)
        case .click:
            guard let target = action.target else { return nil }
            return onElement(target, on: page, operation: .click, payload: nil, destination: nil,
                             binding: approval ?? binding(of: target, on: page), commits: SafetyGuard.commits(action),
                             framesKnown: framesKnown)
        case .type, .select:
            guard let target = action.target, let payload = action.payload else { return nil }
            return onElement(target, on: page, operation: action.operation, payload: payload, destination: nil,
                             binding: approval ?? binding(of: target, on: page), commits: commits(action, approval),
                             framesKnown: framesKnown)
        }
    }

    /// Whether the hands read `action` as an act that commits: one that does by itself (`SafetyGuard.commits`), or
    /// one the user's Yes binds to the form's values — a send, as a choice whose change the page sends is once it is
    /// asked about as one (2026-10-21). A press bound so commits by itself.
    static func commits(_ action: AgentAction, _ approval: Approval?) -> Bool {
        SafetyGuard.commits(action) || approval?.formValues != nil
    }

    /// The lookup of an act sent by script, made alone before it, in its
    /// control's document (ITER-076 I-09, round 5; Claude review c10, #14):
    /// the control found again with every check its act makes, and how many
    /// frames that document holds — what the aim says of a press, so the
    /// look at the act reads a frame the page brought since the step's look
    /// for a select, an open and every act that commits. Nothing is done. An
    /// open's own exemptions are a link's, which those checks never stop: a
    /// link touches no secret and is no frame's wall. Nil for an act that
    /// commits nothing, has no control, or has no script. An open's Yes is
    /// bound to the tab it runs in; its lookup, to its link's own document
    /// (Claude review c11, #10).
    static func found(for action: AgentAction, on page: ObservedPage, approval: Approval? = nil) -> String? {
        guard commits(action, approval), let target = action.target,
              source(for: action, on: page, approval: approval) != nil else { return nil }
        var bound = approval ?? binding(of: target, on: page)
        if action.operation == .open { bound.pageURL = page.address(of: target) }
        return onElement(target, on: page, operation: "found", payload: nil, destination: nil,
                         binding: bound, commits: true)
    }

    /// Whether a typed or selected field shows the action's text now, read and
    /// compared in the page, so the text never leaves it (ITER-076 2.3). The
    /// field is found again by its identity — its words, place and form, the
    /// form's destination included — never on a page that now asks for a
    /// login or a payment, and only on the origin it was acted on. A sort
    /// select that rewrites the page's address, or sends its GET form, is
    /// found again; one whose change rewrites its own row's words, or sends a
    /// POST form with no action of its own to a page at another address, is
    /// not.
    static func holds(_ action: AgentAction, on page: ObservedPage) -> String? {
        guard action.operation == .type || action.operation == .select, let target = action.target,
              let payload = action.payload else { return nil }
        return onElement(target, on: page, operation: "holds", payload: payload, destination: nil,
                         binding: binding(of: target, on: page))
    }

    /// Where a trusted click on `action`'s element goes (ITER-076 3.1): the
    /// element is found again with every check an act makes — the bound page,
    /// the words the checks saw, no secret it could send — and must be
    /// enabled, and writable for a type; it is brought on screen and
    /// hit-tested at its centre. Nothing is clicked here; a bridge with
    /// trusted input clicks at the answer. Nil for anything but a click or a
    /// type with its text.
    static func aim(for action: AgentAction, on page: ObservedPage, approval: Approval? = nil) -> String? {
        guard let target = action.target else { return nil }
        let operation: String
        switch action.operation {
        case .click: operation = "aim"
        case .type where action.payload != nil: operation = "aimToWrite"
        default: return nil
        }
        return onElement(target, on: page, operation: operation, payload: nil, destination: nil,
                         binding: approval ?? binding(of: target, on: page), commits: SafetyGuard.commits(action))
    }

    /// Where the text of a type action goes, once the click on its field is
    /// in (ITER-076 I-07), ported from a reference browser agent's `_fill`
    /// and `_HANDED_FOCUS_JS` (`page.py` 125-150, 753-846, MIT): the field the
    /// click was for, or — where the page swapped it or opened an editor over
    /// it — the editable field that took the focus at the same point, vetted
    /// as the observer vets every field. A secret field the page's handlers
    /// brought makes the page the user's part (ITER-076 2.2, S3). The field
    /// is focused and answers `ready`; a native date or time input answers
    /// `ready` with `native`. Nothing is typed until this answers. `again`,
    /// after text that went nowhere: only another field that took the focus
    /// since answers `ready`, the one typed into `differs`.
    static func focused(for action: AgentAction, on page: ObservedPage, approval: Approval? = nil,
                        again: Bool = false) -> String? {
        guard action.operation == .type, let target = action.target, action.payload != nil else { return nil }
        return onElement(target, on: page, operation: again ? "focusedAgain" : "focused", payload: nil,
                         destination: nil, binding: approval ?? binding(of: target, on: page))
    }

    /// A native date, time or colour input's value, in the input's own
    /// format, set through the value setter with the events its own picker
    /// sends, and read back (ITER-076 I-07, the reference's
    /// `_fill_native_date`, `page.py` 864-886; colour added 2026-10-19).
    static func setDate(for action: AgentAction, on page: ObservedPage, approval: Approval? = nil) -> String? {
        guard action.operation == .type, let target = action.target, let payload = action.payload else { return nil }
        return onElement(target, on: page, operation: "setDate", payload: payload, destination: nil,
                         binding: approval ?? binding(of: target, on: page))
    }

    /// The text written into its field in one renderer task with the check
    /// of that field (Codex review of I-07, round 2, P2-1), ported from a
    /// reference browser agent's one-task insertion (`page.py` 798-807, MIT):
    /// still the field typed into, connected, on the bound page, holding the
    /// focus in a focused document, and vetted as the observer vets every
    /// field — one turned secret, or whose form could now send a secret field,
    /// is a wall — then its text selected and the text inserted as the page's
    /// own editing inserts it: trusted input, and no page code between the
    /// check and the text. What the field's suggestion list shows is noted
    /// first, so only new options end their wait (P2-3). `wall`, `gone`, or
    /// `done`/`differs` as the insertion went.
    static func typeText(for action: AgentAction, on page: ObservedPage, approval: Approval? = nil) -> String? {
        guard action.operation == .type, let target = action.target, let payload = action.payload else { return nil }
        return onElement(target, on: page, operation: "typeText", payload: payload, destination: nil,
                         binding: approval ?? binding(of: target, on: page))
    }

    /// Whether the text typed is in the field it went to — or in the field
    /// that took the focus at its point meanwhile — `held` or `differs`, and
    /// whether that field lists suggestions (ITER-076 I-07, the reference's
    /// `_landed_js`, `page.py` 848-862). Compared in the page: the text never
    /// leaves it.
    static func landed(_ action: AgentAction, on page: ObservedPage) -> String? {
        guard action.operation == .type, let target = action.target, let payload = action.payload else { return nil }
        return onElement(target, on: page, operation: "landed", payload: payload, destination: nil,
                         binding: binding(of: target, on: page))
    }

    /// Waits, at most 1.2 s, for the suggestions the field typed into asks
    /// for to be listed; at once for a field that asks for none (ITER-076
    /// I-07, the reference's `_await_suggestions`, `page.py` 888-921).
    static func suggestions(_ action: AgentAction, on page: ObservedPage) -> String? {
        guard action.operation == .type, let target = action.target else { return nil }
        return onElement(target, on: page, operation: "suggestions", payload: nil, destination: nil,
                         binding: binding(of: target, on: page))
    }

    /// The check a person's press of a form's Send carries (ITER-076 stage 7,
    /// review round 1, C3), armed right before the press: from the aim to
    /// the press the page may act on its own — a timer, or its own handler
    /// of the press — so each event of the press is checked as it comes,
    /// before the page hears it: the element found again with every check
    /// its act makes, every field the Yes is bound to holding what it held,
    /// and the press on the element or one of its labels. One that fails
    /// voids the press: it, every event of the press after it, and a form it
    /// would send never reach the page. Nil for anything but a click bound to
    /// a form's values.
    static func arm(for action: AgentAction, on page: ObservedPage, approval: Approval) -> String? {
        guard action.operation == .click, let target = action.target, approval.formValues != nil else { return nil }
        return onElement(target, on: page, operation: "arm", payload: nil, destination: nil, binding: approval,
                         commits: SafetyGuard.commits(action))
    }

    /// What a press armed with its check came to, read once it went out:
    /// `changed` when the check voided it, else `done` — on a page the press
    /// left too; the check let go either way.
    static func pressed(_ action: AgentAction, on page: ObservedPage) -> String? {
        guard action.operation == .click, let target = action.target else { return nil }
        return onElement(target, on: page, operation: "pressed", payload: nil, destination: nil,
                         binding: binding(of: target, on: page))
    }

    /// Lets go of the field that holds the focus (ITER-076 stage 7, review
    /// round 1, C2): its page hears it left — a `change` its typing owes is
    /// sent then — as a person's click elsewhere would tell it.
    static let letGo = #"""
    (() => {
      let active = document.activeElement;
      for (let hops = 0; active && active.shadowRoot && active.shadowRoot.activeElement && hops < 10; hops++) {
        active = active.shadowRoot.activeElement;
      }
      if (active && active !== document.body && typeof active.blur === 'function') active.blur();
      return JSON.stringify({ outcome: 'done' });
    })()
    """#

    /// What the checks saw on `page` for `target`: its own document — the
    /// page's, or its frame's (ITER-076 I-09).
    private static func binding(of target: ObservedElement, on page: ObservedPage) -> Approval {
        Approval(pageURL: page.address(of: target), text: target.text, formSubmitLabel: target.formSubmitLabel,
                 submits: target.submits, formGrants: target.formGrants,
                 paymentForm: page.flags(of: target).paymentForm, listForm: target.listForm)
    }

    // MARK: - Private

    /// The element as the page reported it — exactly the fields its
    /// fingerprint is made of — plus which of its twins it is.
    private struct Expected: Encodable {
        let role: String
        let name: String
        let href: String?
        let heading: String?
        let context: String?
        let formAction: String?
        let formMethod: String?
        let occurrence: Int
        let total: Int
        let operation: String
        let payload: String?
        let destination: String?
        let boundPageURL: String
        /// The origin of `boundPageURL`, worked out here: the page's own `URL`
        /// may lie, and the holds check stays on this origin.
        let boundOrigin: String?
        let boundText: String
        let boundSubmitLabel: String?
        let boundSubmits: Bool?
        let boundFormGrants: Bool?
        /// For a select, and the check that its option held: where the option
        /// stood when it was observed, and its key — a digest of its exact
        /// words and value (review of A3d, round 2, P2-2; review of I-02,
        /// N3-P2-1). -1 when no one option was listed with the action's words.
        let optionIndex: Int?
        let optionKey: String?
        /// The target's private key in the page, which a redrawn role or name
        /// does not change (N3-P2-2).
        let key: Int?
        /// Payment evidence the checks saw, and whether the act commits: new
        /// evidence at a commit is a wall (N3-P1-5).
        let boundPaymentForm: Bool
        let commits: Bool
        /// How many frames the act's document held when the checks last
        /// looked: one that commits finds more there gone (`source`).
        let framesKnown: Int?
        /// For an option of a made-up dropdown: who that dropdown is, and the
        /// form it sends as the checks saw it (Codex review 1 of I-08, P1-2,
        /// P1-3).
        let listOwner: String?
        let boundListForm: ObservedElement.ListForm?
        /// Whether the target is in a frame of another site than the page's:
        /// a sign-in or a card form in it now makes the target the user's
        /// part, as at the look (Claude review c7 of I-09, #5).
        let foreignFrame: Bool
        /// A form's Send: the fields its Yes is bound to (ITER-076 stage 7).
        let boundValues: [BoundValue]?
    }

    private static func onElement(_ target: ObservedElement, on page: ObservedPage, operation: AgentOperation,
                                  payload: String?, destination: String?, binding: Approval, commits: Bool,
                                  framesKnown: Int? = nil) -> String? {
        onElement(target, on: page, operation: operation.rawValue, payload: payload, destination: destination,
                  binding: binding, commits: commits, framesKnown: framesKnown)
    }

    private static func onElement(_ target: ObservedElement, on page: ObservedPage, operation: String,
                                  payload: String?, destination: String?, binding: Approval,
                                  commits: Bool = false, framesKnown: Int? = nil) -> String? {
        let identity = page.identity(of: target)
        let option = option(of: target, payload: payload, selecting: operation == AgentOperation.select.rawValue
            || (operation == "holds" && target.options != nil))
        let expected = Expected(role: target.role, name: target.name, href: target.href, heading: target.heading,
                                context: target.context, formAction: target.formAction,
                                formMethod: target.formMethod, occurrence: identity.occurrence,
                                total: identity.total, operation: operation, payload: payload,
                                destination: destination, boundPageURL: binding.pageURL,
                                boundOrigin: Self.origin(of: binding.pageURL),
                                boundText: binding.text, boundSubmitLabel: binding.formSubmitLabel,
                                boundSubmits: binding.submits, boundFormGrants: binding.formGrants,
                                optionIndex: option?.index, optionKey: option?.key, key: target.key,
                                boundPaymentForm: binding.paymentForm,
                                commits: commits, framesKnown: framesKnown,
                                listOwner: target.listOwner, boundListForm: binding.listForm,
                                foreignFrame: page.inFrameOfAnotherSite(target), boundValues: binding.formValues)
        guard let data = try? JSONEncoder().encode(expected), let json = String(data: data, encoding: .utf8) else {
            return nil
        }
        return "(() => {\n" + ObserverScript.walk + "const expected = " + json + ";\n" + elementAction + "\n})()"
    }

    /// Where the option a select action chooses stood when the page was
    /// observed, and its key: the one option listed with the action's words.
    /// Index -1 when none or more than one was.
    private static func option(of target: ObservedElement, payload: String?,
                               selecting: Bool) -> (index: Int, key: String?)? {
        guard selecting else { return nil }
        let options = target.options ?? []
        let places = options.indices.filter { options[$0] == payload }
        guard places.count == 1, let place = places.first else { return (-1, nil) }
        let keys = target.optionKeys ?? []
        return (place, keys.indices.contains(place) ? keys[place] : nil)
    }

    /// An address's origin as a browser writes `location.origin`: the scheme
    /// and host in lower case, and the port only when it is not the scheme's
    /// default. Nil when the address has no host.
    static func origin(of address: String) -> String? {
        // Only the scheme and the authority are read: a path or query that a
        // strict parser refuses cannot lose the origin. `encodedHost` keeps
        // an international host in punycode, as the browser writes it.
        guard let schemeEnd = address.range(of: "://") else { return nil }
        let head = String(address[..<schemeEnd.upperBound])
        let authority = String(address[schemeEnd.upperBound...].prefix { !"/?#".contains($0) })
        guard let parts = URLComponents(string: head + authority),
              let scheme = parts.scheme?.lowercased(),
              let host = parts.encodedHost?.lowercased(), !host.isEmpty else { return nil }
        let defaultPort = ["http": 80, "https": 443][scheme]
        let port = parts.port.flatMap { $0 == defaultPort ? nil : $0 }
        let shownHost = host.contains(":") && !host.hasPrefix("[") ? "[" + host + "]" : host
        return scheme + "://" + shownHost + (port.map { ":\($0)" } ?? "")
    }

    /// Opens `destination`, only on the page it was chosen on — for an
    /// approved open, the one the Yes was given on.
    private static func navigate(to destination: String, approvedOn pageURL: String) -> String? {
        guard let data = try? JSONEncoder().encode([destination, pageURL]),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return "(() => {\nconst [destination, approvedOn] = " + json + ";\n"
            + "if (String(location.href).slice(0, "
            + String(ObserverScript.maxURLLength) + ") !== approvedOn) return JSON.stringify({ outcome: 'gone' });\n"
            + "location.assign(destination);\nreturn JSON.stringify({ outcome: 'done' });\n})()"
    }

    /// Finds the element again the way `ObservedPage.element(matching:)`
    /// does — the same fields, the same number of twins, twins only when
    /// they are one destination — and acts on it.
    private static let elementAction = #"""
    // The check a wall met, said with it (2026-10-08): a hand-over names its
    // cause on the log.
    let wallWhy = null;
    const answer = (outcome) => JSON.stringify(outcome === 'wall' && wallWhy ? { outcome, why: wallWhy } : { outcome });
    const wall = (why) => {
      wallWhy = why;
      return { outcome: 'wall' };
    };
    // How many frames the latest lookup found in this document: an aim says
    // it, and the look at the act reads them (review round 4, decision 12).
    let framesSeen = null;
    const locate = () => {
      const { report, nodes, withheld, choiceShown } = observe();
      framesSeen = report.frameOwners.shown;
      // An act is bound to the page it was chosen on. The holds check only
      // reads: it stays on that page's origin and follows the field wherever
      // the page's own address went there.
      const reads = expected.operation === 'holds';
      // A document with no address of its own — a frame the page wrote in
      // itself — is read only where it was acted on (ITER-076 I-09).
      const sameOrigin = typeof expected.boundOrigin === 'string' ? location.origin === expected.boundOrigin
        : String(location.href).slice(0, MAX_URL) === expected.boundPageURL;
      if (reads ? !sameOrigin : String(location.href).slice(0, MAX_URL) !== expected.boundPageURL) {
        return { outcome: 'gone' };
      }
      // An option of a made-up dropdown is that dropdown's: another one's is
      // another option (Codex review 1 of I-08, P1-2).
      const fields = ['role', 'name', 'href', 'heading', 'context', 'formAction', 'formMethod', 'listOwner'];
      // The form an option's dropdown sends, as the checks saw it (P1-3).
      const sameListForm = (form) => ['action', 'method', 'submitLabel', 'grants'].every((field) =>
        ((form ?? {})[field] ?? null) === ((expected.boundListForm ?? {})[field] ?? null));
      // An act needs the words the checks saw; a read needs only the field.
      const stillBound = (element) => reads || (element.text === expected.boundText &&
        (element.formSubmitLabel ?? null) === (expected.boundSubmitLabel ?? null) &&
        (element.submits ?? null) === (expected.boundSubmits ?? null) &&
        (element.formGrants ?? null) === (expected.boundFormGrants ?? null) &&
        sameListForm(element.listForm));
      const matches = [];
      report.elements.forEach((element, index) => {
        if (fields.every((field) => (element[field] ?? null) === (expected[field] ?? null)) && stillBound(element)) {
          matches.push(index);
        }
      });
      // A field the page turned into a secret field since it was chosen —
      // "show password" off, a card number typed in, a search box become a
      // password box — is the user's part, not a target that is gone (review
      // of A3, round 1). Turning secret may change its role, or its name, so
      // it is found by the rest of what it was and one of those two (review
      // of A3d, round 2, P2-4).
      // First by its private key, which no redrawing changes (review of I-02,
      // N3-P2-2); a field drawn anew as a secret one, by what it still shares.
      const lasting = ['href', 'heading', 'context', 'formAction', 'formMethod'];
      const same = (element, field) => (element[field] ?? null) === (expected[field] ?? null);
      if (matches.length === 0 && !reads &&
          withheld.some((element) => (typeof expected.key === 'number' && element.key === expected.key) ||
            (lasting.every((field) => same(element, field)) && (same(element, 'role') || same(element, 'name'))))) {
        return wall('turnedSecret');
      }
      if (matches.length !== expected.total || expected.occurrence >= matches.length) return { outcome: 'gone' };
      const oneDestination = expected.role === 'link' && typeof expected.href === 'string' &&
        expected.href.length > 0 && expected.href.length < MAX_URL;
      if (matches.length > 1 && !oneDestination) return { outcome: 'ambiguous' };
      // A control that could now send a secret field — one that appeared
      // after the choice, in its form or beside a button with none — makes
      // the step the user's part (owner decision 4). Opening a link only
      // leaves the page.
      const chosen = report.elements[matches[expected.occurrence]];
      // A form that needs a file from the user's disk — a field turned
      // required since the choice — makes the step the user's part (Codex
      // review 1 of I-08, P2-2). It is named so before the secret and payment
      // walls, as the policy names it before the question: a form grown past
      // its scan meets both (Codex review 2 of I-08, P2-2).
      if (!reads && chosen.needsFile) return { outcome: 'file' };
      if (expected.operation !== 'open' && chosen.touchesSecret) {
        return wall('secret');
      }
      // A frame of another site that holds a sign-in or a card form now is
      // the user's part, every control in it but a link: the look's rule
      // (`ObservedPage.merging`), applied where the act is — to a sign-in
      // that came since the look too (Claude review c7 of I-09, #5).
      if (expected.operation !== 'open' && expected.foreignFrame && chosen.role !== 'link' &&
          (report.flags.loginForm || report.flags.paymentForm)) {
        return wall('foreignFrame');
      }
      // A card the checks never saw — a card field that came since the look —
      // makes a step that commits the user's part, a Yes given or not (review
      // of I-02, N3-P1-5; owner decision of 2026-10-19: a payment is a page
      // that asks card details, a total beside the act names none).
      if (expected.commits && report.flags.paymentForm && !expected.boundPaymentForm) {
        return wall('paymentForm');
      }
      // A frame the act's document holds that no check read — one the page
      // brought since the checks last looked at it — may show what the act
      // costs: an act that commits, the only one told how many there were,
      // is gone, and the next step looks again (ITER-076 I-09, round 5;
      // Claude review c10, #14).
      if (Number.isInteger(expected.framesKnown) && framesSeen > expected.framesKnown) {
        return { outcome: 'gone' };
      }
      // A form's Send (ITER-076 stage 7, № 93): every field its Yes is bound
      // to is found again — the same twins, the same place among them — and
      // holds exactly what it held when the user said Yes, by its digest, in
      // this same look; one changed, or gone, voids the Yes, and nothing is
      // done.
      if (!reads && Array.isArray(expected.boundValues)) {
        const bound = ['role', 'name', 'href', 'heading', 'context', 'formAction', 'formMethod'];
        for (const field of expected.boundValues) {
          const same = report.elements.filter((element) =>
            bound.every((name) => (element[name] ?? null) === (field[name] ?? null)));
          if (same.length !== field.total || field.occurrence >= same.length ||
              (same[field.occurrence].valueKey ?? null) !== (field.valueKey ?? null) ||
              (same[field.occurrence].checked ?? null) !== (field.checked ?? null)) {
            return { outcome: 'changed' };
          }
        }
      }
      return { node: nodes[matches[expected.occurrence]], choiceShown, nodes };
    };
    // The element found once more: null while it is still `node`, else what
    // the lookup says — a wall, a file the form now needs, twins — and gone
    // for another node. Every lookup made again keeps what it found (Codex
    // review 2 of I-08, P2-2).
    const foundAgain = (node) => {
      const again = locate();
      if (!again.node) return again.outcome;
      return again.node === node ? null : 'gone';
    };
    // The option a select action chose, as the observer listed it: at the
    // same place, with the same words, and exactly the same words and value
    // by its key (review of A3, round 1; review of A3d, round 2, P2-2; review
    // of I-02, N3-P2-1).
    const listedOption = (select) => {
      const at = expected.optionIndex;
      if (typeof expected.optionKey !== 'string' || !Number.isInteger(at) || at < 0 || at >= select.options.length) {
        return null;
      }
      const option = select.options[at];
      return collapse(option.text) === expected.payload && optionKeyOf(option) === expected.optionKey ? option : null;
    };
    // Whether a field holds the focus, asked until the browser's focus
    // controller says so — for a field in a frame it lags `activeElement` by
    // a tick or two — within a second: a reference browser agent's focus
    // check (`page.py` `_focus_script`, MIT). Every condition is read again
    // on the tick that succeeds; `onHeld` runs then.
    const focusHeld = (field, onHeld) => new Promise((resolve) => {
      const deadline = Date.now() + 1000;
      const check = () => {
        if (!field.isConnected || field.getRootNode().activeElement !== field) { resolve(answer('gone')); return; }
        if (field.ownerDocument.hasFocus()) {
          if (onHeld) onHeld();
          resolve(answer('ready'));
          return;
        }
        if (Date.now() > deadline) { resolve(answer('gone')); return; }
        setTimeout(check, 10);
      };
      check();
    });
    // Typing that lands (ITER-076 I-07), ported from a reference browser
    // agent's `page.py` (MIT). The hands' own record lives in the world the
    // scripts run in, for the document's life: the field a person's click
    // was for and the point it covered (the hand-off), the field typed into,
    // and where it stood.
    const hands = (() => {
      const key = '__metawhispHands';
      try {
        if (!window[key] || typeof window[key] !== 'object') {
          Object.defineProperty(window, key, { value: {}, configurable: true });
        }
        return window[key];
      } catch (error) {
        return {};
      }
    })();
    const textField = (a) => a.isContentEditable || a.tagName === 'TEXTAREA' || (a.tagName === 'INPUT' &&
      !['button', 'checkbox', 'color', 'file', 'hidden', 'image', 'radio', 'range', 'reset', 'submit'].includes(a.type));
    // Where focus went after the click on `e` (`_HANDED_FOCUS_JS`): `e`, or
    // an editable field in the same document that covers the point saved
    // before the click — a framework's hydrated copy, an editor opened over
    // it — as a person types where focus went. Decided once the page has
    // been quiet for 100 ms, within 600 ms, one rendered frame first; the
    // timer starts it anyway where frames are held.
    const handedFocus = (e) => new Promise((resolve) => {
      const was = hands.handoff;
      if (!e || !was) { resolve(null); return; }
      const decide = () => {
        if (e.ownerDocument !== was.doc || (was.doc.defaultView && was.doc.defaultView.document) !== was.doc) return null;
        const a = was.root.activeElement;
        const own = e.isConnected ? e : null;
        if (!a || a === e || e.contains(a)) return own;
        if (!textField(a) || !a.isConnected || a.disabled || a.readOnly || a.ownerDocument !== was.doc ||
            a.closest('[aria-disabled="true"],[aria-readonly="true"],[inert]') ||
            !a.checkVisibility({ checkOpacity: true, checkVisibilityCSS: true })) return own;
        const now = a.getBoundingClientRect();
        if (was.x < now.left || was.x > now.right || was.y < now.top || was.y > now.bottom) return own;
        return a;
      };
      const deadline = performance.now() + 600;
      const poll = () => {
        const choice = decide();
        if ((choice !== null && performance.now() - quiet.lastMutation >= 100) || performance.now() >= deadline) {
          resolve(choice);
        } else {
          setTimeout(poll, 20);
        }
      };
      let started = false;
      const start = () => { if (!started) { started = true; poll(); } };
      setTimeout(start, 600);
      if (was.doc.hidden) start(); else requestAnimationFrame(() => setTimeout(start, 0));
    });
    // A field focus went to is vetted as the observer vets every field: one
    // it withholds as secret, or one that could send a secret field, is the
    // user's part; one it does not report is not typed in. The field the
    // click was for is found again as an act finds it.
    const vetted = (field) => {
      if (field === hands.target) return foundAgain(field);
      const { report, nodes, withheldNodes } = observe();
      if (withheldNodes.includes(field)) return 'wall';
      const at = nodes.indexOf(field);
      if (at === -1) return 'gone';
      return report.elements[at].touchesSecret ? 'wall' : null;
    };
    // Fields whose value is set, not typed: a date, time or colour input takes
    // its value through its own setter, as its picker would commit it.
    const NATIVE_VALUE_TYPES = ['date', 'datetime-local', 'month', 'week', 'time', 'color'];
    const focusedField = (e, again) => handedFocus(e).then((choice) => {
      if (!choice || String(location.href).slice(0, MAX_URL) !== expected.boundPageURL) return answer('gone');
      if (again && choice === hands.field) return answer('differs');
      let verdict = vetted(choice);
      if (verdict) return answer(verdict);
      if (choice.tagName === 'INPUT' && NATIVE_VALUE_TYPES.includes(choice.type)) {
        hands.field = choice;
        return JSON.stringify({ outcome: 'ready', native: true });
      }
      choice.ownerDocument.defaultView.focus();
      choice.focus({ preventScroll: true });
      // Focus runs the page's own handlers: vetted again.
      verdict = vetted(choice);
      if (verdict) return answer(verdict);
      return focusHeld(choice, () => {
        const r = choice.getBoundingClientRect();
        hands.filled = { doc: choice.ownerDocument, x: r.x + r.width / 2, y: r.y + r.height / 2 };
        hands.field = choice;
      });
    });
    // `_fill_native_date`: the value its own picker would commit — into a
    // field vetted once more in this same task, right before the setter
    // (Codex review of I-07, P2-1).
    // Whether a field still takes text: one its own handlers turned read-only
    // as the person reached it takes none (Codex review 1 of I-08, P2-3).
    const writable = (e) => e.readOnly !== true && e.getAttribute('aria-readonly') !== 'true';
    const setDate = () => {
      const e = hands.field;
      if (!e || !e.isConnected || String(location.href).slice(0, MAX_URL) !== expected.boundPageURL) return answer('gone');
      const verdict = vetted(e);
      if (verdict) return answer(verdict);
      if (!writable(e)) return answer('gone');
      if (!(e instanceof HTMLInputElement) || !NATIVE_VALUE_TYPES.includes(e.type)) return answer('gone');
      const value = String(expected.payload);
      Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set.call(e, value);
      e.dispatchEvent(new Event('input', { bubbles: true }));
      e.dispatchEvent(new Event('change', { bubbles: true }));
      // A colour field writes its value in lower case, whatever case it was given in.
      const held = e.type === 'color' ? e.value.toLowerCase() === value.toLowerCase() : e.value === value;
      return answer(held ? 'held' : 'differs');
    };
    // The lists a field owns: every one it names, as the observer reads
    // them — in the field's own tree first, a component's shadow root, then
    // the document (Codex review of I-07, round 2, P2-3; Codex review 1 of
    // I-09, P1-2). One that names more than any widget does owns none known.
    const ownedBy = (e) => listsNamedBy(e) || [];
    // The options a field's suggestions show now: in the lists it owns, and
    // nowhere else — another list's options are no answer (P2-3).
    const optionsNow = (e) => ownedBy(e).flatMap((owned) => Array.from(owned.querySelectorAll('[role="option"], li, td')));
    // The check and the text in one task (round 2, P2-1; the reference's
    // `page.py` 798-807): still the field typed into, holding the focus in a
    // focused document, vetted; its suggestions as they are now noted; its
    // text selected so the text replaces it; the text inserted as the page's
    // own editing does it. Nothing of the page runs between.
    const typeText = () => {
      const e = hands.field;
      if (!e || !e.isConnected || String(location.href).slice(0, MAX_URL) !== expected.boundPageURL) return answer('gone');
      const doc = e.ownerDocument;
      if (e.getRootNode().activeElement !== e || !doc.hasFocus()) return answer('gone');
      const verdict = vetted(e);
      if (verdict) return answer(verdict);
      if (!writable(e)) return answer('gone');
      hands.optionsBefore = new WeakSet(optionsNow(e));
      if (typeof e.select === 'function') {
        e.select();
      } else {
        const range = doc.createRange();
        range.selectNodeContents(e);
        const selection = doc.getSelection();
        selection.removeAllRanges();
        selection.addRange(range);
      }
      return answer(doc.execCommand('insertText', false, String(expected.payload)) ? 'done' : 'differs');
    };
    const asksForSuggestions = (e) => e.getAttribute('role') === 'combobox' || e.type === 'search' ||
      !!e.getAttribute('aria-autocomplete') || ownedBy(e).length > 0;
    // `_landed_js`: the field typed into holds the text; or, the page having
    // swapped it or opened an editor over it a moment too late, the field
    // that holds the focus now at its point does — a field elsewhere with the
    // same text is no evidence.
    const landed = () => {
      const e = hands.field;
      const text = String(expected.payload);
      const holds = (n) => !!n && (n.value ?? n.innerText) === text;
      let ok = !!e && e.isConnected && holds(e);
      const was = hands.filled;
      if (!ok && was) {
        const now = was.doc.activeElement;
        if (now && now !== e) {
          const r = now.getBoundingClientRect();
          ok = was.x >= r.left && was.x <= r.right && was.y >= r.top && was.y <= r.bottom && holds(now);
        }
      }
      return JSON.stringify({ outcome: ok ? 'held' : 'differs', suggests: ok && !!e && asksForSuggestions(e) });
    };
    // `_await_suggestions`: the suggestions a field asks for arrive after the
    // typing; a popup that is open is not one that is listed, so only a
    // listed option ends the wait — one in this field's own list, and new
    // since the text went in: a list of something else, or of what the field
    // showed before, is not its answer, and a field that names no list waits
    // the whole bounded time (Codex review of I-07, P2-3, round 2).
    const suggestions = () => new Promise((resolve) => {
      const e = hands.field;
      if (!e || !asksForSuggestions(e)) { resolve(answer('done')); return; }
      const before = hands.optionsBefore;
      const listed = () => optionsNow(e).some((option) => !(before && before.has(option)));
      if (listed()) { resolve(answer('held')); return; }
      let timer = null;
      const observer = new MutationObserver(() => { if (listed()) stop(true); });
      const stop = (ok) => { observer.disconnect(); clearTimeout(timer); resolve(answer(ok ? 'held' : 'differs')); };
      // Watched in the field's own tree too: a list in a component's shadow
      // root changes where the document's watcher does not see (round 2,
      // P2-3).
      const watch = { childList: true, subtree: true, attributes: true, attributeFilter: ['aria-expanded'] };
      observer.observe(e.ownerDocument.body, watch);
      const tree = e.getRootNode();
      if (tree !== e.ownerDocument) observer.observe(tree, watch);
      timer = setTimeout(() => stop(false), 1200);
    });
    // A form's Send, pressed by a person or by script (ITER-076 stage 7,
    // review round 1, C3): each event of the press checked as it comes, in
    // the window's capture, before the page hears it — the element found
    // again with every check its act makes, the fields the Yes is bound to
    // holding what they held, and the press on the element or a label of it
    // (a form's own `submit` has no place to be on). One that fails voids
    // the press: it and every event of it after, and the form it would
    // send, never reach the page.
    const pressChecked = (node) => {
      const own = new Set([node, sourceOf(node), ...(node.labels ? Array.from(node.labels) : [])]);
      const press = { voided: false };
      const kinds = ['pointerdown', 'mousedown', 'pointerup', 'mouseup', 'click', 'submit'];
      const view = node.ownerDocument.defaultView;
      const check = (event) => {
        if (!press.voided) {
          const onIt = event.type === 'submit' || event.composedPath().some((part) => own.has(part));
          press.voided = !onIt || foundAgain(node) !== null;
        }
        if (press.voided) {
          event.preventDefault();
          event.stopImmediatePropagation();
        }
      };
      for (const kind of kinds) view.addEventListener(kind, check, true);
      press.end = () => { for (const kind of kinds) view.removeEventListener(kind, check, true); };
      return press;
    };
    switch (expected.operation) {
      case 'focused': return focusedField(hands.target, false);
      case 'focusedAgain': return focusedField(hands.field, true);
      case 'setDate': return setDate();
      case 'typeText': return typeText();
      case 'landed': return landed();
      case 'suggestions': return suggestions();
      case 'pressed': {
        const press = hands.press;
        hands.press = null;
        if (!press) return answer('done');
        press.end();
        return answer(press.voided ? 'changed' : 'done');
      }
    }
    const found = locate();
    if (!found.node) return answer(found.outcome);
    const node = found.node;
    const announce = () => {
      node.dispatchEvent(new Event('input', { bubbles: true }));
      node.dispatchEvent(new Event('change', { bubbles: true }));
    };
    switch (expected.operation) {
      // The lookup alone: nothing is done (round 5, #14).
      case 'found': return JSON.stringify({ outcome: 'found', frames: framesSeen });
      case 'aim':
      case 'aimToWrite': {
        // Found again right before a person's input, as jev-ultrafast's
        // browser.py does: enabled, and writable when it is to be written in.
        // A label stands for its input only while that input is enabled: the
        // observer reports it no other way (ITER-076 I-08).
        if (node.matches(':disabled') || node.closest('[aria-disabled="true"],[inert]')) return answer('gone');
        if (expected.operation === 'aimToWrite' && (node.readOnly || node.getAttribute('aria-readonly') === 'true')) {
          return answer('gone');
        }
        // A file field is the user's part: never clicked, never written in
        // (ITER-076 I-08).
        const subject = sourceOf(node);
        if (subject instanceof HTMLInputElement && (subject.type || '').toLowerCase() === 'file') {
          return answer('unsupported');
        }
        // A point where a click reaches this control and no other (review of
        // 3.1): the topmost thing there is the control, part of it on the tree
        // a person sees — words a slot puts in it included — or one of its
        // labels, with no other control between. Its centre first, then its
        // labels, then its own lines of words: a row whose centre holds a
        // Delete button is clicked on its words, never on the button. A label
        // and the input it stands for are one target (ITER-076 I-08, a
        // reference browser agent's hit test).
        const labels = (node.labels ? Array.from(node.labels) : []).concat(subject === node ? [] : [subject]);
        // What a click cannot be seen through: a frame, or a component with
        // no open shadow root — a control of its own may sit inside.
        const sealed = (el) => /^(iframe|frame|embed|object)$/.test(el.localName)
          || (el.localName.includes('-') && !el.shadowRoot);
        // The topmost element at a point. A component answers for its own
        // shadow root with its host: look inside, so a control there is seen.
        const root = node.getRootNode();
        const scope = root instanceof ShadowRoot ? root : document;
        const topmost = (x, y) => {
          let hit = scope.elementFromPoint(x, y);
          for (let hops = 0; hit && hit.shadowRoot && hops < 10; hops++) {
            const inner = hit.shadowRoot.elementFromPoint(x, y);
            if (!inner || inner === hit) break;
            hit = inner;
          }
          return hit;
        };
        // A label for another control — one that is not this control or the
        // input it stands for — is that control: a click on it lands there
        // (Codex review 1 of I-08, P1-4). Inside this control, only a box, a
        // radio or a field it wraps is a part of it — a styled checkbox around
        // its own hidden input, whose label ticks it (Codex review 2 of I-08,
        // P1-3). Anything else a label can name — a button, an input that
        // sends, resets, opens a file or a colour picker, a control of the
        // page's own making — is another control wherever it stands (Codex
        // review 3 of I-08, P1-3).
        // A part of it is one it wraps on the tree a person sees, its shadow
        // roots included, and that the report does not hold as a control of
        // its own: a visible box beside the target is another control (Claude
        // review of I-08's round-2 fix).
        const actingTypes = ['button', 'submit', 'reset', 'image', 'file', 'color'];
        const ownPart = (control) => control.localName === 'textarea' || control.localName === 'select' ||
          (control.localName === 'input' && !actingTypes.includes((control.type || 'text').toLowerCase()));
        const wraps = (control) => {
          for (let current = control, hops = 0; current && hops < 50; current = composedParent(current), hops++) {
            if (current === node) return true;
          }
          return false;
        };
        const reported = new Set(found.nodes || []);
        const anotherLabel = (el) => {
          if (!(el instanceof HTMLLabelElement) || el === node || labels.includes(el)) return false;
          const control = labelControl.call(el);
          return !!control && control !== subject &&
            !(wraps(control) && ownPart(control) && !reported.has(control));
        };
        // A label around this control that names another control takes its
        // click too: a click on a part of a label runs the label's control
        // (Claude review of I-08's round-2 fix). No point of it is safe — but
        // where the control, or anything between it and the label, is native
        // interactive content as HTML defines it: a button, an input that is
        // not hidden, a select, a text area, a link with an address, a label,
        // a frame, media with controls, a map's picture. A click there runs
        // no label's activation in Chrome (`HTMLLabelElement`, checked live),
        // and the control is clicked as itself (Claude review of I-09, kept
        // 16). A control of the page's own making is no such content.
        const interactiveContent = (el) => {
          if (!(el instanceof HTMLElement)) return false;
          const tag = el.localName;
          if (['button', 'select', 'textarea', 'label', 'iframe', 'embed'].includes(tag)) return true;
          if (tag === 'input') return (el.type || '').toLowerCase() !== 'hidden';
          if (tag === 'a') return el.hasAttribute('href');
          if (tag === 'audio' || tag === 'video') return el.hasAttribute('controls');
          if (tag === 'img' || tag === 'object') return el.hasAttribute('usemap');
          return false;
        };
        let aroundAnother = false;
        for (let around = composedParent(node), shielded = interactiveContent(node), hops = 0; around && hops < 50;
             around = composedParent(around), hops++) {
          if (anotherLabel(around)) { aroundAnother = !shielded; break; }
          if (interactiveContent(around)) shielded = true;
        }
        const reaches = (hit, x, y) => {
          let start = hit;
          // Words a slot puts in a component are answered for by its host;
          // the words at the point tell which slot, and so which control, they
          // fill.
          if (hit.shadowRoot && document.caretRangeFromPoint) {
            const caret = document.caretRangeFromPoint(x, y);
            const words = caret && caret.startContainer;
            if (words && words.nodeType === 3 && words.parentNode === hit && words.assignedSlot) start = words.assignedSlot;
          }
          for (let current = start, hops = 0; current && hops < 50; current = composedParent(current), hops++) {
            if (current === node || labels.includes(current)) return true;
            if (current.matches(selector) || sealed(current) || anotherLabel(current)) return false;
          }
          return false;
        };
        const onScreen = (x, y) => x >= 0 && y >= 0 && x < innerWidth && y < innerHeight;
        // A grid over a box, nearest its centre first.
        const grid = (box) => {
          const list = [];
          for (let j = 1; j <= 3; j++) {
            for (let i = 1; i <= 5; i++) {
              list.push({ x: box.left + box.width * i / 6, y: box.top + box.height * j / 4,
                          far: Math.abs(i - 3) / 5 + Math.abs(j - 2) / 3 });
            }
          }
          return list.sort((a, b) => a.far - b.far);
        };
        // Its own lines of words, and those its slots show — never words
        // inside another control.
        const wordPoints = () => {
          const words = [];
          const texts = document.createTreeWalker(node, NodeFilter.SHOW_TEXT);
          for (let text = texts.nextNode(); text && words.length < 10; text = texts.nextNode()) {
            if (!text.textContent.trim()) continue;
            let another = false;
            for (let el = text.parentElement; el && el !== node; el = composedParent(el)) {
              if (el.matches(selector) || sealed(el)) { another = true; break; }
            }
            if (!another) words.push(text);
          }
          for (const slot of node.querySelectorAll('slot')) {
            for (const part of slot.assignedNodes({ flatten: true })) {
              if (part.nodeType === 3 && part.textContent.trim() && words.length < 12) words.push(part);
            }
          }
          const range = document.createRange();
          const list = [];
          for (const text of words) {
            range.selectNodeContents(text);
            for (const line of Array.from(range.getClientRects()).slice(0, 3)) {
              list.push({ x: line.left + line.width / 2, y: line.top + line.height / 2 });
            }
          }
          return list;
        };
        const measure = (settled) => {
          // A page that settled may have changed: found again, with every
          // check an act makes — a login wall the scroll brought included.
          if (settled) {
            const lost = foundAgain(node);
            if (lost) return answer(lost);
          }
          if (aroundAnother) return answer('covered');
          // First a point where the topmost thing is the control itself or
          // one of its labels: then no part of it — named a control or not, a
          // span a listener waits on, a frame — takes the click (review of
          // 3.1, round 2).
          for (const part of [node, ...labels]) {
            const box = part.getBoundingClientRect();
            if (!box.width || !box.height) continue;
            for (const { x, y } of grid(box)) {
              if (!onScreen(x, y)) continue;
              const hit = topmost(x, y);
              if (hit === node || labels.includes(hit)) return JSON.stringify({ outcome: 'aim', x, y, frames: framesSeen });
            }
          }
          // A control its parts cover whole is clicked on a part of it — its
          // centre, its labels, its own words — with no other control, frame
          // or closed component between (review of 3.1).
          const box = node.getBoundingClientRect();
          const centre = (part) => {
            const edge = part.getBoundingClientRect();
            return { x: edge.left + edge.width / 2, y: edge.top + edge.height / 2 };
          };
          for (const { x, y } of [node, ...labels].map(centre).concat(wordPoints())) {
            if (!onScreen(x, y)) continue;
            const hit = topmost(x, y);
            if (hit && reaches(hit, x, y)) return JSON.stringify({ outcome: 'aim', x, y, frames: framesSeen });
          }
          const seen = box.bottom > 0 && box.right > 0 && box.top < innerHeight && box.left < innerWidth;
          return answer(seen ? 'covered' : 'gone');
        };
        // What the aim comes to: the point a person's click goes to.
        const aimed = (text) => {
          if (expected.operation === 'aim' || JSON.parse(text).outcome !== 'aim') return text;
          // The hand-off (ITER-076 I-07): the field, and the point it covers,
          // before a person's click reaches it.
          const r = node.getBoundingClientRect();
          hands.target = node;
          hands.handoff = { doc: node.ownerDocument, root: node.getRootNode(),
                            x: r.x + r.width / 2, y: r.y + r.height / 2 };
          hands.field = null;
          hands.filled = null;
          return text;
        };
        // An option of a list that scrolls — a long made-up dropdown's — is
        // brought into sight by scrolling that list alone: the page does not
        // move, so a menu that closes when the page scrolls stays open (review
        // of I-08, F1).
        const ownList = () => {
          if (!(node.getAttribute('role') || '').split(/\s+/).includes('option')) return null;
          for (let el = composedParent(node), hops = 0; el && el !== document.body && el !== document.documentElement &&
               hops < 50; el = composedParent(el), hops++) {
            if (/(auto|scroll)/.test(getComputedStyle(el).overflowY) && el.scrollHeight > el.clientHeight) return el;
          }
          return null;
        };
        // It goes to the middle of the part of its list a person sees — the
        // list clipped to the window — and the page never moves for it: a list
        // that runs past the window's edge stays open (Codex review 1 of I-08,
        // P2-5).
        const list = ownList();
        let listMoved = false;
        if (list) {
          const r = node.getBoundingClientRect();
          const edge = list.getBoundingClientRect().top + list.clientTop;
          const top = Math.max(edge, 0);
          const bottom = Math.min(edge + list.clientHeight, innerHeight);
          const middle = r.top + r.height / 2;
          if (middle < top || middle > bottom) {
            list.scrollTop += middle - (top + bottom) / 2;
            listMoved = true;
          }
        }
        const box = node.getBoundingClientRect();
        const inView = box.top >= 0 && box.left >= 0 && box.bottom <= innerHeight && box.right <= innerWidth;
        if (inView && !listMoved) {
          const there = measure(false);
          // On screen with something laid over it — a banner fixed to the
          // window's edge that the page scrolled it under (2026-10-21, blind
          // b03: a site's footer over its State field) — it is brought to the
          // middle of the window once, as a person scrolls it out, and aimed
          // at there once the page has settled. An option is never: the page
          // does not move for its list. Covered there too, it stays covered.
          if (list || ownList() || aroundAnother || JSON.parse(there).outcome !== 'covered') return aimed(there);
          node.scrollIntoView({ block: 'center', inline: 'nearest', behavior: 'instant' });
        }
        // Off screen: brought on at once — a smooth scroll would still be
        // moving — and aimed at once the page has settled, as jev-ultrafast
        // waits after an action: two frames, or 50 ms.
        if (!inView && !list) node.scrollIntoView({ block: 'center', inline: 'nearest', behavior: 'instant' });
        return new Promise((resolve) => {
          let frames = 0, settled = false;
          const settle = () => { if (!settled) { settled = true; resolve(aimed(measure(true))); } };
          const frame = () => (++frames >= 2 ? settle() : requestAnimationFrame(frame));
          setTimeout(settle, 50);
          requestAnimationFrame(frame);
        });
      }
      case 'arm': {
        if (hands.press) hands.press.end();
        const press = pressChecked(node);
        hands.press = press;
        // A press that never comes lets its check go.
        setTimeout(() => press.end(), 3000);
        return answer('armed');
      }
      case 'open':
        location.assign(expected.destination);
        return answer('done');
      case 'click': {
        node.scrollIntoView({ block: 'center', inline: 'nearest' });
        if (!Array.isArray(expected.boundValues)) {
          node.click();
          return answer('done');
        }
        // The page's own handlers of the click may change a value before the
        // form goes: checked as they come (review round 1, C3).
        const press = pressChecked(node);
        try {
          node.click();
        } finally {
          press.end();
        }
        return answer(press.voided ? 'changed' : 'done');
      }
      case 'type': {
        const text = String(expected.payload);
        node.focus();
        // Focus runs the page's own handlers. The field must still be the one
        // chosen — found again, so still not sensitive — and still hold the
        // focus; otherwise nothing is written. A secret field the handlers
        // brought makes the page the user's part.
        const lost = foundAgain(node);
        if (lost) return answer(lost);
        const root = node.getRootNode();
        const focused = root instanceof ShadowRoot ? root.activeElement : document.activeElement;
        if (focused !== node) return answer('gone');
        if (node.isContentEditable) {
          document.execCommand('selectAll', false);
          const selection = window.getSelection();
          const inside = (part) => !!part && node.contains(part);
          if (!selection || !inside(selection.anchorNode) || !inside(selection.focusNode)) return answer('unsupported');
          document.execCommand('insertText', false, text);
          return answer('done');
        }
        const prototype = node instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype
          : node instanceof HTMLInputElement ? HTMLInputElement.prototype : null;
        if (!prototype) return answer('unsupported');
        Object.getOwnPropertyDescriptor(prototype, 'value').set.call(node, text);
        announce();
        return answer('done');
      }
      case 'select': {
        if (!(node instanceof HTMLSelectElement)) return answer('unsupported');
        const option = listedOption(node);
        if (!option) return answer('gone');
        // A list that takes several choices gets this one added, as a click with the command key adds it: the
        // others stay (2026-10-21, blind b02 — each choice replaced the one before). A list of one changes its choice.
        if (node.multiple) option.selected = true;
        else node.selectedIndex = expected.optionIndex;
        announce();
        return answer('done');
      }
      case 'holds': {
        // Read here, so the value never leaves the page (ITER-076 2.3). Typed
        // text is compared whole; an option as the observer lists it.
        const flat = (text) => String(text).replace(/\s+/g, ' ').trim();
        let held = false;
        const shown = found.choiceShown(node);
        if (node instanceof HTMLSelectElement) {
          const option = listedOption(node);
          held = !!option && option.selected === true;
        } else if (shown !== null) {
          // A made-up dropdown: the choice it shows, as the observer reads
          // words (ITER-076 I-08).
          held = shown === collapse(expected.payload);
        } else if (node.isContentEditable) {
          held = flat(node.innerText || '') === flat(expected.payload);
        } else if (typeof node.value === 'string') {
          held = flat(node.value) === flat(expected.payload);
        }
        return answer(held ? 'held' : 'differs');
      }
    }
    return answer('unsupported');
    """#

    /// One screen down, at once — a smooth scroll would still be moving. A
    /// page that cannot scroll further moves its largest panel on screen
    /// that can instead — a chat list, a results pane (ITER-076 I-10, critic
    /// 16): one that shows at least a fifth of the screen each way, and no
    /// field. One of its own screens down, at once.
    private static let scroll = #"""
    (() => {
      const before = window.scrollY;
      window.scrollBy({ top: Math.round(window.innerHeight * 0.9), behavior: 'instant' });
      if (window.scrollY !== before) return JSON.stringify({ outcome: 'done', moved: true });
      let panel = null, largest = 0;
      const all = document.querySelectorAll('*');
      for (let i = 0; i < all.length && i < 20000; i++) {
        const el = all[i];
        if (el.scrollHeight - el.clientHeight - el.scrollTop < 1) continue;
        if (['input', 'textarea', 'select'].includes(el.localName) || el.isContentEditable) continue;
        if (!/(auto|scroll|overlay)/.test(getComputedStyle(el).overflowY)) continue;
        const box = el.getBoundingClientRect();
        const width = Math.min(box.right, innerWidth) - Math.max(box.left, 0);
        const height = Math.min(box.bottom, innerHeight) - Math.max(box.top, 0);
        if (width < innerWidth / 5 || height < innerHeight / 5) continue;
        if (!el.checkVisibility({ checkOpacity: true, checkVisibilityCSS: true })) continue;
        if (width * height > largest) { largest = width * height; panel = el; }
      }
      if (!panel) return JSON.stringify({ outcome: 'done', moved: false });
      const top = panel.scrollTop;
      panel.scrollBy({ top: Math.round(panel.clientHeight * 0.9), behavior: 'instant' });
      return JSON.stringify({ outcome: 'done', moved: panel.scrollTop !== top });
    })()
    """#
}
