import AppKit
import Foundation
import NaturalLanguage

/// Local adapter around the spell-checking dictionaries already installed in
/// macOS. It makes no network calls and retains no typed text.
@MainActor
final class SystemLayoutLexicon {
    static let shared = SystemLayoutLexicon()

    private let spellChecker = NSSpellChecker.shared
    private let fallback = LocalLayoutLexicon.common

    private init() {}

    func contains(_ word: String, language: KeyboardLayout) -> Bool {
        let canonical = word.precomposedStringWithCanonicalMapping
        if let dictionaryLanguage = installedLanguage(for: language) {
            let misspelling = spellChecker.checkSpelling(
                of: canonical,
                startingAt: 0,
                language: dictionaryLanguage,
                wrap: false,
                inSpellDocumentWithTag: 0,
                wordCount: nil
            )
            if misspelling.location == NSNotFound {
                return true
            }
        }

        let normalized = canonical.lowercased()

        // AppleSpell misses ordinary inflected words such as `раскладка` on
        // some macOS installations. For 4+ letter words, the local Natural
        // Language morphology model is a second positive signal. It performs
        // no network request and the token is not retained.
        if normalized.count >= 4, morphologyRecognizes(normalized, language: language) {
            return true
        }

        guard installedLanguage(for: language) == nil else { return false }
        return fallback.contains(normalized, language: language)
    }

    func warmUp() {
        _ = contains("hello", language: .englishUS)
        _ = contains("привет", language: .russian)
    }

    private func installedLanguage(for layout: KeyboardLayout) -> String? {
        let primaryLanguage = switch layout {
        case .englishUS: "en"
        case .russian: "ru"
        }
        let available = spellChecker.availableLanguages
        return available.first(where: { $0 == primaryLanguage })
            ?? available.first(where: {
                $0.hasPrefix("\(primaryLanguage)_")
                    || $0.hasPrefix("\(primaryLanguage)-")
            })
    }

    private func morphologyRecognizes(_ word: String, language: KeyboardLayout) -> Bool {
        guard word.allSatisfy(\.isLetter) else { return false }
        let languageCode: NLLanguage = switch language {
        case .englishUS: .english
        case .russian: .russian
        }
        let tagger = NLTagger(tagSchemes: [.lemma])
        tagger.string = word
        tagger.setLanguage(languageCode, range: word.startIndex..<word.endIndex)
        return tagger.tag(
            at: word.startIndex,
            unit: .word,
            scheme: .lemma
        ).0 != nil
    }
}
