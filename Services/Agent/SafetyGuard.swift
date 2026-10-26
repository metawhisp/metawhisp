import Foundation

/// The safety rules that need no model (ITER-074 §6.3, §7.1, §7.2).
///
/// ITER-076 2.1 (owner, 2026-09-26): any user language is supported, and the
/// app's code holds no Russian. Words are one signal, in English only; the
/// page's structure and Jev's risk answer read every language, and a missing
/// answer means no action.
enum SafetyGuard {
    /// §7.1, English: action words in their base form. Matching is by whole
    /// word, so nouns that name sections ("Posts", "Orders") are not hits —
    /// the irreversible question to the model covers meaning (§6.3).
    static let englishActionWords: Set<String> = [
        "send", "submit", "publish", "post", "delete", "remove", "pay", "buy", "order", "share",
        "invite", "allow", "accept", "agree", "grant", "authorize", "authorise", "confirm",
        "purchase", "checkout", "transfer", "donate", "bid", "book", "reserve", "subscribe", "upload",
        "withdraw", "sell"
    ]

    /// §6.3: words that make a link something other than a harmless visit.
    static let englishNavigationActionWords: Set<String> = ["logout", "signout", "unsubscribe", "cancel", "approve"]
    static let englishNavigationActionPairs: [(String, String)] = [("log", "out"), ("sign", "out")]

    /// The first irreversible word in any of the texts, or nil. Addresses
    /// are read too — decoded first, so `%64elete` and `delete+account` are
    /// words — and `/api/deleteAccount` and `/api/DELETEAccount` both hit.
    static func lexiconHit(in texts: [String?]) -> String? {
        for text in texts.compactMap({ $0 }) {
            for word in words(in: decoded(text)) where englishActionWords.contains(word) {
                return word
            }
        }
        return nil
    }

    /// §7.1: the lexicon reads the target's name and visible text, its form's
    /// submit label and destination, where the action goes and a select's
    /// chosen option — so a benign name cannot hide what the form does.
    /// Leaving or undoing something — log out, unsubscribe, cancel, approve —
    /// needs a Yes too: the agent must not sign the user out or drop a
    /// subscription on its own.
    static func lexiconRequiresConfirmation(_ action: AgentAction) -> Bool {
        let target = action.target
        // An option's dropdown's form is read as its own is (Codex review 1 of
        // I-08, P1-3).
        let texts = [target?.name, target?.text, target?.formSubmitLabel, target?.formAction,
                     target?.listForm?.submitLabel, target?.listForm?.action,
                     target?.href, action.destination, chosenOption(of: action)]
        return lexiconHit(in: texts) != nil
            || texts.compactMap { $0 }.contains { containsNavigationActionWord(decoded($0)) }
    }

    /// §6.3: a link is a harmless visit only when it is a web address whose
    /// text, path and query hold no irreversible word and no action word
    /// (logout, unsubscribe, cancel, approve…).
    static func passesNavigationCheck(url: URL, linkText: String) -> Bool {
        guard DiaScript.isOpenable(url) else { return false }
        let texts = [linkText, url.path, url.query ?? ""]
        guard lexiconHit(in: texts) == nil else { return false }
        return !texts.contains { containsNavigationActionWord(decoded($0)) }
    }

    /// ITER-076 2.1: what the page's structure says about an action, in any
    /// language. A click anywhere in a POST form may send it (a label, a
    /// script button), and sending any other form hands its fields on — to
    /// another site, or to this one. A select in a POST form may send it when
    /// it changes (2.2) — a submit button beside it says nothing of that: an
    /// AutoPostBack select sends its form as it changes (ITER-076 I-10, critic
    /// 27). Each needs a Yes, whatever the model says (§7.1). A link is not one: every link already gets the
    /// risk question, and asking on each would stop every research errand.
    enum StructuralReason: Equatable { case postForm, crossOriginForm, submitsForm }

    /// Only a click or a select in a form has a structural reason, and
    /// nothing in a dialog form. A control that does not say whether it
    /// submits counts as one that does, and a page whose address is unknown
    /// counts as another site.
    static func structuralReason(of action: AgentAction, pageURL: String?) -> StructuralReason? {
        guard let target = action.target else { return nil }
        // An option of a made-up dropdown answers to two forms: the one the
        // page draws it in, and the one its dropdown sends, which its click
        // may send too. Either one's reason counts (Codex review 1 of I-08,
        // P1-3).
        let own = reason(action.operation, method: target.formMethod, destination: target.formAction,
                         submits: target.submits, pageURL: pageURL)
        return own ?? target.listForm.flatMap {
            reason(action.operation, method: $0.method, destination: $0.action, submits: false, pageURL: pageURL)
        }
    }

    /// One form's structural reason for an action on a control of it.
    private static func reason(_ operation: AgentOperation, method: String?, destination: String?,
                               submits: Bool?, pageURL: String?) -> StructuralReason? {
        guard let method, method != "dialog" else { return nil }
        if operation == .select {
            return method == "post" ? .postForm : nil
        }
        guard operation == .click else { return nil }
        if method == "post" { return .postForm }
        guard submits != false else { return nil }
        guard let page = pageURL.flatMap(URL.init(string:)), let destination,
              let to = URL(string: destination), sameOrigin(page, to) else { return .crossOriginForm }
        return .submitsForm
    }

    /// D4, strictly (the orchestrator's default of 2026-10-05; ITER-076
    /// stage 3, № 81, 82, 84): a search goes without a Yes only to the address
    /// code builds from its form, opened in the tab — never by a click, so
    /// none of the page's code runs for it. Its form: a GET form of the
    /// page's own site, in the page's own document, the page read whole; its
    /// one text field a search field — a search box, or one in the page's
    /// search landmark — that the agent typed in this sub-goal (`typed`, by
    /// fingerprint, with its text), or that shows word for word a text it
    /// typed in this sub-goal; no other control of it filled; no
    /// password or file field; no grant, secret, payment or action word in
    /// its button's words. Its address: the form's destination with its query
    /// as a browser writes it — the hidden fields as they are, the typed text
    /// in the field's place — a web address the agent may open, short enough
    /// to be read back whole. `action`: Jev's click on the form's submit
    /// button. Nil: no such search — the form is asked about as any.
    static func searchAddress(for action: AgentAction, on page: ObservedPage, typed: [String: String]) -> URL? {
        guard action.operation == .click, let button = action.target, button.submits == true, button.frame == nil,
              button.formMethod == "get", button.listForm == nil, !button.touchesSecret, button.needsFile != true,
              structuralReason(of: action, pageURL: page.liveAddress) == .submitsForm,
              !isGrant(action), !lexiconRequiresConfirmation(action), !namesPaymentByItsWords(action),
              !pays(action, risk: .irreversible, on: page.flags) else { return nil }
        return searchAddress(of: button, on: page, typed: typed)
    }

    /// The search of a form, sent as its field's typing ends — as a person's
    /// Enter sends it (№ 122) — by the same rules, the field's own words read
    /// as a button's are; with no button, and with one a person can press
    /// (2026-10-07: on Wikipedia the agent typed, then kept picking a
    /// suggestion list that closed under it, and never sent the search).
    /// Enter presses its first submit button, drawn or not: the act is read
    /// as a click on that button, its words with the field's — so those words
    /// must be known: a button no one can press whose words the page does not
    /// give (`display: none` hides its text) could say anything, and its form
    /// is asked about (Codex review 1 of the fix, P1). A disabled one is read
    /// as a hidden one: the address is the GET a person's Enter sends once it
    /// is enabled, and its words pass every check first.
    static func searchAddress(typedInto field: ObservedElement, on page: ObservedPage, typed: [String: String]) -> URL? {
        let wordsKnown = field.formSubmitLabel != nil || field.submitUnpressable != true
        guard wordsKnown, field.frame == nil,
              field.formMethod == "get", !field.touchesSecret, field.needsFile != true, field.formGrants != true,
              let action = field.formAction, let to = URL(string: action), let from = URL(string: page.liveAddress),
              sameOrigin(from, to), !hasOAuthMarkers(action) else { return nil }
        var enter = field
        enter.submits = true
        let words = AgentAction(operation: .click, target: enter, destination: nil, payload: nil, isPlannedSearch: false)
        guard !lexiconRequiresConfirmation(words), !namesPaymentByItsWords(words),
              !pays(words, risk: .irreversible, on: page.flags) else { return nil }
        return searchAddress(of: field, on: page, typed: typed)
    }

    /// The address of the GET form `member` is part of, as D4 builds it;
    /// nil when the form is no pure search. The form is the member's own
    /// group: a second form that sends to the same address — a footer's
    /// search under a header's — is not more fields of it (2026-10-19: a
    /// park service's header search asked a Yes for that).
    private static func searchAddress(of member: ObservedElement, on page: ObservedPage, typed: [String: String]) -> URL? {
        guard !page.truncated, let action = member.formAction else { return nil }
        let form = page.elements.filter {
            $0.frame == nil && $0.formMethod == "get" && $0.formAction == action
                && (member.group == nil || $0.group == nil || $0.group == member.group)
        }
        guard !form.contains(where: { $0.inputType == "file" || $0.inputType == "password" }) else { return nil }
        let fields = form.filter(CandidateBuilder.takesTyping)
        // Words the agent typed in this sub-goal, in a box drawn anew, are its
        // typing still: a search's results show its box again with the query
        // in it, under another fingerprint (live, 2026-10-07).
        guard fields.count == 1, let field = fields.first,
              let text = typed[field.fingerprint] ?? field.value.flatMap({ typed.values.contains($0) ? $0 : nil }),
              field.role == "searchbox" || field.inputType == "search" || field.inSearch == true,
              let entries = field.formEntries, entries.filter({ $0.value == nil }).count == 1 else { return nil }
        // A second control that sends what it holds: no pure search (№ 84).
        let filled = form.contains { other in
            other.index != field.index && other.submits != true
                && (other.checked == true || !(other.value ?? "").isEmpty)
        }
        guard !filled else { return nil }
        let query = entries.map { formEncoded($0.name) + "=" + formEncoded($0.value ?? text) }.joined(separator: "&")
        let base = action.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? action
        guard let address = URL(string: base + "?" + query), DiaScript.isOpenable(address),
              address.absoluteString.count < ObserverScript.maxURLLength else { return nil }
        return address
    }

    /// `text` as a browser writes a form's query
    /// (`application/x-www-form-urlencoded`): a space as "+", every byte but
    /// an ASCII letter, a digit and `*-._` as "%XX".
    static func formEncoded(_ text: String) -> String {
        var out = ""
        for byte in text.utf8 {
            switch byte {
            case 0x20: out += "+"
            case 0x2A, 0x2D, 0x2E, 0x5F, 0x30...0x39, 0x41...0x5A, 0x61...0x7A: out.append(Character(Unicode.Scalar(byte)))
            default: out += String(format: "%%%02X", byte)
            }
        }
        return out
    }

    /// §6.3: back, scroll, wait and «more» are always reversible, and so is a
    /// search the app built from the plan's own queries — which has no target
    /// on the page and a web address. A link from the page is never taken on trust:
    /// a GET can purchase, transfer or unsubscribe whatever its words say, so
    /// every link gets the risk question.
    static func isAlwaysReversible(_ action: AgentAction) -> Bool {
        switch action.operation {
        case .back, .scroll, .wait, .more:
            return true
        case .open:
            guard action.isPlannedSearch, action.target == nil, let destination = action.destination,
                  let url = URL(string: destination), DiaScript.isOpenable(url) else { return false }
            return true
        case .click, .type, .select, .done, .stuck:
            return false
        }
    }

    /// §7.2: a grant — OAuth, a permission prompt, «Allow access» — is the
    /// user's part: not asked about, handed over. Recognised here in any
    /// language by structure (an OAuth request in an address or in a form's
    /// fields) and in English by its words. A grant in another language with
    /// no such mark is asked about when structure, the English lexicon or
    /// Jev's `irreversible` answer (0.2 or more) says so; otherwise it is
    /// taken on Jev's answer — until Jev's grant question (E, approved on
    /// 2026-09-27) is wired in (ITER-076 1.3). A label that names cookies is
    /// consent to cookies, not a grant (decision 15).
    static let grantWords: Set<String> = ["allow", "grant", "authorize", "authorise"]
    /// The words a cookie consent label is made of (§7.2). A label that names
    /// cookies and holds nothing but these is consent to cookies; a label with
    /// any other word — "access", "account" — is a grant, cookies or not.
    static let cookieConsentWords: Set<String> = [
        "allow", "accept", "agree", "all", "and", "only", "the", "these", "necessary", "essential", "required",
        "optional", "selected", "selection", "analytics", "marketing", "functional", "performance", "preference",
        "preferences", "statistics", "tracking", "advertising"
    ]

    static func isGrant(_ action: AgentAction) -> Bool {
        // An address the model opens itself is a grant when it carries an OAuth request, as a link to it is: a
        // consent page's approval read off the page has no control to wall (Codex review of 2026-10-21, P1-4).
        guard let target = action.target else {
            return action.operation == .open && action.destination.map(hasOAuthMarkers) == true
        }
        // An option's dropdown's form grants as its own form does (Codex
        // review 1 of I-08, P1-3).
        if target.formGrants == true || target.listForm?.grants == true { return true }
        // An address that grants is a grant whatever its query says.
        let labels = [target.name, target.text, target.formSubmitLabel, target.listForm?.submitLabel].compactMap { $0 }
        let addressGrants = [target.formAction, target.listForm?.action, target.href, action.destination]
            .compactMap { $0 }
            .contains { words(in: decoded($0)).contains(where: grantWords.contains) || hasOAuthMarkers($0) }
        return labels.contains { namesGrant($0) } || addressGrants
    }

    /// Words that grant, in English: a grant word — unless they are about
    /// nothing but cookies ("Allow all cookies"). A control's label is read
    /// by them as the observer reads a page: compatibility forms as what they
    /// stand for, hidden marks as nothing (Claude review of I-09, kept 1). A
    /// page's own dialog is read by its stricter rule (`dialogAsks`).
    private static func namesGrant(_ text: String) -> Bool {
        let found = words(in: plain(decoded(text)))
        guard found.contains(where: grantWords.contains) else { return false }
        let isCookieWord = { (word: String) in word.hasPrefix("cookie") }
        let aboutCookiesOnly = found.contains(where: isCookieWord)
            && found.allSatisfy { isCookieWord($0) || cookieConsentWords.contains($0) }
        return !aboutCookiesOnly
    }

    /// Owner decision 6 (2026-09-26): paying is the user's part — the agent
    /// never pays, not even after a Yes (review of A3, round 1). Owner
    /// decision of 2026-10-19: a payment is a page that asks card details —
    /// a card field, a saved card shown, a payment provider's frame
    /// (`PageFlags.paymentForm`) — and nothing else: the words of a control
    /// ("Pay now", "Place order") and a money amount beside it name none,
    /// and such an act is asked about as any send. An irreversible act on a
    /// page that takes a payment is the user's part; checked before the
    /// question, again on the page the Yes came on, and by the hands at the
    /// act (N3-P1-5).
    static func pays(_ action: AgentAction, risk: ActionRisk, on flags: PageFlags) -> Bool {
        risk == .irreversible && flags.paymentForm
    }

    /// Controls a click only sets: a box, a choice, a tab. Clicking one that
    /// does not submit edits a form or a view and commits nothing (review of
    /// I-02, N3-P2-3); a native submitter commits whatever role it names
    /// itself (N4-P1-1).
    static let editRoles: Set<String> = ["checkbox", "radio", "switch", "menuitemcheckbox", "menuitemradio",
                                         "option", "tab"]


    /// An action that could send what a form or a page holds: a click on a
    /// submitter, or on anything but a control it only sets, an open — and a
    /// click on a control it only sets, or a select, whose change no submit
    /// button sends: one of no form at all, its own or its dropdown's, or
    /// whose own form or dropdown's form has no submit button, whatever its
    /// method — its own change may be the send (Claude review of I-09, kept
    /// 14; Claude review c8, #23; decision 11 of review round 4, Claude
    /// review c9, #14). Typing, or choosing in a form sent by its own button,
    /// changes a field and commits nothing: a select there that may send its
    /// POST form as it changes asks the user's Yes for that
    /// (`structuralReason`, ITER-076 I-10), and still commits nothing. The
    /// policy and the hands read this one answer: the hands check payment
    /// evidence again for such an act (N3-P1-5).
    /// An edit of a field that sends nothing (owner decision of 2026-10-19: the brain's errand asks one Yes, at the
    /// send): text typed, a box ticked in a form its own button sends — and an option chosen wherever its list
    /// stands (2026-10-21: a shop's "Order by" in no form was asked about as a send, a quote site's author list that
    /// posts its form ended the errand): under the send hold what a choice's change sends is held back, and the
    /// choice is asked about as a send (`AgentRun.heldBackChoice`). Such a choice still commits as an act: the hands
    /// and the step read `commits`. A box whose form no button sends commits, and is not one.
    /// A click on a field typing goes into (`typedInto`) is one too: under the hold it only focuses the field, as the
    /// click typing starts with does, and reaches nothing typing in it does not (2026-10-21, blind b03: a click on a
    /// made-up State list in a form whose button says Submit was asked about as a send, every time). A field typing
    /// never goes into — read-only, aria-readonly, a native select, a list — is not (Codex reviews 2 and 3 of
    /// 2026-10-21). As a choice does, it still commits as an act: the hands and the step check it again, and a Yes
    /// asked for it without the hold is bound as a press's (Codex review of 2026-10-21, P1-2).
    static func editsOnly(_ action: AgentAction) -> Bool {
        guard let target = action.target else { return false }
        let fieldClick = action.operation == .click && target.typedInto == true && target.submits != true
        guard action.operation == .select || fieldClick || !commits(action) else { return false }
        switch action.operation {
        case .type, .select: return true
        case .click: return fieldClick || editRoles.contains(target.role) && target.submits != true
        default: return false
        }
    }

    static func commits(_ action: AgentAction) -> Bool {
        switch action.operation {
        case .click:
            guard let target = action.target else { return true }
            if target.submits == true || !editRoles.contains(target.role) { return true }
            return sentByItsChange(target)
        case .open: return true
        case .select: return action.target.map(sentByItsChange) ?? true
        default: return false
        }
    }

    /// A press that would send a form short of a secret field the form needs
    /// — empty, and `required`, `aria-required`, or autocompleted as the
    /// sign-in's own password, a new one or a code (`formNeedsSecret`) — is
    /// the user's sign-in, handed over before any Yes (2026-10-21): the
    /// question would only send what the site turns away, and the errand
    /// would never reach the sign-in's hand-over. A field's typing sends
    /// nothing and stays the errand's; a form whose empty secret field is
    /// optional is asked about as any send.
    static func needsTheUsersSecret(_ action: AgentAction) -> Bool {
        commits(action) && action.target?.formNeedsSecret == true
    }

    /// Whether no submit button sends what `target` sets: it has no form,
    /// its own or its dropdown's, or one of those has no submit button — or
    /// none a person can press (Claude review c11, #11).
    private static func sentByItsChange(_ target: ObservedElement) -> Bool {
        let ownSentByNone = target.formMethod != nil && target.formSubmitLabel == nil
        let listSentByNone = target.listForm.map { $0.submitLabel == nil } == true
        return (target.formMethod == nil && target.listForm == nil) || ownSentByNone || listSentByNone
            || target.submitUnpressable == true
    }

    /// The words that name a payment, in English: a control that says so —
    /// "Pay now", "Place order", "Charge the card" — is asked about before it
    /// goes, whatever Jev says of its risk (`AgentPolicy.risk`), and is no
    /// search of the agent's (D4). Not a payment the user must make: that is
    /// a page asking card details (owner decision of 2026-10-19).
    static let englishPaymentWords: Set<String> = ["pay", "buy", "purchase", "checkout", "donate", "bid", "charge",
                                                   "charged", "charges", "debit", "debited", "paid", "payment",
                                                   "payments"]
    /// The stems payment words are made of, in English, each with the endings
    /// it takes only as a payment word (Claude review of I-09, kept 1):
    /// "billed", "purchased", "debiting" — the forms of "charge" a payment
    /// takes are words above — never "charger", "charging", "billing",
    /// "bills", "billion" or a name, "Bill", which name a place to charge a
    /// phone, an address ("Billing country"), a law or a person as often as a
    /// payment.
    static let englishPaymentStems: [(stem: String, endings: Set<String>)] = [
        ("bill", ["ed"]), ("purchas", ["e", "es", "ed", "ing"]), ("debit", ["", "s", "ed", "ing"]),
    ]
    static let englishPaymentPairs: [(String, String)] = [("place", "order"), ("complete", "order"),
                                                          ("confirm", "order"), ("submit", "order"),
                                                          ("order", "now"), ("check", "out")]

    /// The words of the control acted on name a payment, in English: its
    /// name and text, and its form's submit label only when the act is a
    /// click on that submitter — one that says it does not submit is a field
    /// or a control of the form, and changing it in a form whose button says
    /// "Buy" names nothing (review of A3d, round 2, N-P2-1; review of I-02,
    /// N3-P2-3).
    static func namesPaymentByItsWords(_ action: AgentAction) -> Bool {
        guard let target = action.target else { return false }
        let sendsForm = action.operation == .click && target.submits != false
        let labels = [target.name, target.text] + (sendsForm ? [target.formSubmitLabel] : [])
        return labels.compactMap { $0 }.contains(where: namesPayment)
    }

    /// Words that name a payment, in English: a payment word, a form of a
    /// payment stem, or one of the pairs — as the observer reads a page:
    /// compatibility forms as what they stand for, hidden marks as nothing
    /// (Claude review of I-09, kept 1).
    private static func namesPayment(_ text: String) -> Bool {
        let found = words(in: plain(decoded(text)))
        if found.contains(where: isPaymentWord) { return true }
        return englishPaymentPairs.contains { first, second in
            found.indices.dropLast().contains { found[$0] == first && found[$0 + 1] == second }
        }
    }

    private static func isPaymentWord(_ word: String) -> Bool {
        englishPaymentWords.contains(word) || englishPaymentStems.contains { stem, endings in
            word.hasPrefix(stem) && endings.contains(String(word.dropFirst(stem.count)))
        }
    }

    /// The ISO 4217 codes a money amount is written with (owner decision 6):
    /// the one list the observer reads a page by and the policy reads a
    /// dialog by (review of I-09, F4).
    static let currencyCodes: [String] = ("AED AFN ALL AMD ANG AOA ARS AUD AWG AZN BAM BBD BDT BGN BHD BIF BMD BND BOB "
        + "BRL BSD BTN BWP BYN BZD CAD CDF CHF CLP CNY COP CRC CUC CUP CVE CZK DJF DKK DOP DZD EGP ERN ETB EUR FJD FKP "
        + "GBP GEL GHS GIP GMD GNF GTQ GYD HKD HNL HTG HUF IDR ILS INR IQD IRR ISK JMD JOD JPY KES KGS KHR KMF KPW KRW "
        + "KWD KYD KZT LAK LBP LKR LRD LSL LYD MAD MDL MGA MKD MMK MNT MOP MRU MUR MVR MWK MXN MYR MZN NAD NGN NIO NOK "
        + "NPR NZD OMR PAB PEN PGK PHP PKR PLN PYG QAR RON RSD RUB RWF SAR SBD SCR SDG SEK SGD SHP SLE SLL SOS SRD SSP "
        + "STN SVC SYP SZL THB TJS TMT TND TOP TRY TTD TWD TZS UAH UGX USD UYU UZS VED VES VND VUV WST XAF XCD XCG XOF "
        + "XPF YER ZAR ZMW ZWG ZWL").split(separator: " ").map(String.init)

    /// The English names of the currencies whose codes are most used, and
    /// their plurals: an amount is written with them as with a code (Codex
    /// review 1 of I-09, P1-3) — "49.99 dollars", "Dollars 49".
    static let currencyNames: [String] = [
        "dollar", "dollars", "euro", "euros", "sterling", "yen", "yuan", "renminbi", "rupee", "rupees", "ruble", "rubles",
        "rouble", "roubles", "franc", "francs", "krona", "kronor", "krone", "kroner", "zloty", "zlotys", "reais", "peso",
        "pesos", "lira", "lire", "shekel", "shekels", "dirham", "dirhams", "riyal", "riyals", "ringgit", "baht",
        "hryvnia", "forint", "koruna",
    ]
    /// Currency names that are everyday words too — "you won 3 games",
    /// "Rand 2", "real 5 stars", "pound 3 nails in": an amount only after its
    /// number ("500 won", "1 200 rand", "3 real", "50 pounds").
    static let currencyNamesAfterANumber: [String] = ["pound", "pounds", "real", "rand", "won", "dong", "lei", "leu"]

    /// A money amount (owner decision 6; review of A3d, round 2, P1-7): a
    /// currency sign, one of `currencyCodes` standing as a word, or one of
    /// `currencyNames` standing as a word in any case, beside a number — in
    /// any script; one of `currencyNamesAfterANumber` only right after one.
    /// The one expression the observer runs in a page (`ObserverScript`) and
    /// `showsAmount(in:)` runs here. Each name's letters are spelled in both
    /// cases: no flag is needed where it runs.
    static let amountPattern: String = {
        let anyCase = { (names: [String]) in
            names.map { $0.map { "[\($0.lowercased())\($0.uppercased())]" }.joined() }.joined(separator: "|")
        }
        let code = "(?<![A-Za-z])(?:" + currencyCodes.joined(separator: "|") + ")(?![A-Za-z])"
        let name = "(?<!\\p{L})(?:" + anyCase(currencyNames) + ")(?!\\p{L})"
        let everyday = "(?<!\\p{L})(?:" + anyCase(currencyNamesAfterANumber) + ")(?!\\p{L})"
        let currency = "(?:\\p{Sc}|" + code + "|" + name + ")"
        return currency + "\\s?\\p{Nd}|\\p{Nd}\\s?(?:" + currency + "|" + everyday + ")"
    }()

    /// What a page may put inside a word or a number to hide it — zero-width
    /// spaces and joiners, a word joiner, a byte-order mark, a soft hyphen —
    /// as the body of a character class: read as nothing, by the observer
    /// (`normalizeSecrets`) and by `showsAmount(in:)`.
    static let invisibleMarks = "\\u200B-\\u200D\\u2060\\uFEFF\\u00AD"

    private static let amount = try? NSRegularExpression(pattern: amountPattern)

    /// Whether `text` shows a money amount, read as the observer reads a
    /// page: compatibility forms as what they stand for, the invisible marks
    /// as nothing.
    static func showsAmount(in text: String) -> Bool {
        let plain = plain(text)
        return amount?.firstMatch(in: plain, range: NSRange(plain.startIndex..., in: plain)) != nil
    }

    /// `text` as the observer reads a page (`normalizeSecrets`):
    /// compatibility forms as what they stand for, the invisible marks as
    /// nothing.
    static func plain(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping
            .replacingOccurrences(of: "[" + invisibleMarks + "]", with: "", options: .regularExpression)
    }

    /// What a page's own confirm, prompt or "Leave the page?" asks for that
    /// is the user's part (review of I-09, F4) — read where the dialog opens,
    /// and kept nowhere: a grant, by a grant word anywhere inside a word —
    /// "preauthorize", "permissions", "access" — or by a form of giving or
    /// sharing with someone. Nil for anything else — a payment among it: a
    /// payment is a page that asks card details (owner decision of
    /// 2026-10-19), which no dialog's words are; a charge or a price in them
    /// is Cancel by the rules every confirm has, bound to the approved act or
    /// not. A dialog that names a grant is Cancel whatever the Yes, so a word
    /// as often about something else — "shallow" — costs a Cancel (Codex
    /// review 2 of I-09, P1-3; Claude review c8, #10, #22; decision 8 of
    /// review round 4: Codex review 3, P1-3, Claude review c9, #12). Cookies
    /// alone are no grant, as for a label.
    static func dialogAsks(_ message: String) -> ErrandHandover.Kind? {
        let found = words(in: plain(decoded(message)))
        let holds = { (stems: [String]) in found.contains { word in stems.contains(where: word.contains) } }
        let isCookieWord = { (word: String) in word.hasPrefix("cookie") }
        let aboutCookiesOnly = found.contains(where: isCookieWord)
            && found.allSatisfy { isCookieWord($0) || cookieConsentWords.contains($0) }
        let grants = holds(englishDialogGrantStems) && !aboutCookiesOnly
        return grants || asksGrantInOtherWords(found) ? .grant : nil
    }
    /// What a page's own dialog grants by, anywhere inside a word —
    /// "allowing", "granted", "preauthorize", "reauthorizing", "permissions",
    /// "access" (Claude review c8 of I-09, #10; decision 8 of review round 4).
    static let englishDialogGrantStems = ["access", "permission", "authoriz", "authoris", "grant", "allow"]

    /// Grants a page's own dialog asks for in other words, in English:
    /// giving someone access or permission, sharing something with someone —
    /// in any form of give or share, the second word anywhere after the
    /// first (Claude review of I-09, kept 1; Codex review 3, P1-3). A dialog
    /// under a Yes has no grant answer of Jev's beside its words; a control's
    /// label that says so — "Share with someone" — is asked about, and handed
    /// over on that answer (review of A3, round 1).
    static let grantPhraseForms: Set<String> = ["give", "gives", "giving", "gave", "given",
                                                "share", "shares", "sharing", "shared"]
    static let grantPhraseObjects: Set<String> = ["access", "permission", "with"]

    private static func asksGrantInOtherWords(_ found: [String]) -> Bool {
        found.firstIndex(where: grantPhraseForms.contains)
            .map { found[$0...].dropFirst().contains(where: grantPhraseObjects.contains) } ?? false
    }

    /// How the agent answers a page's own dialog (Codex review 1 of I-09,
    /// P1-3) — read where it opens, kept nowhere. An alert is closed. A
    /// confirm, a prompt or "Leave the page?" whose words name a payment or a
    /// grant is Cancel, or Stay, whatever the Yes, and says which it named. A
    /// prompt is Cancel: the agent has no words to give it. One that shows a
    /// number the approved control does not show is Cancel, or Stay: in any
    /// language, a price in letters no amount rule reads among them (Claude
    /// review c8 of I-09, #9). "Leave the page?" is Leave under the step's
    /// own Yes, else Stay. A confirm is OK under the step's own Yes only when
    /// it is bound to the act the Yes was for — by the act's own word, or
    /// nothing but a bare confirmation (`bound`). Anything else is Cancel:
    /// what is not recognised is never taken as safe to accept. `act`: the
    /// act the step has the user's Yes for, not yet answered for; nil, none.
    static func answer(_ kind: PageDialog, saying message: String,
                       under act: ApprovedAct?) -> (accept: Bool, named: ErrandHandover.Kind?) {
        switch kind {
        case .alert:
            return (true, nil)
        case .confirm, .prompt, .beforeunload:
            if let named = dialogAsks(message) { return (false, named) }
            guard let act, kind != .prompt,
                  numbers(in: message).isSubset(of: act.words.reduce(into: Set<String>()) { $0.formUnion(numbers(in: $1)) })
            else { return (false, nil) }
            return (kind == .beforeunload || bound(message, to: act), nil)
        }
    }

    /// The numbers `text` shows, read as the observer reads a page: each run
    /// of decimal digits, in any script, as the values of its digits — "299"
    /// in Latin, Arabic-Indic or full-width digits is one number.
    static func numbers(in text: String) -> Set<String> {
        var found: Set<String> = [], run = ""
        for character in plain(text) {
            if let digit = character.wholeNumberValue,
               character.unicodeScalars.allSatisfy({ $0.properties.numericType == .decimal }) {
                run += String(digit)
            } else if !run.isEmpty {
                found.insert(run)
                run = ""
            }
        }
        if !run.isEmpty { found.insert(run) }
        return found
    }

    /// The words of a bare confirmation, in English: a confirm made of them
    /// alone asks for nothing but the act it follows (Codex review 1 of
    /// I-09, P1-3). "can't" reads "can" and "t".
    static let bareConfirmationWords: Set<String> = [
        "are", "you", "sure", "do", "really", "want", "to", "continue", "this", "it", "cannot", "can", "not", "t", "be",
        "undone", "confirm", "proceed", "please", "ok", "okay", "action",
    ]

    /// English words of three letters or more that every sentence has: they
    /// bind a dialog to no act.
    static let englishFunctionWords: Set<String> = [
        "the", "and", "for", "with", "your", "that", "will", "from", "have", "has", "was", "were", "all", "now", "its",
        "our", "any", "into", "than", "then", "there", "these", "those", "them", "they", "what", "when", "which", "who",
        "also", "but", "yes",
    ]

    /// English words after which a word names a thing, not an act: "this
    /// post", "the order", "your share".
    static let englishDeterminers: Set<String> = [
        "a", "an", "the", "this", "that", "these", "those", "my", "your", "our", "their", "his", "her", "its", "each",
        "every", "any", "no",
    ]

    /// Whether a confirm is bound to `act` by the act's own word (Claude
    /// review c8 of I-09, #11), read sentence by sentence (decision 9 of
    /// review round 4; Claude review c9, #11). The acts a text names are the
    /// words of the policy's whole lexicon — the action words, the words of
    /// leaving or undoing (`englishBindingActWords`) — each where it names an
    /// act: not a confirmation's own "confirm", and not a word that names a
    /// thing right after "this", "the" or "your" in its own sentence. A
    /// confirm that names an act the approved control's words do not name is
    /// bound to nothing. Then it is bound when every one of its words is a
    /// bare confirmation's; when the control's words name an act, only by
    /// naming that act too — an object word shared alone, or the act's word
    /// used as a thing, binds nothing; and otherwise — in any other language
    /// — when it shares a content word with them: three letters or more,
    /// case-folded, in any script, and neither a word every sentence has nor
    /// a confirmation's own.
    private static func bound(_ message: String, to act: ApprovedAct) -> Bool {
        let sentences = foldedSentences(message)
        let said = sentences.flatMap { $0 }
        guard !said.isEmpty else { return false }
        let controlSentences = act.words.flatMap(foldedSentences)
        let approved = Set(controlSentences.flatMap { $0 })
        let own = Set(controlSentences.flatMap(actsNamed(in:)))
        let named = sentences.flatMap(actsNamed(in:))
        guard named.allSatisfy(own.contains) else { return false }
        if said.allSatisfy(bareConfirmationWords.contains) { return true }
        if !own.isEmpty { return !named.isEmpty }
        let isContent = { (word: String) in
            word.count >= 3 && !bareConfirmationWords.contains(word) && !englishFunctionWords.contains(word)
        }
        return said.contains { isContent($0) && approved.contains($0) }
    }

    /// The words a confirm names an act by: the policy's whole lexicon — the
    /// action words, the words of leaving or undoing, and the acts a page's
    /// own dialog asks for in their place ("archive", "reject", "decline") —
    /// "log out" and "sign out" read as "logout" and "signout" (decision 9 of
    /// review round 4).
    static let englishBindingActWords: Set<String> = englishActionWords.union(englishNavigationActionWords)
        .union(["cancel", "unsubscribe", "approve", "reject", "decline", "remove", "archive", "send", "publish", "post",
                "submit"])
        .subtracting(bareConfirmationWords)

    /// The acts `sentence` names, each where it names one: an act word of
    /// `englishBindingActWords` — or "log out", "sign out" — not right after
    /// a determiner of the same sentence.
    private static func actsNamed(in sentence: [String]) -> [String] {
        sentence.indices.compactMap { index in
            guard index == 0 || !englishDeterminers.contains(sentence[index - 1]) else { return nil }
            let word = sentence[index]
            if index + 1 < sentence.count,
               englishNavigationActionPairs.contains(where: { $0.0 == word && $0.1 == sentence[index + 1] }) {
                return word + sentence[index + 1]
            }
            return englishBindingActWords.contains(word) ? word : nil
        }
    }

    /// The sentences of `text` — split at ".", "?" and "!" — each as its
    /// words, read as the observer reads a page and folded as case is
    /// folded in any script; an empty one left out.
    private static func foldedSentences(_ text: String) -> [[String]] {
        plain(text).split(whereSeparator: { ".?!".contains($0) }).map { sentence in
            words(in: String(sentence)).map { $0.folding(options: .caseInsensitive, locale: nil) }
        }.filter { !$0.isEmpty }
    }

    /// OAuth in an address, whatever the words around it: a client that asks
    /// to be sent back somewhere, or a pushed request (ITER-076 2.1). Read as
    /// decoded text, not parsed, so a wrapped link or a query no parser
    /// accepts is still caught.
    static func hasOAuthMarkers(_ address: String) -> Bool {
        oauthReadings(of: address).contains { text in
            text.contains("client_id=") && ["redirect_uri=", "response_type=", "request_uri="].contains(where: text.contains)
        }
    }

    /// An address as OAuth marks are read in it: decoded, and also with only
    /// the escapes that matter undone — one malformed escape elsewhere makes
    /// full decoding give up, and a link can be wrapped twice.
    private static func oauthReadings(of address: String) -> [String] {
        var loose = address.lowercased()
        for _ in 0..<2 { loose = loose.replacingOccurrences(of: "%25", with: "%") }
        loose = loose.replacingOccurrences(of: "%3d", with: "=").replacingOccurrences(of: "%5f", with: "_")
            .replacingOccurrences(of: "%26", with: "&")
        return [decoded(address).lowercased(), loose]
    }

    /// An address an identity provider signs people in at (review of I-09,
    /// F6): one that names an OAuth client, read as `hasOAuthMarkers` reads
    /// one, or one of a short list of identity providers' own — Google's,
    /// Apple's and Microsoft's sign-in hosts, Facebook's dialogs, GitHub's
    /// OAuth pages. A frame from another site there is a sign-in, with or
    /// without a password field in it.
    static func signsIn(at address: String) -> Bool {
        if oauthReadings(of: address).contains(where: { $0.contains("client_id=") }) { return true }
        guard let url = URL(string: address), var host = url.host?.lowercased() else { return false }
        if host.hasSuffix(".") { host.removeLast() }
        let path = url.path.lowercased()
        switch host {
        case "accounts.google.com", "appleid.apple.com", "login.microsoftonline.com", "login.live.com": return true
        case "www.facebook.com": return path.contains("/dialog/")
        case "github.com": return path.hasPrefix("/login/oauth")
        default: return false
        }
    }

    /// A CAPTCHA provider's own widget, by the address of the frame it is
    /// drawn in (ITER-076 stage 3, № 71): solving one is the user's part
    /// (owner decision 6), told by structure alone, no model asked. The
    /// frames each provider's own documentation names (read 2026-10-06):
    /// reCAPTCHA's under `/recaptcha/` at `www.google.com`,
    /// `recaptcha.google.com` and `www.recaptcha.net` (its FAQ: CSP
    /// `frame-src`, and the host for where google.com is not reachable);
    /// hCaptcha's at `hcaptcha.com` and any host under it (its CSP settings);
    /// Cloudflare Turnstile's and its challenges' at
    /// `challenges.cloudflare.com` (Turnstile's CSP reference).
    static func isCaptchaWidget(_ address: String) -> Bool {
        guard let url = URL(string: address), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              var host = url.host?.lowercased() else { return false }
        if host.hasSuffix(".") { host.removeLast() }
        switch host {
        case "www.google.com", "recaptcha.google.com", "www.recaptcha.net": return url.path.hasPrefix("/recaptcha/")
        case "challenges.cloudflare.com", "hcaptcha.com": return true
        default: return host.hasSuffix(".hcaptcha.com")
        }
    }

    // MARK: - Private

    /// Lowercased words, split on anything that is not a letter, with
    /// camelCase and acronyms broken apart first ("deleteAccount",
    /// "DELETEAccount" → "delete", "account").
    static func words(in text: String) -> [String] {
        let characters = Array(text)
        var spaced = ""
        for (index, character) in characters.enumerated() {
            if index > 0 {
                let previous = characters[index - 1]
                let next: Character? = index + 1 < characters.count ? characters[index + 1] : nil
                let lowerToUpper = previous.isLowercase && character.isUppercase
                let acronymEnds = previous.isUppercase && character.isUppercase && (next?.isLowercase ?? false)
                if lowerToUpper || acronymEnds { spaced.append(" ") }
            }
            spaced.append(character)
        }
        return spaced.lowercased().split { !$0.isLetter }.map(String.init)
    }

    /// Percent-decoded, with "+" read as a space as in a query string.
    static func decoded(_ text: String) -> String {
        let spaced = text.replacingOccurrences(of: "+", with: " ")
        return spaced.removingPercentEncoding ?? spaced
    }

    /// A select's chosen option is what the action does (ITER-076 2.2, S2),
    /// read by the lexicon only: a grant word in an option ("Grant" in a
    /// funding filter) asks for a Yes rather than handing the errand over.
    /// Typed text is not read: it is the user's own words.
    private static func chosenOption(of action: AgentAction) -> String? {
        action.operation == .select ? action.payload : nil
    }

    private static func sameOrigin(_ a: URL, _ b: URL) -> Bool {
        a.scheme?.lowercased() == b.scheme?.lowercased() && a.host?.lowercased() == b.host?.lowercased()
            && a.port == b.port
    }

    private static func containsNavigationActionWord(_ text: String) -> Bool {
        let tokens = words(in: text)
        if tokens.contains(where: { englishNavigationActionWords.contains($0) }) { return true }
        for (first, second) in englishNavigationActionPairs {
            for index in tokens.indices.dropLast() where tokens[index] == first && tokens[index + 1] == second {
                return true
            }
        }
        return false
    }
}

/// What the agent does with a cookie banner (§7.2).
enum CookieChoice: Equatable {
    case rejectAll, necessaryOnly, close, accept
}

/// Cookie banners never interrupt the user (§7.2, decision 15).
enum CookieBanner {
    /// The word that names cookies in a banner's text, in any language a
    /// banner is written in: the eyes read a box fixed to the viewport that
    /// holds it as the page's cookie window (2026-10-19), and `isRecognised`
    /// asks for it.
    static let word = "cookie"

    /// A cookie window a page shows: every layer of it the page draws, read as one — its first layer, and its
    /// settings when they are open, which a consent platform keeps drawn over its first layer (blind task b08,
    /// 2026-10-21). `least`: the control the agent presses next there, with no Yes and no model asked, or none —
    /// the least consent itself, or the way to it (`way`); `free`: every control it may press there now with no
    /// Yes — `least`, and every other switch it may turn off; `controls`: the window's own controls, every one;
    /// and whether the window blocks the page — a dialog does, a bar fixed to the viewport does not
    /// (2026-10-19). One that blocks the page and offers nothing to press is the user's part; one that does not is
    /// read past, its accept decided as any control when the agent goes for it.
    struct Window: Equatable {
        /// What pressing `least` does (2026-10-21).
        enum Way: Equatable {
            /// It gives the least consent: reject all, necessary only, a settings layer's save with only necessary
            /// switches on, close.
            case consent
            /// It turns off a switch that gives a consent — a consent taken away — before the save.
            case turnOff
            /// It opens the window's settings, where the least consent is, when the first layer offers none.
            case settings
        }
        let least: ObservedElement?
        var blocksPage = true
        var way: Way = .consent
        var controls: [ObservedElement] = []
        var free: [ObservedElement] = []

        /// Whether `control`, of the look the window was read from, is one of the window's.
        func holds(_ control: ObservedElement) -> Bool { controls.contains { $0.index == control.index } }
        /// Whether the agent may press `control`, of the look the window was read from, with no Yes.
        func frees(_ control: ObservedElement) -> Bool { free.contains { $0.index == control.index } }
    }

    /// The roles a cookie window is read by: what a person presses, and the switches that give a consent.
    static let pressRoles: Set<String> = ["button", "link"]
    static let switchRoles: Set<String> = ["checkbox", "switch"]

    /// The cookie window a page shows (ITER-076 stage 3, № 98), in any of its documents: every dialog whose own
    /// words and buttons make it one (`isRecognised`), each a layer of it — and the control there the agent
    /// presses next, the first of (2026-10-21): reject all, necessary only, a save in a layer of switches whose
    /// every switch that may be on is a necessary one, a switch that is on and not necessary in a layer with a save
    /// (to turn off), close — then, while no other layer of switches is open, a control that opens the settings; or
    /// none: the accept is never the agent's to give. A control that shows or hides a part of the window — a
    /// category's header, drawn as a button over it — is no choice, whatever its words. Nil when the page shows
    /// none.
    static func window(on page: ObservedPage) -> Window? {
        var dialogs: [(frame: String?, words: String, controls: [ObservedElement])] = []
        for element in page.elements where element.region == .dialog {
            guard let words = element.dialogText else { continue }
            if let at = dialogs.firstIndex(where: { $0.frame == element.frame && $0.words == words }) {
                dialogs[at].controls.append(element)
            } else {
                dialogs.append((element.frame, words, [element]))
            }
        }
        let layers = dialogs.filter { dialog in
            isRecognised(text: dialog.words,
                         buttonLabels: dialog.controls.filter { pressRoles.contains($0.role) }.map(\.name))
        }.map(\.controls)
        guard !layers.isEmpty else { return nil }
        let switched = layers.map { $0.contains { switchRoles.contains($0.role) } }
        var rejecting: [ObservedElement] = [], necessary: [ObservedElement] = [], saving: [ObservedElement] = []
        var turningOff: [ObservedElement] = [], closing: [ObservedElement] = [], opening: [ObservedElement] = []
        for (place, layer) in layers.enumerated() {
            let switches = layer.filter { switchRoles.contains($0.role) }
            let settingsOpen = switched.indices.contains { $0 != place && switched[$0] }
            var save: ObservedElement?
            for control in layer where pressRoles.contains(control.role) {
                switch control.expanded == nil ? classify(control.name) : nil {
                case .rejectAll?: rejecting.append(control)
                case .necessaryOnly?: necessary.append(control)
                case .close?: closing.append(control)
                case .accept?: break
                case nil:
                    if save == nil, !switches.isEmpty, control.expanded == nil, saves(control.name) {
                        save = control
                    } else if !settingsOpen, opensSettings(control.name) {
                        opening.append(control)
                    }
                }
            }
            guard let save else { continue }
            // A switch whose state is not known may be on: the save waits for it, and it is never turned.
            let mayBeOn = switches.filter { $0.checked != false && !isNecessary($0) }
            if mayBeOn.isEmpty { saving.append(save) } else { turningOff += mayBeOn.filter { $0.checked == true } }
        }
        let ways: [(control: ObservedElement, way: Window.Way)] = (rejecting + necessary + saving).map { ($0, .consent) }
            + turningOff.map { ($0, .turnOff) } + closing.map { ($0, .consent) } + opening.map { ($0, .settings) }
        let next = ways.first
        let free = next.map { next in [next.control] + turningOff.filter { $0.index != next.control.index } } ?? []
        return Window(least: next?.control, blocksPage: layers.contains { $0.contains { $0.dialogBlocks != false } },
                      way: next?.way ?? .consent, controls: layers.flatMap { $0 }, free: free)
    }

    /// The words a control that opens a cookie window's settings is named by, in English (2026-10-21): one of
    /// `settingsWords`, and around it nothing but cookie words and `settingsAround` — "Cookies settings", "Manage
    /// preferences", "More options", "Customise". A consent label is read first (`classify`).
    static let settingsWords: Set<String> = ["settings", "setting", "preferences", "preference", "options", "option",
                                             "customize", "customise", "manage"]
    static let settingsAround: Set<String> = ["more", "my", "your", "the", "and", "change", "show", "view", "set",
                                              "edit", "adjust", "privacy", "consent"]

    static func opensSettings(_ label: String) -> Bool {
        let found = SafetyGuard.words(in: SafetyGuard.plain(label))
        return found.contains(where: settingsWords.contains)
            && found.allSatisfy { settingsWords.contains($0) || settingsAround.contains($0) || $0.hasPrefix(word) }
    }

    /// The words a settings layer's save is named by, in English (2026-10-21): one of `saveWords`, and around it
    /// nothing but cookie words and `saveAround` — "Confirm my choices", "Save preferences", "Save and close". One
    /// that accepts or allows too is no save: "Save and accept all".
    static let saveWords: Set<String> = ["save", "confirm"]
    static let saveAround: Set<String> = ["my", "your", "the", "and", "close", "exit", "choices", "choice",
                                          "preferences", "preference", "settings", "setting", "selection", "consent"]

    static func saves(_ label: String) -> Bool {
        let found = SafetyGuard.words(in: SafetyGuard.plain(label))
        return found.contains(where: saveWords.contains)
            && found.allSatisfy { saveWords.contains($0) || saveAround.contains($0) || $0.hasPrefix(word) }
    }

    /// A necessary switch (2026-10-21): one a person cannot change (`disabled`), or one named by a word of
    /// `necessaryWords` that no "non" or "not" right before it turns around — "Strictly Necessary Cookies",
    /// "Essential"; never "Non-essential cookies", "Not required" or "Unnecessary".
    static let necessaryWords: Set<String> = ["necessary", "essential", "strictly", "required"]

    static func isNecessary(_ control: ObservedElement) -> Bool {
        if control.disabled == true { return true }
        let found = SafetyGuard.words(in: SafetyGuard.plain(control.name))
        return found.indices.contains { at in
            necessaryWords.contains(found[at]) && (at == 0 || !["non", "not"].contains(found[at - 1]))
        }
    }

    /// Words that make a dialog about access to an account, an app or
    /// anything of the user's — a grant, never a cookie banner, even when it
    /// mentions cookies (§7.2). A bare "access" is not one of them: the
    /// standard cookie wording is "store and/or access information on a
    /// device".
    static let grantWordsInText = ["your account", "this app", "access your", "access to your", "authoriz",
                                   "authoris", "permission", "sign in", "log in"]
    static let grantWordsInButtons = ["access", "authoriz", "authoris", "sign in", "log in"]

    /// A banner is a cookie banner only when its text mentions cookies, it
    /// asks for no access to an account, an app or anything of the user's,
    /// and at least one of its buttons carries a consent label.
    static func isRecognised(text: String, buttonLabels: [String]) -> Bool {
        let lowered = text.lowercased()
        guard lowered.contains(word) else { return false }
        guard !grantWordsInText.contains(where: lowered.contains) else { return false }
        let labels = buttonLabels.map { $0.lowercased() }
        guard !labels.contains(where: { label in grantWordsInButtons.contains(where: label.contains) }) else {
            return false
        }
        return buttonLabels.contains { classify($0) != nil }
    }

    /// The least permissive option present: reject all, then necessary only,
    /// then close. Accept — the one choice that grants something — only when
    /// the banner blocks the page, offers nothing else, and the button says
    /// it accepts cookies: a bare «Accept» may sit on a dialog that asks for
    /// more. Nil means the agent does not touch the banner.
    static func choice(buttonLabels: [String], blocksPage: Bool) -> (index: Int, choice: CookieChoice)? {
        let classified = buttonLabels.enumerated().compactMap { index, label in
            classify(label).map { (index: index, choice: $0) }
        }
        for preferred in [CookieChoice.rejectAll, .necessaryOnly, .close] {
            if let match = classified.first(where: { $0.choice == preferred }) { return match }
        }
        guard blocksPage else { return nil }
        return classified.first { $0.choice == .accept && namesCookies(buttonLabels[$0.index]) }
    }

    /// Reject is checked first — including a consent word under a negation,
    /// "I do not accept" — then necessary-only (unless the label widens it:
    /// "Accept non-essential" is an accept), then close, then accept.
    ///
    /// "Allow" is how a permission is granted. In a cookie banner it says
    /// what it allows — "Allow all", "Allow cookies"; bare, it is a grant and
    /// never a cookie accept.
    static func classify(_ label: String) -> CookieChoice? {
        let text = label.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let consent = ["accept", "agree", "got it"]
        let grant = ["allow"]
        let negations = ["not ", "don't", "don’t", "dont ", "no,"]
        let agrees = consent.contains(where: text.contains)
        let grants = grant.contains(where: text.contains)
        if ["reject", "decline", "deny", "refuse"].contains(where: text.contains) {
            return .rejectAll
        }
        if (agrees || grants) && negations.contains(where: text.contains) {
            return .rejectAll
        }
        let widening = ["non-essential", "non essential", "nonessential", "optional", " all"]
        if ["necessary", "essential", "required"].contains(where: text.contains),
           !widening.contains(where: text.contains) {
            return .necessaryOnly
        }
        if ["×", "x", "✕", "close", "dismiss"].contains(text) { return .close }
        let namesItsScope = namesCookies(text) || SafetyGuard.words(in: text).contains { $0 == "all" }
        if agrees || text == "ok" || (grants && namesItsScope) { return .accept }
        return nil
    }

    private static func namesCookies(_ label: String) -> Bool {
        SafetyGuard.words(in: label).contains { $0.hasPrefix(word) }
    }
}

/// A question to the user about one irreversible action (§7.1).
struct ConfirmationRequest: Equatable {
    enum Answer: Equatable { case yes, no }
    enum Outcome: Equatable { case waiting, approved, refused }

    /// No answer within two minutes is a No (§7.1).
    static let answerWindow: TimeInterval = 120

    let action: AgentAction
    /// The tab and the full page address the question was asked on.
    let tab: BrowserTab
    let pageURL: String
    /// On the continuous clock: setting the wall clock back cannot stretch
    /// the window, and time asleep counts.
    let askedAt: ContinuousClock.Instant
    /// A form's question (ITER-076 stage 7): its preview, Fill — one consent
    /// to type every value it shows — or its Send, bound to the values it
    /// shows. Nil for a question about one action.
    var form: FormQuestion? = nil

    /// How long the question waits for an answer: the answer window — but a
    /// form's preview, which has no timer and waits for the user (decision
    /// 7.4, 2026-10-06); the errand's own expiry ends that wait.
    var window: TimeInterval? { form?.kind == .fill ? nil : Self.answerWindow }

    /// The user's answer counts only if it came after the question, no later
    /// than now, and inside the window; silence past the window is a No.
    /// Waiting ends there, whatever happens. A question with no window waits.
    func outcome(answer: Answer?, answeredAt: ContinuousClock.Instant?, now: ContinuousClock.Instant) -> Outcome {
        let window = self.window.map { Duration.seconds($0) }
        if let answer, let answeredAt, answeredAt >= askedAt, answeredAt <= now,
           window.map({ answeredAt - askedAt < $0 }) ?? true {
            return answer == .yes ? .approved : .refused
        }
        guard let window else { return .waiting }
        return now - askedAt >= window ? .refused : .waiting
    }

    /// A Yes holds for the exact action, in the same tab, on the same page:
    /// the same operation, the same target (its fingerprint includes the
    /// form's destination and method) with the same visible words and submit
    /// label — "Pay $10" turning into "Pay $100" voids it — and the same
    /// destination and payload.
    func stillHolds(for candidate: AgentAction, tab: BrowserTab, pageURL: String) -> Bool {
        lapse(for: candidate, tab: tab, pageURL: pageURL) == nil
    }

    /// What no longer holds, by name — never by value, which is the page's text — or nil while the Yes holds
    /// (2026-10-21: on a blind task 19 of 21 Yes answers lapsed and nothing on record said why).
    func lapse(for candidate: AgentAction, tab: BrowserTab, pageURL: String) -> String? {
        if tab != self.tab { return "tab" }
        if pageURL != self.pageURL { return "page address" }
        if candidate.operation != action.operation { return "operation" }
        if candidate.target?.fingerprint != action.target?.fingerprint { return "target" }
        if candidate.target?.text != action.target?.text { return "words" }
        if candidate.target?.formSubmitLabel != action.target?.formSubmitLabel { return "submit label" }
        if candidate.destination != action.destination { return "destination" }
        if candidate.payload != action.payload { return "payload" }
        return nil
    }
}
