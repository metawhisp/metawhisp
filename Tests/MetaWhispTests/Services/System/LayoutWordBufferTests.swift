import XCTest
@testable import MetaWhisp

final class LayoutWordBufferTests: XCTestCase {
    func test_emitsBufferedWordOnlyAfterASingleSeparator() {
        var buffer = LayoutWordBuffer()

        for character in "ghbdtn" {
            XCTAssertNil(buffer.record(String(character), source: .englishUS))
        }

        XCTAssertEqual(
            buffer.record(" ", source: .englishUS),
            LayoutBufferedToken(
                token: "ghbdtn",
                convertedToken: "привет",
                source: .englishUS,
                trailingText: " "
            )
        )
    }

    func test_sourceChangeAndEditingCharactersDiscardThePendingWord() {
        var buffer = LayoutWordBuffer()
        _ = buffer.record("g", source: .englishUS)
        _ = buffer.record("h", source: .englishUS)

        XCTAssertNil(buffer.record("б", source: .russian))
        XCTAssertNil(buffer.record(" ", source: .russian))

        _ = buffer.record("g", source: .englishUS)
        XCTAssertNil(buffer.record("1", source: .englishUS))
        XCTAssertNil(buffer.record(" ", source: .englishUS))
    }

    func test_capsLongWordsAndAcceptsPunctuationAsTheTrailingText() {
        var buffer = LayoutWordBuffer(maxTokenLength: 3)
        _ = buffer.record("g", source: .englishUS)
        _ = buffer.record("h", source: .englishUS)
        _ = buffer.record("b", source: .englishUS)
        XCTAssertNil(buffer.record("d", source: .englishUS))
        XCTAssertNil(buffer.record(" ", source: .englishUS))

        for character in "gh" {
            XCTAssertNil(buffer.record(String(character), source: .englishUS))
        }
        XCTAssertEqual(
            buffer.record("!", source: .englishUS),
            LayoutBufferedToken(
                token: "gh",
                convertedToken: "пр",
                source: .englishUS,
                trailingText: "!"
            )
        )
    }

    func test_keepsPhysicalRussianLetterKeysInsideEnglishLayoutToken() {
        var buffer = LayoutWordBuffer()

        for character in "cjj,otybt" {
            XCTAssertNil(buffer.record(String(character), source: .englishUS))
        }

        XCTAssertEqual(
            buffer.record(" ", source: .englishUS),
            LayoutBufferedToken(
                token: "cjj,otybt",
                convertedToken: "сообщение",
                source: .englishUS,
                trailingText: " "
            )
        )
    }

    func test_keepsAmbiguousTrailingPunctuationUntilWhitespace() {
        var buffer = LayoutWordBuffer()

        for character in "ghbdtn," {
            XCTAssertNil(buffer.record(String(character), source: .englishUS))
        }

        XCTAssertEqual(
            buffer.record(" ", source: .englishUS),
            LayoutBufferedToken(
                token: "ghbdtn,",
                convertedToken: "приветб",
                source: .englishUS,
                trailingText: " "
            )
        )
    }

    func test_recordsRealPhysicalKeycodesForAppleRussianLetterKeys() throws {
        let mapper = KeyboardLayoutMapper.russianEnglish
        guard mapper.isAvailable else {
            throw XCTSkip("The host does not have both US and Russian keyboard layouts enabled.")
        }
        var buffer = LayoutWordBuffer()
        let strokes: [(String, UInt16)] = [
            ("\\", 42), ("k", 40), ("r", 15), ("f", 3)
        ]

        for (text, keyCode) in strokes {
            XCTAssertNil(
                buffer.record(
                    text,
                    keyCode: keyCode,
                    flags: [],
                    source: .englishUS,
                    mapper: mapper
                )
            )
        }

        XCTAssertEqual(
            buffer.record(
                " ",
                keyCode: 49,
                flags: [],
                source: .englishUS,
                mapper: mapper
            ),
            LayoutBufferedToken(
                token: "\\krf",
                convertedToken: "ёлка",
                source: .englishUS,
                trailingText: " "
            )
        )
    }
}
