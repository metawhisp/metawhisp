import Carbon
import Foundation

/// The two macOS input sources supported by the first Layout Fixer release.
enum KeyboardLayout: String, Equatable, Sendable {
    case englishUS
    case russian

    var opposite: Self {
        switch self {
        case .englishUS: .russian
        case .russian: .englishUS
        }
    }
}

/// A deterministic correction proposed by the local layout confidence engine.
struct LayoutCorrection: Equatable, Sendable {
    let replacement: String
    let targetLayout: KeyboardLayout
}

/// One physical macOS keyboard position and its relevant modifier state.
struct KeyboardPhysicalKey: Hashable, Sendable {
    let keyCode: UInt16
    let shifted: Bool
    let capsLock: Bool
}

private struct KeyboardLayoutCharacterMap: Sendable {
    let byKey: [KeyboardPhysicalKey: Character]
    let byCharacter: [Character: KeyboardPhysicalKey]

    static let empty = KeyboardLayoutCharacterMap(byKey: [:], byCharacter: [:])
}

/// Loads the exact enabled macOS keyboard-layout data. Apple Russian is not
/// the same punctuation layout as Windows Russian, so a handwritten table is
/// not a safe source of truth.
private enum SystemKeyboardLayoutMapLoader {
    static func load(identifier: String) -> KeyboardLayoutCharacterMap? {
        let properties = [
            kTISPropertyInputSourceCategory: kTISCategoryKeyboardInputSource,
            kTISPropertyInputSourceType: kTISTypeKeyboardLayout
        ] as CFDictionary
        let sources = TISCreateInputSourceList(properties, false)
            .takeRetainedValue() as! [TISInputSource]
        guard let source = sources.first(where: {
            stringProperty(kTISPropertyInputSourceID, from: $0) == identifier
        }),
        let dataPointer = TISGetInputSourceProperty(
            source,
            kTISPropertyUnicodeKeyLayoutData
        ) else {
            return nil
        }

        let data = Unmanaged<CFData>.fromOpaque(dataPointer)
            .takeUnretainedValue() as Data
        var byKey: [KeyboardPhysicalKey: Character] = [:]
        var byCharacter: [Character: KeyboardPhysicalKey] = [:]
        let modifierStates = [
            (shifted: false, capsLock: false),
            (shifted: true, capsLock: false),
            (shifted: false, capsLock: true),
            (shifted: true, capsLock: true)
        ]

        for keyCode in UInt16(0)...UInt16(127) {
            for state in modifierStates {
                let key = KeyboardPhysicalKey(
                    keyCode: keyCode,
                    shifted: state.shifted,
                    capsLock: state.capsLock
                )
                guard let character = translate(key, using: data) else { continue }
                byKey[key] = character
                // Enumeration visits the main keyboard before keypad and the
                // ordinary Shift spelling before Caps Lock duplicates.
                if byCharacter[character] == nil {
                    byCharacter[character] = key
                }
            }
        }

        guard !byKey.isEmpty else { return nil }
        return KeyboardLayoutCharacterMap(
            byKey: byKey,
            byCharacter: byCharacter
        )
    }

    private static func translate(
        _ key: KeyboardPhysicalKey,
        using data: Data
    ) -> Character? {
        var modifierState: UInt32 = 0
        if key.shifted {
            modifierState |= (UInt32(shiftKey) >> 8) & 0xFF
        }
        if key.capsLock {
            modifierState |= (UInt32(alphaLock) >> 8) & 0xFF
        }

        var deadKeyState: UInt32 = 0
        var characters = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = data.withUnsafeBytes { bytes -> OSStatus in
            guard let baseAddress = bytes.baseAddress else { return OSStatus(paramErr) }
            return UCKeyTranslate(
                baseAddress.assumingMemoryBound(to: UCKeyboardLayout.self),
                key.keyCode,
                UInt16(kUCKeyActionDown),
                modifierState,
                UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysMask),
                &deadKeyState,
                characters.count,
                &length,
                &characters
            )
        }
        guard status == noErr, length > 0 else { return nil }
        let value = String(utf16CodeUnits: characters, count: length)
        guard value.count == 1,
              let character = value.first,
              !character.isNewline,
              character.unicodeScalars.allSatisfy({ $0.value >= 0x20 }) else {
            return nil
        }
        return character
    }

    private static func stringProperty(
        _ property: CFString,
        from source: TISInputSource
    ) -> String? {
        guard let pointer = TISGetInputSourceProperty(source, property) else {
            return nil
        }
        return Unmanaged<CFString>.fromOpaque(pointer)
            .takeUnretainedValue() as String
    }
}

/// Maps characters by the exact physical US/Russian keyboard positions that
/// macOS exposes through TIS/UCKeyTranslate.
struct KeyboardLayoutMapper: Sendable {
    static let russianEnglish = KeyboardLayoutMapper()

    private let english: KeyboardLayoutCharacterMap
    private let russian: KeyboardLayoutCharacterMap

    var isAvailable: Bool {
        !english.byKey.isEmpty && !russian.byKey.isEmpty
    }

    init() {
        self.english = SystemKeyboardLayoutMapLoader.load(
            identifier: InputSourceIDResolver.englishUS
        ) ?? .empty
        self.russian = SystemKeyboardLayoutMapLoader.load(
            identifier: InputSourceIDResolver.russian
        ) ?? .empty
    }

    /// Converts a complete token or returns `nil` rather than partially
    /// modifying a token that contains an unsupported character.
    func convert(_ token: String, from source: KeyboardLayout) -> String? {
        guard !token.isEmpty else { return nil }
        var converted = String()
        converted.reserveCapacity(token.count)

        for character in token {
            guard let replacement = convertedCharacter(character, from: source) else {
                return nil
            }
            converted.append(replacement)
        }

        return converted
    }

    /// Explicit manual conversion for a selection or phrase. Characters that
    /// do not belong to either physical layout (spaces, line breaks, emoji,
    /// typographic punctuation) pass through unchanged instead of making the
    /// entire operation fail.
    func convertText(_ text: String, from source: KeyboardLayout) -> String? {
        guard !text.isEmpty else { return nil }
        var converted = String()
        converted.reserveCapacity(text.count)
        var changed = false
        for character in text {
            guard let replacement = convertedCharacter(character, from: source) else {
                converted.append(character)
                continue
            }
            converted.append(replacement)
            changed = changed || replacement != character
        }
        return changed ? converted : nil
    }

    /// Renders one observed physical key in both layouts. Automatic input uses
    /// this path so punctuation that represents a target-language letter is
    /// never mistaken for a word boundary.
    func translation(
        for keyCode: UInt16,
        shifted: Bool,
        capsLock: Bool,
        from source: KeyboardLayout
    ) -> (source: Character, target: Character)? {
        let key = KeyboardPhysicalKey(
            keyCode: keyCode,
            shifted: shifted,
            capsLock: capsLock
        )
        let sourceMap = map(for: source)
        let targetMap = map(for: source.opposite)
        guard let sourceCharacter = sourceMap.byKey[key],
              let targetCharacter = targetMap.byKey[key] else {
            return nil
        }
        return (sourceCharacter, targetCharacter)
    }

    /// Manual intent follows the script of the text, not whichever input
    /// source happens to be active after the text was typed.
    func sourceLayout(for text: String, fallback: KeyboardLayout) -> KeyboardLayout {
        let (latinLetters, cyrillicLetters) = scriptCounts(in: text)
        if latinLetters > cyrillicLetters { return .englishUS }
        if cyrillicLetters > latinLetters { return .russian }
        return fallback
    }

    /// No-selection conversion must not choose a direction for a mixed line:
    /// converting by majority would corrupt the already-correct script.
    func unambiguousSourceLayout(
        for text: String,
        fallback: KeyboardLayout
    ) -> KeyboardLayout? {
        let (latinLetters, cyrillicLetters) = scriptCounts(in: text)
        guard latinLetters == 0 || cyrillicLetters == 0 else { return nil }
        if latinLetters > 0 { return .englishUS }
        if cyrillicLetters > 0 { return .russian }
        return fallback
    }

    private func scriptCounts(in text: String) -> (latin: Int, cyrillic: Int) {
        var latin = 0
        var cyrillic = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x41...0x5A, 0x61...0x7A: latin += 1
            case 0x0400...0x04FF: cyrillic += 1
            default: break
            }
        }
        return (latin, cyrillic)
    }

    private func convertedCharacter(
        _ character: Character,
        from source: KeyboardLayout
    ) -> Character? {
        let sourceMap = map(for: source)
        let targetMap = map(for: source.opposite)
        guard let key = sourceMap.byCharacter[character] else { return nil }
        return targetMap.byKey[key]
    }

    private func map(for layout: KeyboardLayout) -> KeyboardLayoutCharacterMap {
        switch layout {
        case .englishUS: english
        case .russian: russian
        }
    }
}

/// Bounded local vocabulary for the initial strict automatic mode.
///
/// The first release deliberately corrects only a recognised target word.
/// This keeps the false-positive rate low until a licensed, broader dictionary
/// is productised in a follow-up iteration.
struct LocalLayoutLexicon: Sendable {
    static let common = LocalLayoutLexicon(
        english: [
            "hello", "hi", "thanks", "thank", "please", "yes", "no", "good", "great",
            "morning", "evening", "today", "tomorrow", "now", "later", "work", "project",
            "task", "meeting", "message", "email", "write", "read", "open", "close",
            "start", "stop", "test"
        ],
        russian: [
            "привет", "спасибо", "пожалуйста", "да", "нет", "хорошо", "отлично",
            "утро", "вечер", "сегодня", "завтра", "сейчас", "потом", "работа", "проект",
            "задача", "встреча", "сообщение", "письмо", "написать", "прочитать", "открыть",
            "закрыть", "начать", "остановить", "тест"
        ]
    )

    private let english: Set<String>
    private let russian: Set<String>

    init(english: [String], russian: [String]) {
        self.english = Set(english.map(Self.normalize))
        self.russian = Set(russian.map(Self.normalize))
    }

    func contains(_ word: String, language: KeyboardLayout) -> Bool {
        let words = switch language {
        case .englishUS: english
        case .russian: russian
        }
        return words.contains(Self.normalize(word))
    }

    private static func normalize(_ word: String) -> String {
        word.lowercased()
    }
}

/// Proposes only high-confidence automatic corrections.
struct LayoutConfidenceEngine: Sendable {
    private static let englishLetters = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
    private static let russianLetters = Set("абвгдеёжзийклмнопрстуфхцчшщъыьэюяАБВГДЕЁЖЗИЙКЛМНОПРСТУФХЦЧШЩЪЫЬЭЮЯ")
    private static let safeThreeLetterEnglishTargets: Set<String> = [
        "all", "and", "are", "but", "can", "day", "did", "for", "get", "got",
        "her", "him", "how", "man", "new", "not", "now", "one", "our", "out",
        "see", "the", "two", "use", "was", "who", "why", "yes", "you"
    ]
    private static let safeThreeLetterRussianTargets: Set<String> = [
        "вас", "все", "где", "для", "дом", "его", "еще", "как", "кто", "мир",
        "мне", "нет", "она", "они", "так", "там", "тут", "уже", "что", "это"
    ]
    /// Corpus-audited source words that the installed dictionaries can miss
    /// even though their physical-layout image is a valid target word.
    private static let blockedEnglishSourceCollisions: Set<String> = [
        "asdf", "qwerty", "dna", "tim", "nba", "ceo", "nec", "ghz", "gen", "cfr", "rec",
        "ide", "buf", "gba", "chen", "len", "dept", "eds", "vcr", "abu",
        "gtk", "rel", "att", "che", "det", "ctr", "hsn", "rdf", "cbc",
        "dst", "ger", "dep", "abn", "rey", "thb", "ita", "cbd", "afl",
        "rfp", "itk", "entre", "gev", "ren", "neu", "ect", "afc", "ecs",
        "pps", "aff", "utp", "ibn", "ctx", "fha", "tls", "abit"
    ]
    private static let blockedRussianSourceCollisions: Set<String> = [
        "мвд", "ввс", "фыва", "йцукен"
    ]

    private let mapper: KeyboardLayoutMapper
    private let lexicon: LocalLayoutLexicon

    init(
        mapper: KeyboardLayoutMapper = .russianEnglish,
        lexicon: LocalLayoutLexicon = .common
    ) {
        self.mapper = mapper
        self.lexicon = lexicon
    }

    /// Returns a correction only for a known target-language word that was
    /// typed entirely in the other layout. Correct source-language words and
    /// unknown tokens stay untouched.
    func automaticCorrection(for token: String, typedIn source: KeyboardLayout) -> LayoutCorrection? {
        automaticCorrection(for: token, typedIn: source) { word, language in
            lexicon.contains(word, language: language)
        }
    }

    /// Same conservative decision path with the caller's local lexicon lookup.
    /// The controller supplies macOS's installed spell-checking
    /// dictionaries in production; the built-in lexicon keeps this pure
    /// engine deterministic in unit tests and when no system dictionary is
    /// installed for a supported language.
    func automaticCorrection(
        for token: String,
        typedIn source: KeyboardLayout,
        isKnownWord: (String, KeyboardLayout) -> Bool
    ) -> LayoutCorrection? {
        automaticCorrection(
            for: token,
            preconvertedReplacement: nil,
            typedIn: source,
            isKnownWord: isKnownWord
        )
    }

    /// Automatic input already has the physical keycodes, so its opposite
    /// rendering is supplied directly instead of reverse-looking-up visible
    /// punctuation after the fact.
    func automaticCorrection(
        for token: String,
        convertedTo replacement: String,
        typedIn source: KeyboardLayout,
        isKnownWord: (String, KeyboardLayout) -> Bool
    ) -> LayoutCorrection? {
        automaticCorrection(
            for: token,
            preconvertedReplacement: replacement,
            typedIn: source,
            isKnownWord: isKnownWord
        )
    }

    private func automaticCorrection(
        for token: String,
        preconvertedReplacement: String?,
        typedIn source: KeyboardLayout,
        isKnownWord: (String, KeyboardLayout) -> Bool
    ) -> LayoutCorrection? {
        let direct = directAutomaticCorrection(
            for: token,
            preconvertedReplacement: preconvertedReplacement,
            typedIn: source,
            isKnownWord: isKnownWord
        )
        guard let split = splitTrailingAmbiguousPunctuation(token, typedIn: source) else {
            return direct
        }

        let convertedCore = preconvertedReplacement.map {
            String($0.dropLast(split.suffix.count))
        }
        let core = directAutomaticCorrection(
            for: split.core,
            preconvertedReplacement: convertedCore,
            typedIn: source,
            isKnownWord: isKnownWord
        )

        // Both interpretations are valid (for example `levf.` can be either
        // `думаю` or literal `дума.`). Automatic mode must leave it alone.
        if direct != nil, core != nil {
            return nil
        }
        if let direct {
            return direct
        }
        guard let core else { return nil }
        return LayoutCorrection(
            replacement: core.replacement + split.suffix,
            targetLayout: core.targetLayout
        )
    }

    private func directAutomaticCorrection(
        for token: String,
        preconvertedReplacement: String? = nil,
        typedIn source: KeyboardLayout,
        isKnownWord: (String, KeyboardLayout) -> Bool
    ) -> LayoutCorrection? {
        guard (3...24).contains(token.count),
              !isAllCaps(token),
              !isRepeatedCharacterMash(token),
              !looksLikeCodeIdentifier(token),
              !isBlockedSourceCollision(token, in: source) else {
            return nil
        }
        guard let replacement = preconvertedReplacement
                ?? mapper.convert(token, from: source) else { return nil }

        let target = source.opposite
        guard isEligibleAutomaticToken(replacement, in: target) else {
            return nil
        }

        // A punctuation key may be a real target-layout letter. Such a token
        // cannot be looked up as a source word, but a positive target match is
        // still safe. Plain source words are protected first.
        if isEligibleAutomaticToken(token, in: source),
           isKnownWord(token, source) {
            return nil
        }
        if token.count >= 4,
           token == token.lowercased(),
           isEligibleAutomaticToken(token, in: source),
           isKnownWord(token.prefix(1).uppercased() + token.dropFirst(), source) {
            return nil
        }
        guard isKnownWord(replacement, target) else { return nil }

        if replacement.count == 3,
           !isSafeThreeLetterTarget(replacement, in: target) {
            return nil
        }

        return LayoutCorrection(replacement: replacement, targetLayout: target)
    }

    private func isEligibleAutomaticToken(_ token: String, in layout: KeyboardLayout) -> Bool {
        guard (2...24).contains(token.count) else { return false }
        let alphabet = switch layout {
        case .englishUS: Self.englishLetters
        case .russian: Self.russianLetters
        }
        return token.allSatisfy(alphabet.contains)
    }

    private func isSafeThreeLetterTarget(_ word: String, in layout: KeyboardLayout) -> Bool {
        let normalized = word.lowercased()
        switch layout {
        case .englishUS:
            return Self.safeThreeLetterEnglishTargets.contains(normalized)
        case .russian:
            return Self.safeThreeLetterRussianTargets.contains(normalized)
        }
    }

    private func isBlockedSourceCollision(_ word: String, in layout: KeyboardLayout) -> Bool {
        switch layout {
        case .englishUS:
            return Self.blockedEnglishSourceCollisions.contains(word.lowercased())
        case .russian:
            return Self.blockedRussianSourceCollisions.contains(word.lowercased())
        }
    }

    private func isAllCaps(_ token: String) -> Bool {
        let letters = token.filter(\.isLetter)
        return letters.count > 1
            && letters == letters.uppercased()
            && letters != letters.lowercased()
    }

    private func isRepeatedCharacterMash(_ token: String) -> Bool {
        let normalized = token.lowercased()
        return normalized.count >= 3 && Set(normalized).count == 1
    }

    private func looksLikeCodeIdentifier(_ token: String) -> Bool {
        if token.dropFirst().contains(where: \.isUppercase) {
            return true
        }

        var hasLatin = false
        var hasCyrillic = false
        for scalar in token.unicodeScalars {
            switch scalar.value {
            case 0x41...0x5A, 0x61...0x7A: hasLatin = true
            case 0x0400...0x04FF: hasCyrillic = true
            default: break
            }
        }
        return hasLatin && hasCyrillic
    }

    private func splitTrailingAmbiguousPunctuation(
        _ token: String,
        typedIn source: KeyboardLayout
    ) -> (core: String, suffix: String)? {
        var core = token
        var suffix = ""
        while let last = core.last,
              !last.isLetter,
              mapper.convert(String(last), from: source)?.first?.isLetter == true {
            core.removeLast()
            suffix.insert(last, at: suffix.startIndex)
        }
        guard !core.isEmpty, !suffix.isEmpty else { return nil }
        return (core, suffix)
    }
}
