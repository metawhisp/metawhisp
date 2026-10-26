import CryptoKit
import Foundation

/// Where on the page an element sits (ITER-074 §6.1). Candidates prefer the
/// main content over page chrome (§6.2).
enum PageRegion: String, Decodable, Equatable {
    case main, header, nav, footer, aside, dialog, other
}

/// One element a person could act on, as the observer script reports it
/// (ITER-074 §6.1). The page's text is data in these fields and nothing else.
struct ObservedElement: Decodable, Equatable {
    /// Its place in the report; in a page with frames, renumbered so that no
    /// two of the page's controls share one (`ObservedPage.merging`).
    var index: Int
    /// Its private key in the page, the same for the document's life whatever
    /// the page redraws: what the hands tell a target by that turned into a
    /// secret field (review of I-02, N3-P2-2). No part of its identity, and
    /// read by the app's hands only; nil in a report made by hand.
    var key: Int? = nil
    let role: String
    /// Its words — name, text, heading, row, submit label, options, value —
    /// as its own document reported them: as a person reads them (owner
    /// decision of 2026-10-03).
    var name: String
    var text: String
    let href: String?
    let inputType: String?
    var heading: String?
    let region: PageRegion
    let inViewport: Bool
    /// The text of the row the element sits in (a list item, a table row),
    /// without the element's own text — "Home" for the "Remove" button in the
    /// Home row. Part of the element's identity (§6.3).
    var context: String?
    /// For a form control: where its form sends, how, and what its submit
    /// button says — what the risk check needs (§6.3, §7.1).
    let formAction: String?
    let formMethod: String?
    var formSubmitLabel: String?
    /// Its form — or, for an option of a made-up dropdown, that dropdown's —
    /// has submit buttons, and none a person can press: no button sends what
    /// it sets (round 5, Claude review c10, #15; Claude review c11, #11).
    /// Read only where what sends a form is decided (`SafetyGuard`); nil in a
    /// report made by hand.
    var submitUnpressable: Bool? = nil
    /// For a select: its listed options, as a person reads them. The option it shows
    /// is its `value`; whether what the agent wrote or chose is held is
    /// checked in the page (`ActionScript.holds`).
    var options: [String]?
    /// For a select: beside each listed option, its key — a digest of its
    /// exact words and value. With the option's place, what the hands find it by again
    /// (review of A3d, round 2, P2-2; review of I-02, N3-P2-1). Read by the
    /// app's hands only.
    var optionKeys: [String?]? = nil
    /// For a checkbox, radio or switch: whether it is on.
    let checked: Bool?
    /// For a checkbox, radio or switch: a person cannot change it —
    /// `disabled`, itself or by its fieldset, `aria-disabled` on it or around
    /// it, or inside an inert box — what tells a cookie window's necessary
    /// switch (2026-10-21). Nil for any other control, and in a report made
    /// by hand.
    var disabled: Bool? = nil
    /// Clicking it sends its form: a submit button in a form (ITER-076 2.1).
    /// Structure the risk check reads in any language.
    var submits: Bool? = nil
    /// Its form carries an OAuth request in its fields, hidden ones
    /// included: sending it grants access, whatever the button says.
    var formGrants: Bool? = nil
    /// What an ordinary field holds (owner decision 4, 2026-09-29): a text
    /// field's value, a select's chosen option, an editable region's words.
    /// Nil for a control that holds none. A secret field is never reported.
    var value: String? = nil
    /// Acting on it could send a secret field: its form could send one — a
    /// secret field in it holds something, typed in or filled by the browser;
    /// it holds a card's field, filled or not; or what it holds is not known,
    /// a frame of another origin inside it or more controls than a form is
    /// read to — or it is itself a field whose words name a sign-in or a
    /// payment; or it is a control outside any form on a page with a secret
    /// field outside any form, or with one filled in, in any form (review of
    /// A3d, round 2). An empty password sends none: the rest of its form is
    /// the errand's (2026-10-21). A link never does. Such a step is the user's
    /// part (owner decision 4).
    var touchesSecret: Bool = false
    /// Its form holds a secret field it needs, empty: one the form marks
    /// `required` or `aria-required`, or whose autocomplete names it the
    /// sign-in's own password, a new one or a code. Such a form sends no
    /// secret, so typing in it is the errand's; a press that sends it is the
    /// user's sign-in (`SafetyGuard.needsTheUsersSecret`, 2026-10-21). Read
    /// from the form's own fields; a link never has one. Nil in a report made
    /// by hand.
    var formNeedsSecret: Bool? = nil
    /// Its form, or the page region around it, shows a money amount: a
    /// currency sign or an ISO 4217 code beside a number, in any script. An
    /// irreversible step that commits there is a payment (owner decision 6;
    /// review of A3d, round 2, P1-7; review of I-02, N3-P1-6).
    var showsAmount: Bool = false
    /// Its form, or the page region around it, holds a frame of the page:
    /// what that frame shows is read with it — a total there makes its step a
    /// payment (Claude review of I-09, kept 3). Nil in a report made by hand.
    var holdsFrame: Bool? = nil
    /// It shows an amount only because a frame the look could not read may
    /// show one (`merging`): not known, not seen (2026-10-16). Set by the app,
    /// never read from a report.
    var amountUnknown: Bool? = nil
    /// A click opens it, and nothing is typed or chosen in it directly
    /// (ITER-076 I-08): a made-up dropdown — a combobox, or a list box that
    /// pops up as one, that is no native select and takes no typing — whose
    /// options come on the next look, or a read-only field (`readonly`,
    /// `aria-readonly`), whose click opens its picker. Nil in a report made
    /// by hand.
    var opens: Bool? = nil
    /// A field typing goes into — writable, a text field or a combobox that takes typing, as the hands write in
    /// (`aimToWrite`): its click is the click typing starts with (`SafetyGuard.editsOnly`, 2026-10-21). Nil for any
    /// other control, and in a report made by hand.
    var typedInto: Bool? = nil
    /// A control that shows or hides a part of the page (`aria-expanded`):
    /// whether that part is shown now — what tells a cookie window's category
    /// header, drawn as a button over it, from a choice (2026-10-21). Nil for
    /// any other control, and in a report made by hand.
    var expanded: Bool? = nil
    /// Clicking it sends its form, and that form asks for a file it does not
    /// hold yet: the step is the user's part, as a file from their disk is
    /// theirs to pick (ITER-076 I-08). Nil in a report made by hand.
    var needsFile: Bool? = nil
    /// For an option of a made-up dropdown: the index, in the same report,
    /// of that dropdown — the one whose list holds it — so the choice it
    /// makes is read back on the dropdown (ITER-076 I-08).
    var listOf: Int? = nil
    /// For an option of a made-up dropdown: who that dropdown is — a digest
    /// of its role, name, address, heading, row and form — the same on every
    /// look, so an option another dropdown's list now holds is another
    /// option. Part of its identity and its Yes (Codex review 1 of I-08,
    /// P1-2). An option whose dropdown has a twin is not reported (Codex
    /// review 2 of I-08, P1-2).
    var listOwner: String? = nil
    /// For an option of a made-up dropdown: that dropdown as a refusal reads
    /// a control — its role, name, row, addresses and form method, without
    /// the heading above it or the choice it shows — so a No holds while only
    /// the heading changes (Codex review 2 of I-08, P2-1). Its addresses come
    /// as the page has them: `AgentAction.effect` reads them as it reads every
    /// address (Codex review 3 of I-08, P2-1).
    var listOwnerEffect: ListOwner? = nil

    /// A made-up dropdown as a refusal of one of its options reads it.
    struct ListOwner: Codable, Hashable {
        let role: String?
        let name: String?
        let context: String?
        let href: String?
        let formAction: String?
        let formMethod: String?
    }
    /// For an option of a made-up dropdown in a form: the form that dropdown
    /// sends, kept apart from the one the page draws the option in. Both are
    /// judged, the stricter counts, and both are checked at the act (Codex
    /// review 1 of I-08, P1-3).
    var listForm: ListForm? = nil

    /// A dropdown's form, as an option of it carries it.
    struct ListForm: Codable, Equatable {
        let action: String?
        let method: String?
        let submitLabel: String?
        let grants: Bool?
    }
    /// The frame of the page it is in, by the browser's id for it — where
    /// its scripts run; nil for the page itself (ITER-076 I-09). Set by the
    /// app, never read from a report (`ObservedPage.merging`).
    var frame: String? = nil
    /// Who that frame is across looks — the same after a reload that gives
    /// it a new id (`BrowserFrame.identity`; review of I-09, F5). Part of the
    /// control's identity: the same control in frames of two holders or two
    /// origins is two controls; in frames of one origin side by side, twins
    /// (Claude review c7 of I-09, #4). Set by the app with `frame`, never
    /// read from a report.
    var frameIdentity: String? = nil
    /// For a control in a dialog: that dialog's own words as a person reads
    /// them, bounded — what tells a cookie window (ITER-076 stage 3, № 98).
    /// Read by the app only, never sent; nil outside a dialog.
    var dialogText: String? = nil
    /// For a control in a dialog: whether that dialog blocks the page — a
    /// `<dialog>`, a `role=dialog`, an `aria-modal` box — or is a bar fixed to
    /// the viewport that a person reads past (2026-10-19: a cookie notice with
    /// one "Got it" over an app). Nil outside a dialog, and in a report made
    /// by hand, where the rules take the dialog for blocking.
    var dialogBlocks: Bool? = nil
    /// For a field of a GET form: that form's own query as a browser writes
    /// it — its hidden fields as they are, in order, and the field's own
    /// place, with no value — what D4 builds its search's address from
    /// (ITER-076 stage 3). Read by the app only, never sent; nil for
    /// anything else, a form that cannot be read whole, or one that holds a
    /// secret field, empty or not: no pure search (2026-10-21).
    var formEntries: [FormEntry]? = nil
    /// It sits in the page's search landmark: `role=search`, or `<search>`.
    var inSearch: Bool? = nil
    /// A form as one whole (ITER-076 stage 7, № 69), read by the app only,
    /// never sent: for a field, its `autocomplete` as the page wrote it,
    /// lowercased — what the page's structure says it asks for — and whether
    /// it is required; nil for anything else, and in a report made by hand.
    var autocomplete: String? = nil
    var required: Bool? = nil
    /// For a field or a button: the group it is part of — its form, or, for
    /// fields a script gathers without one, the box that holds them — by that
    /// box's private key, the same for the document's life. Nil for none.
    var group: Int? = nil
    /// For a field that holds a value: a digest of exactly what it holds — to
    /// its last character and space, however long — by which a Yes is bound
    /// to the values the user saw (ITER-076 stage 7, № 93); for a list, of the
    /// value its chosen option sends, not its words (review round 1, C5).
    /// Never the value.
    var valueKey: String? = nil

    /// One name and value of a form's query; no value: the field's own place.
    struct FormEntry: Decodable, Equatable {
        let name: String
        let value: String?
    }
}

/// One frame of a page, as the agent read it (ITER-076 I-09): where it really
/// is and what it asks for.
struct ObservedFrame: Equatable {
    /// The browser's id for it: what its controls carry.
    let id: String
    let address: String
    let flags: PageFlags
}

/// What the page asks for that the agent must not touch (§7.2, §11).
struct PageFlags: Decodable, Equatable {
    /// A visible password or one-time-code field.
    let loginForm: Bool
    /// The page takes a payment: a visible card-number, expiry,
    /// security-code or other `cc-*` field, a saved card shown by its last
    /// digits, or a payment provider's own frame (owner decision 6).
    let paymentForm: Bool

    static let none = PageFlags(loginForm: false, paymentForm: false)
}

/// What one run of the observer script saw (ITER-074 §6.1).
struct ObservedPage: Decodable, Equatable {
    /// The frames a document holds, as the app reads it with them (Codex
    /// review 1 of I-09, P1-1; Claude review of I-09, kept 3): how many,
    /// whether any stands where a total shows, and what it names any it
    /// shows — a card's field, a sign-in's — by a label around it or its
    /// title (Claude review c11, #4).
    struct FrameOwners: Decodable, Equatable {
        let count: Int
        /// How many of them a person can see (2026-10-16).
        let shown: Int
        let besideAmount: Bool
        let named: PageFlags
    }

    /// The page's address as anyone but the app may see it — Jev, the writer,
    /// a source link: as the address bar shows it, with no user name or
    /// password, which a browser never shows (owner decision of 2026-10-03).
    var url: String
    var title: String
    /// The page had more than the observer may report; the rest is unseen.
    let truncated: Bool
    let flags: PageFlags
    var elements: [ObservedElement]
    /// The page's visible main text, at most 6,000 characters, without
    /// anything someone wrote or a secret field's content (ITER-076 A3a).
    var text: String = ""
    /// How far down the page is scrolled, in CSS pixels.
    var scrollY: Int = 0
    /// Where the tab really is, for the app's own checks — a Yes bound to its
    /// page, where a navigation landed, a consent page's marks. Never shown to
    /// anyone; nil only in a report made by hand.
    var address: String? = nil
    /// The frames read with the page, whose controls are among `elements`
    /// (ITER-076 I-09). Never read from a report.
    var frames: [ObservedFrame] = []
    /// `text` is the first part of a longer one: a limit of size or of time
    /// cut it (ITER-076 I-10).
    var textCut: Bool = false
    /// Where the tab's document was loaded from — the address its answer came
    /// from, which the page's own history calls never change (ITER-076 I-10).
    /// For the app's own checks, never shown; nil in a report made by hand.
    var loadedFrom: String? = nil
    /// What the document says of the frames it holds; nil in a report made
    /// by hand. Read by the app only, never shown.
    var frameOwners: FrameOwners? = nil
    /// The document shows a total anywhere: for a frame, what the controls
    /// around it are read with (Claude review of I-09, kept 3).
    var amountShown: Bool? = nil
    /// The document's own id, the same for its life (2026-10-21): what tells two looks at one document from a look at
    /// another one loaded from the same address. For the app's own checks, never shown; nil in a report made by hand.
    var documentID: String? = nil

    private enum CodingKeys: String, CodingKey {
        case url, title, truncated, flags, elements, text, scrollY, address, textCut, loadedFrom, frameOwners, amountShown,
             documentID
    }

    /// Where the tab really is: `address`, or `url` for a report made by hand.
    var liveAddress: String { address ?? url }
}

extension ObservedPage {
    /// A report as the observer writes it: every field it always carried is
    /// required; whether its text was cut, and where its document was loaded
    /// from, may be left out — a report made by hand carries neither
    /// (ITER-076 I-10); so may what it says of its frames (ITER-076 I-09).
    init(from decoder: any Decoder) throws {
        let report = try decoder.container(keyedBy: CodingKeys.self)
        self.init(url: try report.decode(String.self, forKey: .url),
                  title: try report.decode(String.self, forKey: .title),
                  truncated: try report.decode(Bool.self, forKey: .truncated),
                  flags: try report.decode(PageFlags.self, forKey: .flags),
                  elements: try report.decode([ObservedElement].self, forKey: .elements),
                  text: try report.decode(String.self, forKey: .text),
                  scrollY: try report.decode(Int.self, forKey: .scrollY),
                  address: try report.decodeIfPresent(String.self, forKey: .address),
                  textCut: try report.decodeIfPresent(Bool.self, forKey: .textCut) ?? false,
                  loadedFrom: try report.decodeIfPresent(String.self, forKey: .loadedFrom),
                  frameOwners: try report.decodeIfPresent(FrameOwners.self, forKey: .frameOwners),
                  amountShown: try report.decodeIfPresent(Bool.self, forKey: .amountShown))
        documentID = try report.decodeIfPresent(String.self, forKey: .documentID)
    }
}

/// Why an observer report was not accepted.
enum ObservationError: Error, Equatable {
    case tooLarge
}

/// An element's identity on one page: its fingerprint, which of the elements
/// sharing that fingerprint it is, and how many share it (ITER-074 §6.3).
struct ElementIdentity: Hashable {
    let fingerprint: String
    let occurrence: Int
    let total: Int
}

extension ObservedPage {
    /// The most the app will read from one observation. The script caps its
    /// own output well below this; a bigger report means the page tampered
    /// with it, and it is refused unread.
    static let maxReportBytes = 2_000_000

    /// Reads the observer script's JSON. Anything that is not a complete
    /// report is refused rather than half-read (ITER-074 §6.1).
    static func decode(_ json: String) throws -> ObservedPage {
        guard json.utf8.count <= maxReportBytes else { throw ObservationError.tooLarge }
        return try JSONDecoder().decode(ObservedPage.self, from: Data(json.utf8))
    }

    /// Which of the elements sharing this one's fingerprint it is, counted in
    /// document order.
    func identity(of element: ObservedElement) -> ElementIdentity {
        let fingerprint = element.fingerprint
        let twins = elements.filter { $0.fingerprint == fingerprint }
        let occurrence = twins.firstIndex { $0.index == element.index } ?? 0
        return ElementIdentity(fingerprint: fingerprint, occurrence: occurrence, total: twins.count)
    }

    /// Finds the element with this identity on a fresh observation (§6.3).
    /// Nothing matches when the number of elements sharing the fingerprint
    /// changed, or when the twins are not provably the same action. Twin
    /// links with a whole address go to the same place, so any of them will
    /// do; twin buttons may act on different rows, a link without an address
    /// may run any script, and an address at the report's length limit may
    /// have been cut — acting on the wrong one is worse than deciding again.
    func element(matching identity: ElementIdentity) -> ObservedElement? {
        let twins = elements.filter { $0.fingerprint == identity.fingerprint }
        guard twins.count == identity.total, identity.occurrence < twins.count else { return nil }
        let candidate = twins[identity.occurrence]
        guard twins.count == 1 || Self.twinsAreOneDestination(candidate) else { return nil }
        return candidate
    }

    /// `original` again on this fresh look: by its identity, as `element(matching:)` finds it — or, among twins that
    /// are not one destination, as the same node: the twin at its place carries its key, which the observer keeps for
    /// the document's life, and this look is of the document `earlier` was. A frame's control is left to its identity:
    /// its document is not the page's (2026-10-21: on DemoQA every Yes on a field with a twin lapsed).
    func element(sameAs original: ObservedElement, matching identity: ElementIdentity,
                 seenIn earlier: ObservedPage) -> ObservedElement? {
        if let found = element(matching: identity) { return found }
        guard original.frame == nil, let key = original.key, let document = documentID,
              document == earlier.documentID else { return nil }
        let twins = elements.filter { $0.fingerprint == identity.fingerprint }
        guard twins.count == identity.total, identity.occurrence < twins.count else { return nil }
        let candidate = twins[identity.occurrence]
        return candidate.key == key ? candidate : nil
    }

    private static func twinsAreOneDestination(_ element: ObservedElement) -> Bool {
        guard element.role == "link", let href = element.href, !href.isEmpty else { return false }
        return href.count < ObserverScript.maxURLLength
    }

    /// The page with its frames read into it (ITER-076 I-09), each as the
    /// observer reports it in that frame's own document: every frame's
    /// controls join the page's, numbered after them and carrying their
    /// frame — its id and who it is; the page asks for what any of its frames
    /// asks for; its text is every frame's after its own, as bounded as its
    /// own, and cut when any part of it was (ITER-076 I-10). A frame from another site that holds a sign-in — a password
    /// field, or an address an identity provider signs people in at (review
    /// of I-09, F6) — or a card form is the user's part: every control in it
    /// could send a secret — its links aside, which only leave the page. So
    /// is every frame from another site when a document names a frame a
    /// card's or a sign-in's field: which frame it names is not known, and
    /// each asks for what it is named (Claude review c11, #4). A frame whose
    /// address asks for a grant makes the whole page ask for one
    /// (`asksForGrant`).
    ///
    /// A frame's controls and words are reported as a person sees them,
    /// whatever its holder names it: its own fields the page marks secret by
    /// structure its own look withholds (owner decision of 2026-10-03). Which
    /// frame a word about a total is of is not known: one standing where a
    /// total shows makes every frame's controls show it; a frame that shows
    /// a total makes every control whose form or region holds a frame show
    /// it, and every frame's control — a total and its order may stand in two
    /// frames side by side (Claude review of I-09, kept 3; Claude review c8
    /// of I-09, #20).
    ///
    /// A frame the look did not read (`unread`) may show a total: it counts
    /// as one that does (#19). And it may hold a twin of a control read in
    /// another frame — one of the same holder and origin — which no count of
    /// the read can rule out: a control in a frame of an unread one's
    /// identity, or in any frame when one could not even be listed, is not
    /// reported (#21).
    func merging(_ frames: [(id: String, identity: String, page: ObservedPage)],
                 unread: Unread = Unread()) -> ObservedPage {
        var joined = elements.map { element in
            var own = element
            own.frame = nil
            return own
        }
        var flags = flags, truncated = truncated, text = text, textCut = textCut
        var read: [ObservedFrame] = []
        var next = (elements.map(\.index).max() ?? -1) + 1
        let documents = [self] + frames.map(\.page)
        let besideAmount = documents.contains { $0.frameOwners?.besideAmount == true }
        let named = documents.compactMap { $0.frameOwners?.named }
        let readAmount = frames.contains { $0.page.amountShown == true }
        let frameShowsAmount = unread.any || readAmount
        for (id, identity, frame) in frames {
            let base = next
            let otherSite = Self.site(of: frame.liveAddress, isNotThatOf: liveAddress)
            let asks = !otherSite ? frame.flags
                : PageFlags(loginForm: frame.flags.loginForm || named.contains { $0.loginForm },
                            paymentForm: frame.flags.paymentForm || named.contains { $0.paymentForm })
            let walled = (asks.loginForm || asks.paymentForm || SafetyGuard.signsIn(at: frame.liveAddress)) && otherSite
            let unproven = unread.unknown || unread.identities.contains(identity)
            for element in frame.elements where !unproven {
                var theirs = element
                theirs.index = base + element.index
                theirs.listOf = element.listOf.map { base + $0 }
                theirs.frame = id
                theirs.frameIdentity = identity
                if walled, element.role != "link" { theirs.touchesSecret = true }
                if besideAmount || frameShowsAmount {
                    if !theirs.showsAmount, !besideAmount, !readAmount { theirs.amountUnknown = true }
                    theirs.showsAmount = true
                }
                joined.append(theirs)
                next = max(next, theirs.index + 1)
            }
            flags = PageFlags(loginForm: flags.loginForm || frame.flags.loginForm,
                              paymentForm: flags.paymentForm || frame.flags.paymentForm)
            truncated = truncated || frame.truncated
            if !frame.text.isEmpty {
                let joined = text.isEmpty ? frame.text : text + "\n" + frame.text
                text = String(joined.prefix(Self.maxText))
                textCut = textCut || joined.count > Self.maxText
            }
            textCut = textCut || frame.textCut
            read.append(ObservedFrame(id: id, address: frame.liveAddress, flags: asks))
        }
        if frameShowsAmount {
            for index in joined.indices where joined[index].holdsFrame == true {
                if !joined[index].showsAmount, !readAmount { joined[index].amountUnknown = true }
                joined[index].showsAmount = true
            }
        }
        return ObservedPage(url: url, title: title, truncated: truncated, flags: flags, elements: joined, text: text,
                            scrollY: scrollY, address: address, frames: frames.isEmpty ? self.frames : read,
                            textCut: textCut, loadedFrom: loadedFrom, frameOwners: frameOwners, amountShown: amountShown,
                            documentID: documentID)
    }

    /// The frames of a page a look did not read: who each one listed is, and
    /// whether any could not even be listed — who that one is, is unknown.
    struct Unread: Equatable {
        var identities: Set<String> = []
        var unknown = false

        var any: Bool { unknown || !identities.isEmpty }
    }

    /// The most text a page carries, its frames' included: the observer's
    /// own bound (`MAX_PAGE_TEXT`).
    static let maxText = 6_000

    /// The page asks for a grant: its address carries an OAuth request, or
    /// a frame's does, whatever the frame's site — a consent page the site
    /// frames itself (ITER-076 2.1; review of I-09, F3).
    var asksForGrant: Bool {
        SafetyGuard.hasOAuthMarkers(liveAddress) || frames.contains { SafetyGuard.hasOAuthMarkers($0.address) }
    }

    /// The hosts of the addresses that ask for the grant (`asksForGrant`): the page's own, a frame's. An address of
    /// one opened from the page — its approval, read off it — is the user's part as its controls are (Codex review
    /// of 2026-10-21, P1-4).
    var consentHosts: Set<String> {
        Set(([liveAddress] + frames.map(\.address)).filter(SafetyGuard.hasOAuthMarkers).compactMap(Self.host(of:)))
    }

    /// An address's host as one name is compared: lowercased, without the root's dot a host may be written with
    /// (`example.com.` is `example.com`; Codex review 2 of 2026-10-21's second round, P1).
    static func host(of address: String) -> String? {
        guard let host = URL(string: address)?.host()?.lowercased(), !host.isEmpty else { return nil }
        return host.hasSuffix(".") ? String(host.dropLast()) : host
    }

    /// Whether `address` is of a consent host's own family (`consentHosts`): the domain its last two labels name, or
    /// any host under it, however deep — an approval kept on a subdomain or a sibling host (Codex reviews of
    /// 2026-10-21: idp.test's finish.idp.test, login.eu.example.com's accounts.example.com). Read without a list of
    /// public suffixes, it walls more than the site where two labels are a suffix (co.uk): only from a consent page.
    func isOfTheConsent(_ address: String?) -> Bool {
        guard let host = address.flatMap(Self.host(of:)) else { return false }
        return consentHosts.contains { consent in
            let base = consent.split(separator: ".").suffix(2).joined(separator: ".")
            return host == base || host.hasSuffix("." + base)
        }
    }

    /// Whether a frame at `address` is of another site than the page at
    /// `page`: a sign-in or a card form in it makes every control in it the
    /// user's part (`merging`), at the look and at the act (Claude review c7
    /// of I-09, #5).
    static func site(of address: String, isNotThatOf page: String) -> Bool {
        URL(string: address).flatMap(Scratchpad.site(of:)) != URL(string: page).flatMap(Scratchpad.site(of:))
    }

    /// Whether `element` is in a CAPTCHA provider's widget, by where its
    /// frame really is (ITER-076 stage 3): never acted on.
    func inCaptchaWidget(_ element: ObservedElement?) -> Bool {
        frame(of: element).map { SafetyGuard.isCaptchaWidget($0.address) } ?? false
    }

    /// Whether `element` is in a frame of another site than the page's.
    func inFrameOfAnotherSite(_ element: ObservedElement?) -> Bool {
        guard let frame = frame(of: element) else { return false }
        return Self.site(of: frame.address, isNotThatOf: liveAddress)
    }

    /// Where `element`'s own document really is: its frame's, or the page's.
    func address(of element: ObservedElement?) -> String {
        frame(of: element)?.address ?? liveAddress
    }

    /// What `element`'s own document asks for: its frame's, or the page's —
    /// with every frame's.
    func flags(of element: ObservedElement?) -> PageFlags {
        frame(of: element)?.flags ?? flags
    }

    private func frame(of element: ObservedElement?) -> ObservedFrame? {
        guard let id = element?.frame else { return nil }
        return frames.first { $0.id == id }
    }
}

extension ObservedElement {
    /// The element's identity across observations (ITER-074 §6.1): SHA-256 of
    /// role, name, href, nearest heading, row context and the form's action and
    /// method — and, for an option of a made-up dropdown, that dropdown, and,
    /// in a frame, who its frame is (ITER-076 I-08, I-09; review of I-09, F5)
    /// — first 8 bytes as hex.
    /// Index, viewport and visible text are left out on purpose — they change
    /// when the page scrolls or re-renders; identity does not. Two "Continue"
    /// buttons that send to different places are different things to do.
    var fingerprint: String {
        // The dropdown an option is of (Codex review 1 of I-08, P1-2) and the
        // frame a control is in (I-09) are part of it; a control with neither
        // keeps the fingerprint it had.
        var parts: [String] = [role, name, href ?? "", heading ?? "", context ?? "", formAction ?? "", formMethod ?? ""]
        if let listOwner { parts.append(listOwner) }
        if let frameIdentity { parts.append(frameIdentity) }
        let identity = parts.joined(separator: "\u{1F}")
        return SHA256.hash(data: Data(identity.utf8))
            .prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
