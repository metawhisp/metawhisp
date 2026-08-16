import XCTest
@testable import MetaWhisp

final class LayoutConfidenceEngineTests: XCTestCase {
    private let mapper = KeyboardLayoutMapper.russianEnglish
    private let confidence = LayoutConfidenceEngine()

    func test_convertEnglishTypingToRussianPreservesLetterCaseAndPunctuation() {
        XCTAssertEqual(
            mapper.convert("GHBDTN!", from: .englishUS),
            "ПРИВЕТ!"
        )
    }

    func test_convertRussianTypingToEnglish() {
        XCTAssertEqual(
            mapper.convert("руддщ", from: .russian),
            "hello"
        )
    }

    func test_manualConversionPreservesSentenceSeparatorsInBothDirections() {
        XCTAssertEqual(
            mapper.convertText("ghbdtn rfr ltkf!", from: .englishUS),
            "привет как дела!"
        )
        XCTAssertEqual(
            mapper.convertText("руддщ цщкдв", from: .russian),
            "hello world"
        )
    }

    func test_manualConversionPreservesNewlinesAndUnsupportedCharacters() {
        XCTAssertEqual(
            mapper.convertText("ghbdtn\n🙂 vbh", from: .englishUS),
            "привет\n🙂 мир"
        )
    }

    func test_systemMapperUsesTheActualAppleRussianPhysicalKeys() throws {
        guard mapper.isAvailable else {
            throw XCTSkip("The host does not have both US and Russian keyboard layouts enabled.")
        }

        XCTAssertEqual(mapper.convert("\\krf", from: .englishUS), "ёлка")
        XCTAssertEqual(mapper.convert("^&?", from: .englishUS), ",.?")
        XCTAssertEqual(mapper.convert("№", from: .russian), "#")
    }

    func test_manualConversionUsesPhysicalPunctuationAndPreservesUnsupportedText() {
        XCTAssertEqual(
            mapper.convertText("ghbdtn? #1", from: .englishUS),
            "привет? №1"
        )
        XCTAssertEqual(
            mapper.convertText(";bpym", from: .englishUS),
            "жизнь"
        )
        XCTAssertEqual(
            mapper.convertText("руддщ, №1", from: .russian),
            "hello^ #1"
        )
    }

    func test_manualConversionDetectsSourceFromTextInsteadOfCurrentInputSource() {
        XCTAssertEqual(
            mapper.sourceLayout(for: "ghbdtn rfr", fallback: .russian),
            .englishUS
        )
        XCTAssertEqual(
            mapper.sourceLayout(for: "руддщ цщкдв", fallback: .englishUS),
            .russian
        )
        XCTAssertEqual(
            mapper.sourceLayout(for: "123 🙂", fallback: .russian),
            .russian
        )
    }

    func test_manualConversionRejectsMixedScriptWhenDirectionMustBeUnambiguous() {
        XCTAssertNil(
            mapper.unambiguousSourceLayout(
                for: "Hello world руддщ",
                fallback: .englishUS
            )
        )
        XCTAssertEqual(
            mapper.unambiguousSourceLayout(
                for: "ghbdtn rfr",
                fallback: .russian
            ),
            .englishUS
        )
        XCTAssertEqual(
            mapper.unambiguousSourceLayout(
                for: "123 🙂",
                fallback: .russian
            ),
            .russian
        )
    }

    func test_convertRejectsTokenWithUnsupportedCharacter() {
        XCTAssertNil(mapper.convert("ghbdtn🙂", from: .englishUS))
    }

    func test_automaticCorrectionRecognizesWrongEnglishLayoutForRussianWord() {
        XCTAssertEqual(
            confidence.automaticCorrection(for: "ghbdtn", typedIn: .englishUS),
            LayoutCorrection(replacement: "привет", targetLayout: .russian)
        )
    }

    func test_automaticCorrectionRecognizesWrongRussianLayoutForEnglishWord() {
        XCTAssertEqual(
            confidence.automaticCorrection(for: "руддщ", typedIn: .russian),
            LayoutCorrection(replacement: "hello", targetLayout: .englishUS)
        )
    }

    func test_automaticCorrectionDoesNotAlterKnownEnglishWord() {
        XCTAssertNil(confidence.automaticCorrection(for: "hello", typedIn: .englishUS))
    }

    func test_automaticCorrectionDoesNotAlterKnownRussianWord() {
        XCTAssertNil(confidence.automaticCorrection(for: "привет", typedIn: .russian))
    }

    func test_automaticCorrectionRejectsLowConfidenceKeyboardRow() {
        XCTAssertNil(confidence.automaticCorrection(for: "asdf", typedIn: .englishUS))
    }

    func test_automaticCorrectionRejectsTwoLetterAmbiguity() {
        let known: (String, KeyboardLayout) -> Bool = { word, language in
            word == "во" && language == .russian
        }

        XCTAssertNil(
            confidence.automaticCorrection(
                for: "dj",
                typedIn: .englishUS,
                isKnownWord: known
            )
        )
    }

    func test_automaticCorrectionAllowsOnlyAuditedThreeLetterTargets() {
        let known: (String, KeyboardLayout) -> Bool = { word, language in
            switch language {
            case .englishUS:
                return word.lowercased() == "the"
            case .russian:
                return ["мир", "это", "втф", "сущ", "шву"].contains(word.lowercased())
            }
        }

        XCTAssertEqual(
            confidence.automaticCorrection(
                for: "vbh",
                typedIn: .englishUS,
                isKnownWord: known
            ),
            LayoutCorrection(replacement: "мир", targetLayout: .russian)
        )
        XCTAssertEqual(
            confidence.automaticCorrection(
                for: "Vbh",
                typedIn: .englishUS,
                isKnownWord: known
            ),
            LayoutCorrection(replacement: "Мир", targetLayout: .russian)
        )
        XCTAssertEqual(
            confidence.automaticCorrection(
                for: "'nj",
                typedIn: .englishUS,
                isKnownWord: known
            ),
            LayoutCorrection(replacement: "это", targetLayout: .russian)
        )
        XCTAssertEqual(
            confidence.automaticCorrection(
                for: "еру",
                typedIn: .russian,
                isKnownWord: known
            ),
            LayoutCorrection(replacement: "the", targetLayout: .englishUS)
        )

        for word in ["dna", "ceo", "ide"] {
            XCTAssertNil(
                confidence.automaticCorrection(
                    for: word,
                    typedIn: .englishUS,
                    isKnownWord: known
                ),
                word
            )
        }
    }

    func test_automaticCorrectionAllowsAuditedCommonThreeLetterTarget() {
        let known: (String, KeyboardLayout) -> Bool = { word, language in
            word == "нет" && language == .russian
        }

        XCTAssertEqual(
            confidence.automaticCorrection(
                for: "ytn",
                typedIn: .englishUS,
                isKnownWord: known
            ),
            LayoutCorrection(replacement: "нет", targetLayout: .russian)
        )
    }

    func test_automaticCorrectionRejectsUnauditedThreeLetterTarget() {
        let known: (String, KeyboardLayout) -> Bool = { word, language in
            word == "age" && language == .englishUS
        }

        XCTAssertNil(
            confidence.automaticCorrection(
                for: "фпу",
                typedIn: .russian,
                isKnownWord: known
            )
        )
    }

    func test_dynamicAppleLetterKeyCanRemainLiteralTrailingPunctuation() {
        let known: (String, KeyboardLayout) -> Bool = { word, language in
            word == "привет" && language == .russian
        }

        XCTAssertEqual(
            confidence.automaticCorrection(
                for: "ghbdtn\\",
                convertedTo: "приветё",
                typedIn: .englishUS,
                isKnownWord: known
            ),
            LayoutCorrection(replacement: "привет\\", targetLayout: .russian)
        )
    }

    func test_dynamicAppleLetterKeyAmbiguityFailsClosed() {
        let known: (String, KeyboardLayout) -> Bool = { word, language in
            ["привет", "приветё"].contains(word) && language == .russian
        }

        XCTAssertNil(
            confidence.automaticCorrection(
                for: "ghbdtn\\",
                convertedTo: "приветё",
                typedIn: .englishUS,
                isKnownWord: known
            )
        )
    }

    func test_automaticCorrectionRejectsEveryObservedFrequencyCorpusCollision() {
        let englishToRussian = [
            ("dna", "втф"), ("tim", "ешь"), ("nba", "тиф"), ("ceo", "сущ"),
            ("nec", "тус"), ("ghz", "пря"), ("gen", "пут"), ("cfr", "сак"),
            ("rec", "кус"), ("ide", "шву"), ("buf", "ига"), ("gba", "пиф"),
            ("chen", "срут"), ("len", "дут"), ("dept", "вузе"), ("eds", "увы"),
            ("vcr", "мск"), ("abu", "фиг"), ("gtk", "пел"), ("rel", "куд"),
            ("att", "фее"), ("che", "сру"), ("det", "вуе"), ("ctr", "сек"),
            ("hsn", "рыт"), ("rdf", "ква"), ("cbc", "сис"), ("dst", "вые"),
            ("ger", "пук"), ("dep", "вуз"), ("abn", "фит"), ("rey", "кун"),
            ("thb", "ери"), ("ita", "шеф"), ("cbd", "сив"), ("afl", "фад"),
            ("rfp", "каз"), ("itk", "шел"), ("entre", "утеку"), ("gev", "пум"),
            ("ren", "кут"), ("neu", "туг"), ("ect", "усе"), ("afc", "фас"),
            ("ecs", "усы"), ("pps", "ззы"), ("aff", "фаа"), ("utp", "гез"),
            ("ibn", "шит"), ("ctx", "сеч"), ("fha", "арф"), ("tls", "еды"),
            ("abit", "фише")
        ]
        let russianToEnglish = [("мвд", "vdl"), ("ввс", "ddc")]
        let knownRussianTargets = Set(englishToRussian.map(\.1))
        let knownEnglishTargets = Set(russianToEnglish.map(\.1))
        let known: (String, KeyboardLayout) -> Bool = { word, language in
            switch language {
            case .englishUS: knownEnglishTargets.contains(word.lowercased())
            case .russian: knownRussianTargets.contains(word.lowercased())
            }
        }

        for (source, _) in englishToRussian {
            XCTAssertNil(
                confidence.automaticCorrection(
                    for: source,
                    typedIn: .englishUS,
                    isKnownWord: known
                ),
                source
            )
        }
        for (source, _) in russianToEnglish {
            XCTAssertNil(
                confidence.automaticCorrection(
                    for: source,
                    typedIn: .russian,
                    isKnownWord: known
                ),
                source
            )
        }
    }

    func test_automaticCorrectionPreservesOriginalCaseForSourceValidation() {
        var validatedSourceWords: [String] = []
        let known: (String, KeyboardLayout) -> Bool = { word, language in
            switch language {
            case .englishUS:
                validatedSourceWords.append(word)
                return word == "Test"
            case .russian:
                return word.lowercased() == "еуые"
            }
        }

        XCTAssertNil(
            confidence.automaticCorrection(
                for: "Test",
                typedIn: .englishUS,
                isKnownWord: known
            )
        )
        XCTAssertEqual(validatedSourceWords, ["Test"])
    }

    func test_automaticCorrectionRejectsAllCapsAcronym() {
        let known: (String, KeyboardLayout) -> Bool = { word, language in
            word.lowercased() == "привет" && language == .russian
        }

        XCTAssertNil(
            confidence.automaticCorrection(
                for: "GHBDTN",
                typedIn: .englishUS,
                isKnownWord: known
            )
        )
    }
}
