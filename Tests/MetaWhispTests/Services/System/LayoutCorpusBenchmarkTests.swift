import AppKit
import XCTest
@testable import MetaWhisp

@MainActor
final class LayoutCorpusBenchmarkTests: XCTestCase {
    /// Optional release preflight over external, pinned frequency lists. The
    /// corpora are test inputs only and are never bundled with MetaWhisp.
    func test_externalFrequencyCorporaHaveNoObservedFalseCorrections() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let englishPath = environment["METAWHISP_EN_CORPUS"],
              let russianPath = environment["METAWHISP_RU_CORPUS"],
              let englishText = try? String(contentsOfFile: englishPath, encoding: .utf8),
              let russianText = try? String(contentsOfFile: russianPath, encoding: .utf8) else {
            throw XCTSkip("Set METAWHISP_EN_CORPUS and METAWHISP_RU_CORPUS for corpus preflight.")
        }

        let mapper = KeyboardLayoutMapper.russianEnglish
        guard mapper.isAvailable else {
            throw XCTSkip("The exact US and Russian macOS layouts are required.")
        }
        let lexicon = SystemLayoutLexicon.shared
        let engine = LayoutConfidenceEngine(mapper: mapper)
        let isKnown: (String, KeyboardLayout) -> Bool = { word, language in
            lexicon.contains(word, language: language)
        }

        let englishWords = corpusWords(in: englishText, layout: .englishUS)
        let russianWords = corpusWords(in: russianText, layout: .russian)
        var observedFalseCorrections: [String] = []
        var eligibleWrongLayoutWords = 0
        var correctedWrongLayoutWords = 0

        for word in englishWords {
            if engine.automaticCorrection(
                for: word,
                typedIn: .englishUS,
                isKnownWord: isKnown
            ) != nil {
                observedFalseCorrections.append("EN:\(word)")
            }
            guard let wrongLayout = mapper.convert(word, from: .englishUS) else { continue }
            eligibleWrongLayoutWords += 1
            if engine.automaticCorrection(
                for: wrongLayout,
                convertedTo: word,
                typedIn: .russian,
                isKnownWord: isKnown
            )?.replacement == word {
                correctedWrongLayoutWords += 1
            }
        }

        for word in russianWords {
            if engine.automaticCorrection(
                for: word,
                typedIn: .russian,
                isKnownWord: isKnown
            ) != nil {
                observedFalseCorrections.append("RU:\(word)")
            }
            guard let wrongLayout = mapper.convert(word, from: .russian) else { continue }
            eligibleWrongLayoutWords += 1
            if engine.automaticCorrection(
                for: wrongLayout,
                convertedTo: word,
                typedIn: .englishUS,
                isKnownWord: isKnown
            )?.replacement == word {
                correctedWrongLayoutWords += 1
            }
        }

        let recall = eligibleWrongLayoutWords == 0
            ? 0
            : Double(correctedWrongLayoutWords) / Double(eligibleWrongLayoutWords)
        print(
            "Layout corpus: correct=\(englishWords.count + russianWords.count) "
                + "false=\(observedFalseCorrections) eligible=\(eligibleWrongLayoutWords) "
                + "fixed=\(correctedWrongLayoutWords) recall=\(recall)"
        )
        XCTAssertTrue(observedFalseCorrections.isEmpty, observedFalseCorrections.joined(separator: ", "))
        XCTAssertGreaterThanOrEqual(recall, 0.85)
    }

    private func corpusWords(in text: String, layout: KeyboardLayout) -> [String] {
        text.split(whereSeparator: \Character.isNewline)
            .map { String($0).precomposedStringWithCanonicalMapping.lowercased() }
            .filter { word in
                (3...24).contains(word.count) && word.allSatisfy { character in
                    switch layout {
                    case .englishUS:
                        character.isASCII && character.isLetter
                    case .russian:
                        character.unicodeScalars.allSatisfy {
                            (0x0400...0x04FF).contains($0.value)
                        }
                    }
                }
            }
    }
}
