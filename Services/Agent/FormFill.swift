import Foundation
import SwiftData

/// The user's own details a web form is filled from (ITER-076 stage 7, № 53,
/// 87; owner decision 3 of 2026-09-26): confirmed memories — MetaChat's own
/// filter, not dismissed and not waiting for review — the ones the user told
/// MetaChat first, then the newest, at most as many as MetaChat reads for an
/// answer; then the Pro account's e-mail, a detail of its own. A memory that
/// holds a card number is never one: it is neither sent to the writer nor
/// typed. E-mail, phone and web address are found in them by code
/// (`NSDataDetector`) and copied word for word, as the memory writes them.
struct FormFacts: Equatable, Sendable {
    /// One detail: its words, and where it comes from.
    struct Detail: Equatable, Sendable {
        enum Source: Equatable, Sendable { case memory, proAccount }
        let text: String
        let source: Source
    }

    /// A memory as the collector reads it.
    struct Memory: Equatable, Sendable {
        let content: String
        /// The user told it to MetaChat (`addMemory`, ITER-076 stage 7, № 246).
        let toldMetaChat: Bool
        let createdAt: Date
    }

    let details: [Detail]

    static let none = FormFacts(details: [])
    /// The most memories one form is filled from: as many as MetaChat reads
    /// for an answer (`ChatService`, `fetchMemoriesForQuery(limit: 20)`).
    static let maxMemories = 20

    /// The facts of `memories` — already MetaChat's confirmed ones — and the
    /// Pro account's e-mail.
    static func collect(memories: [Memory], proEmail: String?) -> FormFacts {
        let ordered = memories.enumerated().sorted { first, second in
            let (a, b) = (first.element, second.element)
            if a.toldMetaChat != b.toldMetaChat { return a.toldMetaChat }
            if a.createdAt != b.createdAt { return a.createdAt > b.createdAt }
            return first.offset < second.offset
        }.map(\.element)
        return gathered(ordered, proEmail: proEmail)
    }

    /// The facts of `memories` in the order given — MetaChat's own ranking
    /// for a form's names (ITER-076 stage 11) — but the ones the user told
    /// MetaChat first; then as `collect` keeps them.
    static func collect(ranked memories: [Memory], proEmail: String?) -> FormFacts {
        gathered(memories.filter(\.toldMetaChat) + memories.filter { !$0.toldMetaChat }, proEmail: proEmail)
    }

    /// `ordered`'s first `maxMemories` that hold words and no card number,
    /// then the Pro account's e-mail.
    private static func gathered(_ ordered: [Memory], proEmail: String?) -> FormFacts {
        var details = Array(ordered.lazy.map { $0.content.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !holdsCardNumber($0) }.prefix(maxMemories)
            .map { Detail(text: $0, source: .memory) })
        if let email = proEmail?.trimmingCharacters(in: .whitespacesAndNewlines), !email.isEmpty,
           !holdsCardNumber(email) {
            details.append(Detail(text: email, source: .proAccount))
        }
        return FormFacts(details: details)
    }

    /// The app's facts: its own store's memories with MetaChat's filter, and
    /// the Pro account's e-mail — read when a form is met, so a fact the user
    /// told MetaChat a moment ago counts.
    @MainActor
    static func stored(in container: ModelContainer?, proEmail: String?) -> FormFacts {
        var memories: [Memory] = []
        if let container {
            let descriptor = FetchDescriptor<UserMemory>(predicate: #Predicate { !$0.isDismissed && !$0.needsReview },
                                                         sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
            memories = ((try? ModelContext(container).fetch(descriptor)) ?? []).map { Memory($0) }
        }
        return collect(memories: memories, proEmail: proEmail)
    }

    /// The facts of the app this runs in (ITER-076 stage 7).
    @MainActor
    static func app() -> FormFacts {
        stored(in: AppDelegate.shared?.historyService.modelContainer, proEmail: LicenseService.shared.email)
    }

    /// Each e-mail address the details write, as written, with its detail's
    /// source, in the details' order, each once.
    var emails: [(text: String, source: Detail.Source)] {
        found { match in match.resultType == .link && match.url?.scheme?.lowercased() == "mailto" }
    }

    /// Each phone number the details write, as written.
    var phones: [(text: String, source: Detail.Source)] {
        found { $0.resultType == .phoneNumber }
    }

    /// Each web address the details write, as written.
    var links: [(text: String, source: Detail.Source)] {
        found { match in match.resultType == .link && ["http", "https"].contains(match.url?.scheme?.lowercased() ?? "") }
    }

    private func found(_ wanted: (NSTextCheckingResult) -> Bool) -> [(text: String, source: Detail.Source)] {
        var seen: Set<String> = []
        var out: [(text: String, source: Detail.Source)] = []
        for detail in details {
            for text in Self.matches(in: detail.text, wanted) where seen.insert(text.lowercased()).inserted {
                out.append((text, detail.source))
            }
        }
        return out
    }

    /// What a detector finds in `text` that `wanted` keeps: the words exactly
    /// as they stand in it, never the detector's canonical form.
    static func matches(in text: String, _ wanted: (NSTextCheckingResult) -> Bool) -> [String] {
        let types = NSTextCheckingResult.CheckingType.link.rawValue | NSTextCheckingResult.CheckingType.phoneNumber.rawValue
        guard let detector = try? NSDataDetector(types: types) else { return [] }
        let whole = text as NSString
        return detector.matches(in: text, range: NSRange(location: 0, length: whole.length)).filter(wanted)
            .map { whole.substring(with: $0.range) }
    }

    /// Whether `text` holds a card number, read as the observer reads a field
    /// (`ObserverScript`'s `holdsCardNumber`): compatibility forms as what they
    /// stand for, hidden marks as nothing, then a run of digit groups —
    /// parted by spaces, dots, dashes, slashes or underscores — with, from any
    /// group, 13 to 19 digits that pass the Luhn check.
    static func holdsCardNumber(_ text: String) -> Bool {
        let plain = SafetyGuard.plain(text)
        guard let runs = try? NSRegularExpression(pattern: "[0-9][0-9 ._/-]*[0-9]") else { return false }
        for run in runs.matches(in: plain, range: NSRange(plain.startIndex..., in: plain)) {
            guard let range = Range(run.range, in: plain) else { continue }
            let groups = plain[range].split { !("0"..."9").contains($0) }.map(String.init)
            for start in groups.indices {
                var digits = ""
                for group in groups[start...] {
                    guard digits.count < 19 else { break }
                    digits += group
                    if (13...19).contains(digits.count), luhn(digits) { return true }
                }
            }
        }
        return false
    }

    private static func luhn(_ digits: String) -> Bool {
        var sum = 0
        for (place, character) in digits.reversed().enumerated() {
            guard var digit = character.wholeNumberValue else { return false }
            if place % 2 == 1 {
                digit *= 2
                if digit > 9 { digit -= 9 }
            }
            sum += digit
        }
        return sum % 10 == 0
    }
}

extension FormFacts.Memory {
    /// A memory of the app's store: told to MetaChat when MetaChat stored it
    /// (`addMemory`).
    init(_ memory: UserMemory) {
        self.init(content: memory.content, toldMetaChat: memory.sourceApp == "MetaChat", createdAt: memory.createdAt)
    }
}

/// A web form as one whole (ITER-076 stage 7, № 69, 54, 56, 59): what each
/// field asks for by the page's structure alone, the fields a preview fills,
/// and which written value is kept. No word of a label is read to decide any
/// of it, in any language (owner decision 11 of 2026-09-26).
enum FormFill {
    /// What a field asks for, by its structure: its `autocomplete`, then its
    /// input type; a text area — a field the observer reads as typed into,
    /// with no input type — asks for a message. The raw values are the fixed
    /// words MetaChat's line names them by: never a page's label.
    enum Kind: String, CaseIterable, Equatable, Sendable {
        case name, firstName = "first name", lastName = "last name", email, phone, company, jobTitle = "job title"
        case website, streetAddress = "street address", city, postalCode = "postal code", country, message

        /// A street address is never typed in this version (decision 7.2):
        /// the preview shows it left empty, never typed.
        var neverTyped: Bool { self == .streetAddress }

        /// A field that makes its form one of the user's details: one that
        /// asks for how to reach them, or who they are — no search asks for
        /// either by structure.
        var marksTheUsersDetails: Bool {
            [.email, .phone, .name, .firstName, .lastName].contains(self)
        }
    }

    /// Where a value comes from, as the preview names it.
    enum Source: Equatable, Sendable {
        /// "from your memories"
        case memories
        /// "written from the request"
        case request
        /// "from your Pro account"
        case proAccount
    }

    /// A field's value and its source.
    struct Value: Equatable, Sendable {
        let text: String
        let source: Source
    }

    /// The autocomplete field names a kind is read from (WHATWG HTML,
    /// "autofill field name"); the qualifiers around one — a section, billing
    /// or shipping, home or work — say nothing of what it asks for.
    private static let named: [String: Kind] = [
        "name": .name, "given-name": .firstName, "family-name": .lastName, "email": .email, "tel": .phone,
        "tel-national": .phone, "organization": .company, "organization-title": .jobTitle, "url": .website,
        "street-address": .streetAddress, "address-line1": .streetAddress, "address-line2": .streetAddress,
        "address-line3": .streetAddress, "address-level1": .streetAddress, "address-level3": .streetAddress,
        "address-level4": .streetAddress, "address-level2": .city, "postal-code": .postalCode, "country": .country,
        "country-name": .country,
    ]

    /// What `field` asks for, by its structure; nil when it does not say.
    static func kind(of field: ObservedElement) -> Kind? {
        let tokens = (field.autocomplete ?? "").split(whereSeparator: \.isWhitespace).map { $0.lowercased() }
        if let kind = tokens.lazy.compactMap({ named[$0] }).first { return kind }
        switch field.inputType {
        case "email": return .email
        case "tel": return .phone
        case "url": return .website
        case nil where field.role == "textbox": return .message
        default: return nil
        }
    }

    /// The fields a preview fills, when `target` — the field Jev chose to type
    /// in — is one of them (a reference browser agent's `_fill_form`, `agent.py`
    /// 1684-1700, MIT): every field of its group that takes typing, empty or
    /// holding what the site put there, in the page's order, all in
    /// `target`'s frame — however few: a form of the user's details is never
    /// typed field by field around its preview (review round 1, C1). The
    /// group a form of the user's details — it holds a field that asks for an
    /// e-mail, a phone or a name by structure, so a search is none — and the
    /// page read whole. Nil otherwise.
    static func fields(around target: ObservedElement, on page: ObservedPage) -> [ObservedElement]? {
        guard !page.truncated, target.group != nil else { return nil }
        let members = Self.members(of: target, on: page)
        guard members.contains(where: { kind(of: $0)?.marksTheUsersDetails == true }) else { return nil }
        let fields = members.filter(typeable)
        guard fields.contains(where: { $0.index == target.index }) else { return nil }
        return fields
    }

    /// The controls of `control`'s group on `page`, in its frame: none for a
    /// control in no group.
    static func members(of control: ObservedElement, on page: ObservedPage) -> [ObservedElement] {
        guard let group = control.group else { return [] }
        return page.elements.filter {
            $0.group == group && $0.frame == control.frame && $0.frameIdentity == control.frameIdentity
        }
    }

    /// A field a preview fills: one the agent types in — no picker a click
    /// opens, no file — that has a name a person reads.
    static func typeable(_ field: ObservedElement) -> Bool {
        CandidateBuilder.takesTyping(field) && field.opens != true && field.inputType != "file"
            && !field.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Such a field that holds nothing yet.
    static func fillable(_ field: ObservedElement) -> Bool {
        typeable(field) && (field.value ?? "").isEmpty
    }

    /// A control that holds what a form may send: a field, a list, a box —
    /// not a button.
    static func holdsAValue(_ control: ObservedElement) -> Bool {
        control.valueKey != nil || control.checked != nil
    }

    /// Such a control that sends something as it stands: a box ticked, a
    /// choice made, a field that holds text (review round 1, C5).
    static func sendsAValue(_ control: ObservedElement) -> Bool {
        control.checked == true || control.valueKey.map { $0 != digest("") } == true
    }

    /// Whether `page` shows a form to fill: a group with two empty fields or
    /// more — a step of a form that goes on, or the same form again.
    static func showsAFormToFill(_ page: ObservedPage) -> Bool {
        var counts: [String: Int] = [:]
        for field in page.elements where fillable(field) {
            guard let group = field.group else { continue }
            counts["\(field.frameIdentity ?? "")\u{1F}\(group)", default: 0] += 1
        }
        return counts.values.contains { $0 >= 2 }
    }

    /// The value code finds for a field of `kind` (decision 7.6): an e-mail,
    /// a phone or a web address, word for word from the details — an e-mail
    /// from the Pro account when no memory holds one. Nil for any other kind,
    /// a writer's, and when the details hold none.
    static func fact(_ kind: Kind, in facts: FormFacts) -> Value? {
        let found: [(text: String, source: FormFacts.Detail.Source)]
        switch kind {
        case .email: found = facts.emails
        case .phone: found = facts.phones
        case .website: found = facts.links
        default: return nil
        }
        return found.first.map { Value(text: $0.text, source: $0.source == .proAccount ? .proAccount : .memories) }
    }

    /// What a writer wrote for a field of `kind`, as the form keeps it; nil
    /// when nothing is kept. Every e-mail, phone and web address in it must
    /// stand in the details or the user's words — a placeholder one is
    /// invented. A message (text 4) is written from the request. Any other
    /// value — a personal fact the structure names, or a field it does not
    /// name — is kept only where a detail or the user's words hold it, its
    /// source the first that does (spec 6.4): one neither holds is invented
    /// (review round 1, C6).
    static func accept(_ written: String?, kind: Kind?, goal: String, facts: FormFacts) -> Value? {
        guard let written, !written.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let sources = [goal] + facts.details.map(\.text)
        let contacts = FormFacts.matches(in: written) { _ in true }
        guard contacts.allSatisfy({ holds($0, in: sources) }) else { return nil }
        if kind == .message { return Value(text: written, source: .request) }
        if let detail = facts.details.first(where: { holds(written, in: [$0.text]) }) {
            return Value(text: written, source: detail.source == .proAccount ? .proAccount : .memories)
        }
        return holds(written, in: [goal]) ? Value(text: written, source: .request) : nil
    }

    /// Whether one of `sources` holds `text` as whole words, read as a
    /// person reads both: compatibility forms as what they stand for, hidden
    /// marks as nothing, spaces squeezed, case aside — and where it stands,
    /// it begins where a word of the source begins and ends where one ends,
    /// as Unicode tells words apart in any script, one written without
    /// spaces too: "Al" is no word of "always" (review round 1, Kimi P2-3).
    /// An edge that is a mark — a phone's "+", a closing stop — stands as
    /// it is written.
    static func holds(_ text: String, in sources: [String]) -> Bool {
        let wanted = plain(text)
        guard let first = wanted.first, let last = wanted.last else { return false }
        let opensAWord = first.isLetter || first.isNumber
        let closesAWord = last.isLetter || last.isNumber
        return sources.contains { source in
            let whole = plain(source)
            var starts: Set<String.Index> = []
            var ends: Set<String.Index> = []
            whole.enumerateSubstrings(in: whole.startIndex..., options: .byWords) { _, range, _, _ in
                starts.insert(range.lowerBound)
                ends.insert(range.upperBound)
            }
            var from = whole.startIndex
            while from < whole.endIndex, let found = whole.range(of: wanted, range: from..<whole.endIndex) {
                if !opensAWord || starts.contains(found.lowerBound), !closesAWord || ends.contains(found.upperBound) {
                    return true
                }
                from = whole.index(after: found.lowerBound)
            }
            return false
        }
    }

    private static func plain(_ text: String) -> String {
        SafetyGuard.plain(text).split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .folding(options: [.caseInsensitive], locale: nil)
    }

    /// The observer's digest of a text (`ObserverScript`'s `digestOf`), exact
    /// to its last UTF-16 unit: what a field's `valueKey` is of the value
    /// typed in it, so the app tells — without reading the value back —
    /// whether the field still holds what Fill typed.
    static func digest(_ text: String) -> String {
        var a: UInt32 = 0xdeadbeef, b: UInt32 = 0x41c6ce57
        for unit in text.utf16 {
            a = (a ^ UInt32(unit)) &* 2_654_435_761
            b = (b ^ UInt32(unit)) &* 1_597_334_677
        }
        a = ((a ^ (a >> 16)) &* 2_246_822_507) ^ ((b ^ (b >> 13)) &* 3_266_489_909)
        b = ((b ^ (b >> 16)) &* 2_246_822_507) ^ ((a ^ (a >> 13)) &* 3_266_489_909)
        return String(format: "%08x%08x", b, a)
    }

    /// A page's address as a record, a link or a log may keep it (ITER-076
    /// stage 7, item 18; review round 2, R2-5): with no value the form held
    /// anywhere in it, as it is written there or encoded, case aside: its
    /// path cut at the first part where any value stands — however often it
    /// stands there — and its query and fragment dropped, when any of them
    /// holds one — so neither
    /// MetaChat's model nor the record ever reads a value; as it is
    /// otherwise.
    static func link(_ address: String, holding values: [String]) -> String {
        guard var parts = URLComponents(string: address) else { return address }
        let wanted = values.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).folding(options: [.caseInsensitive], locale: nil)
        }.filter { !$0.isEmpty }
        let read = { (text: String) in SafetyGuard.decoded(text).folding(options: [.caseInsensitive], locale: nil) }
        let holds = { (text: String?) in text.map { part in wanted.contains { read(part).contains($0) } } == true }
        // The path's parts as they read, and where each begins in it: cut at
        // the part where any value first stands (review round 3, R3-1).
        let segments = parts.percentEncodedPath.components(separatedBy: "/")
        let shown = segments.map(read)
        var starts: [Int] = []
        var offset = 0
        for part in shown {
            starts.append(offset)
            offset += part.utf16.count + 1
        }
        let path = shown.joined(separator: "/")
        let first = wanted.compactMap { path.range(of: $0, options: .literal)?.lowerBound.utf16Offset(in: path) }.min()
        let cut = first.map { at in starts.lastIndex { $0 <= at } ?? 0 }
        guard cut != nil || holds(parts.percentEncodedQuery) || holds(parts.percentEncodedFragment) else { return address }
        if let cut {
            let kept = segments[..<cut].joined(separator: "/")
            parts.percentEncodedPath = kept.isEmpty ? "/" : kept
        }
        parts.percentEncodedQuery = nil
        parts.percentEncodedFragment = nil
        return parts.string ?? address
    }
}

/// One field of a form's question (ITER-076 stage 7, item 17): its label as
/// the page names it, and its value with where it came from — or why it is
/// left empty. The card shows it; MetaChat's model never reads it.
struct FormRow: Equatable, Sendable {
    enum Shown: Equatable, Sendable {
        case value(String, FormFill.Source, unsure: Bool)
        /// "left empty · not known": no detail of the user's holds it.
        case notKnown
        /// "left empty · never typed": a street address (decision 7.2).
        case neverTyped
    }

    let label: String
    let shown: Shown

    /// The value it shows, if any.
    var value: String? {
        if case .value(let text, _, _) = shown { return text }
        return nil
    }
}

/// What a form's question asks (ITER-076 stage 7, № 92, 93, 180): to fill
/// the form with the values it shows — one consent for every field, waiting
/// for the user (decision 7.4) — or to send it, bound to the values it shows.
struct FormQuestion: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case fill, send }

    let kind: Kind
    /// The page's host.
    let host: String
    /// The host the form is set to send to, when it is another site's: its
    /// action as the page writes it — for a Send, the action of the control
    /// pressed (review round 1, C8) — the page's own code may still send it
    /// elsewhere: named so.
    let destination: String?
    let rows: [FormRow]
    /// The site changed a value after Fill: the Send question says so.
    var changed = false
}

/// How a form's errand ended (ITER-076 stage 7, № 183, item 18), beside the
/// record's own ending: what MetaChat says and the card shows. Page words —
/// the labels — are the card's alone; MetaChat's line names the fields sent
/// by their kinds' fixed words.
struct FormEnding: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Equatable, Sendable {
        /// Sent after the user's Yes, and the next page showed it was
        /// received: the form left the page.
        case sent
        /// Send was pressed after the user's Yes, and the next page did not
        /// show the form was received.
        case notConfirmed
        /// The user said No to Fill: nothing was typed.
        case notFilled
        /// The user said No to Send, or nothing in two minutes: filled, not
        /// sent.
        case notSent
        /// The form kept changing after the user's Yes: not sent.
        case keptChanging
        /// A required field asks for a detail the user's memories do not
        /// hold, or no field could be filled: nothing was typed.
        case detailsMissing
    }

    let kind: Kind
    /// The page's host.
    let host: String
    /// Sent: the kinds of the fields sent, as `FormFill.Kind` names them, in
    /// the page's order, each once; a field the structure does not name has
    /// none.
    var kinds: [String] = []
    /// Sent: the labels of the fields sent; details missing: of the required
    /// fields no detail holds. The card's alone.
    var labels: [String] = []
    /// Not filled, not sent: no answer came in time — else the user said No.
    var silence = false
    /// Not confirmed: the page after Send, as its line names it.
    var url: String? = nil
}
