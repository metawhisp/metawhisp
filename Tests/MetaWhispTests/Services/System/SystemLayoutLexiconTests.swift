import AppKit
import XCTest
@testable import MetaWhisp

@MainActor
final class SystemLayoutLexiconTests: XCTestCase {
    func test_installedDictionariesRecognizeOrdinaryWordsInBothSupportedLanguages() throws {
        let available = Set(NSSpellChecker.shared.availableLanguages)
        guard available.contains("ru"), available.contains("en") else {
            throw XCTSkip("The host does not have both macOS spelling dictionaries installed.")
        }

        let russianWords = [
            "машина", "работа", "проект", "встреча", "сообщение", "письмо",
            "сегодня", "завтра", "сейчас", "потом", "человек", "время",
            "вопрос", "ответ", "книга", "город", "страна", "семья", "музыка",
            "привет", "мир", "дом", "текст"
        ]
        let englishWords = [
            "machine", "work", "project", "meeting", "message", "email",
            "today", "tomorrow", "now", "later", "person", "time", "question",
            "answer", "book", "city", "country", "family", "music", "hello",
            "world", "house", "text", "layout", "keyboard"
        ]

        let lexicon = SystemLayoutLexicon.shared
        for word in russianWords {
            XCTAssertTrue(lexicon.contains(word, language: .russian), word)
        }
        for word in englishWords {
            XCTAssertTrue(lexicon.contains(word, language: .englishUS), word)
        }
        XCTAssertFalse(lexicon.contains("руддщ", language: .russian))
    }

    func test_productionConfidenceCoversDictionaryPunctuationAndHeuristicFallback() throws {
        let available = Set(NSSpellChecker.shared.availableLanguages)
        guard available.contains("ru"), available.contains("en") else {
            throw XCTSkip("The host does not have both macOS spelling dictionaries installed.")
        }

        let lexicon = SystemLayoutLexicon.shared
        let confidence = LayoutConfidenceEngine()
        let isKnown: (String, KeyboardLayout) -> Bool = { word, language in
            lexicon.contains(word, language: language)
        }

        XCTAssertEqual(
            confidence.automaticCorrection(
                for: "vfibyf",
                typedIn: .englishUS,
                isKnownWord: isKnown
            ),
            LayoutCorrection(replacement: "машина", targetLayout: .russian)
        )
        XCTAssertEqual(
            confidence.automaticCorrection(
                for: "цщкдв",
                typedIn: .russian,
                isKnownWord: isKnown
            ),
            LayoutCorrection(replacement: "world", targetLayout: .englishUS)
        )
        XCTAssertEqual(
            confidence.automaticCorrection(
                for: "руддщ",
                typedIn: .russian,
                isKnownWord: isKnown
            ),
            LayoutCorrection(replacement: "hello", targetLayout: .englishUS)
        )
        XCTAssertEqual(
            confidence.automaticCorrection(
                for: "ьфсршту",
                typedIn: .russian,
                isKnownWord: isKnown
            ),
            LayoutCorrection(replacement: "machine", targetLayout: .englishUS)
        )
        let englishLayoutRussianWords = [
            ("cjj,otybt", "сообщение"),
            (";bpym", "жизнь"),
            ("\\krf", "ёлка"),
            ("'nj", "это"),
            ("k.,jdm", "любовь")
        ]
        for (typed, expected) in englishLayoutRussianWords {
            XCTAssertEqual(
                confidence.automaticCorrection(
                    for: typed,
                    typedIn: .englishUS,
                    isKnownWord: isKnown
                ),
                LayoutCorrection(replacement: expected, targetLayout: .russian),
                typed
            )
        }
        XCTAssertEqual(
            confidence.automaticCorrection(
                for: "ghbdtn,",
                typedIn: .englishUS,
                isKnownWord: isKnown
            ),
            LayoutCorrection(replacement: "привет,", targetLayout: .russian)
        )
        XCTAssertEqual(
            confidence.automaticCorrection(
                for: "hfcrkflrf",
                typedIn: .englishUS,
                isKnownWord: isKnown
            ),
            LayoutCorrection(replacement: "раскладка", targetLayout: .russian)
        )
        XCTAssertNil(
            confidence.automaticCorrection(
                for: "levf.",
                typedIn: .englishUS,
                isKnownWord: isKnown
            ),
            "The suffix is ambiguous: it may mean either 'думаю' or literal 'дума.'."
        )
    }

    func test_productionConfidenceKeepsCorrectAndTechnicalWords() throws {
        let available = Set(NSSpellChecker.shared.availableLanguages)
        guard available.contains("ru"), available.contains("en") else {
            throw XCTSkip("The host does not have both macOS spelling dictionaries installed.")
        }

        let lexicon = SystemLayoutLexicon.shared
        let confidence = LayoutConfidenceEngine()
        let isKnown: (String, KeyboardLayout) -> Bool = { word, language in
            lexicon.contains(word, language: language)
        }

        for word in [
            "hello", "project", "github", "swift", "xcode", "git", "ssh", "curl",
            "brew", "sudo", "docker", "kubectl", "Tim", "Tom", "dna", "nba",
            "ceo", "ide", "chen", "dept", "entre", "abit"
        ] {
            XCTAssertNil(
                confidence.automaticCorrection(
                    for: word,
                    typedIn: .englishUS,
                    isKnownWord: isKnown
                ),
                word
            )
        }
        for word in [
            "привет", "раскладка", "сообщение", "который", "данные", "работает",
            "функция", "почта", "текст", "файл", "мвд", "ввс"
        ] {
            XCTAssertNil(
                confidence.automaticCorrection(
                    for: word,
                    typedIn: .russian,
                    isKnownWord: isKnown
                ),
                word
            )
        }
    }

    func test_productionConfidenceRejectsSpellCheckerFalsePositivesAndNames() throws {
        let available = Set(NSSpellChecker.shared.availableLanguages)
        guard available.contains("ru"), available.contains("en") else {
            throw XCTSkip("The host does not have both macOS spelling dictionaries installed.")
        }

        let lexicon = SystemLayoutLexicon.shared
        let confidence = LayoutConfidenceEngine()
        let isKnown: (String, KeyboardLayout) -> Bool = { word, language in
            lexicon.contains(word, language: language)
        }

        for (word, source) in [
            ("фыва", KeyboardLayout.russian),
            ("йцукен", .russian),
            ("мммм", .russian),
            ("neha", .englishUS),
            ("cath", .englishUS)
        ] {
            XCTAssertNil(
                confidence.automaticCorrection(
                    for: word,
                    typedIn: source,
                    isKnownWord: isKnown
                ),
                word
            )
        }
    }

    func test_productionConfidenceCoversAuditedCommonThreeLetterWords() throws {
        let available = Set(NSSpellChecker.shared.availableLanguages)
        guard available.contains("ru"), available.contains("en") else {
            throw XCTSkip("The host does not have both macOS spelling dictionaries installed.")
        }

        let lexicon = SystemLayoutLexicon.shared
        let confidence = LayoutConfidenceEngine()
        let isKnown: (String, KeyboardLayout) -> Bool = { word, language in
            lexicon.contains(word, language: language)
        }
        let cases: [(String, KeyboardLayout, String, KeyboardLayout)] = [
            ("ytn", .englishUS, "нет", .russian),
            ("lkz", .englishUS, "для", .russian),
            ("vyt", .englishUS, "мне", .russian),
            ("dfc", .englishUS, "вас", .russian),
            ("нуы", .russian, "yes", .englishUS),
            ("црн", .russian, "why", .englishUS),
            ("вшв", .russian, "did", .englishUS),
            ("пще", .russian, "got", .englishUS)
        ]

        for (word, source, replacement, target) in cases {
            XCTAssertEqual(
                confidence.automaticCorrection(
                    for: word,
                    typedIn: source,
                    isKnownWord: isKnown
                ),
                LayoutCorrection(replacement: replacement, targetLayout: target),
                word
            )
        }
    }

    func test_systemLexiconPreservesSignificantNameCapitalization() throws {
        let checker = NSSpellChecker.shared
        let language = "en"
        guard checker.availableLanguages.contains(language) else {
            throw XCTSkip("The host does not have the macOS English spelling dictionary installed.")
        }

        func isSpelledCorrectly(_ word: String) -> Bool {
            checker.checkSpelling(
                of: word,
                startingAt: 0,
                language: language,
                wrap: false,
                inSpellDocumentWithTag: 0,
                wordCount: nil
            ).location == NSNotFound
        }

        guard isSpelledCorrectly("Tim"), !isSpelledCorrectly("tim") else {
            throw XCTSkip("This host dictionary does not distinguish Tim from tim.")
        }
        XCTAssertTrue(SystemLayoutLexicon.shared.contains("Tim", language: .englishUS))
        XCTAssertFalse(SystemLayoutLexicon.shared.contains("tim", language: .englishUS))
    }
}
