import XCTest
@testable import MetaWhisp

/// ITER-060 Phase 1 — pins the three measured garbage classes (2026-08-07
/// audit: 863 cross-channel echo duplicates, 410 repetition runs, 2-5 foreign
/// fragments per meeting) and every corner case agreed with the user.
final class MeetingTranscriptSanitizerTests: XCTestCase {

    private typealias S = MeetingTranscriptSanitizer

    private func seg(_ text: String, _ start: Double, _ end: Double, _ speaker: Speaker) -> StreamSegment {
        StreamSegment(text: text, startSec: start, endSec: end, speaker: speaker)
    }

    // MARK: - collapseRepetitionLoops

    func test_collapse_wordLoop() {
        XCTAssertEqual(S.collapseRepetitionLoops("как как как как будет"), "как будет")
    }

    func test_collapse_phraseLoop() {
        XCTAssertEqual(
            S.collapseRepetitionLoops("я думаю что я думаю что я думаю что"),
            "я думаю что"
        )
    }

    func test_collapse_naturalDoubleKept() {
        // Live speech: doubles are natural, threshold is 3+.
        XCTAssertEqual(S.collapseRepetitionLoops("да да согласен"), "да да согласен")
        XCTAssertEqual(S.collapseRepetitionLoops("очень очень хорошо"), "очень очень хорошо")
    }

    func test_collapse_punctuationInsensitiveKeepsFirstFormatting() {
        XCTAssertEqual(S.collapseRepetitionLoops("Как, как, как, так вышло"), "Как, так вышло")
    }

    func test_collapse_speechAroundLoopSurvives() {
        // Майские грабли: реальная речь вокруг петли не должна теряться.
        XCTAssertEqual(
            S.collapseRepetitionLoops("мы решили что надо надо надо надо задеплоить в пятницу"),
            "мы решили что надо задеплоить в пятницу"
        )
    }

    func test_collapse_cleanTextUntouched() {
        let clean = "обычная фраза без повторов вообще"
        XCTAssertEqual(S.collapseRepetitionLoops(clean), clean)
    }

    func test_collapse_idempotent() {
        let once = S.collapseRepetitionLoops("как как как как будет")
        XCTAssertEqual(S.collapseRepetitionLoops(once), once)
    }

    // MARK: - dedupeConsecutiveIdentical

    func test_consecutiveIdentical_collapsed() {
        // «Окей.» ×5 as separate utterances — decoder loop across boundaries.
        let segs = (0..<5).map { seg("Окей.", Double($0), Double($0) + 0.5, .them) }
        var dropped: [S.Drop] = []
        let kept = S.dedupeConsecutiveIdentical(segs, dropped: &dropped)
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(dropped.count, 4)
        XCTAssertTrue(dropped.allSatisfy { $0.reason == "consecutive-duplicate" })
    }

    func test_consecutiveIdentical_legitimateRepeatMinutesApartKept() {
        let segs = [
            seg("Окей.", 10, 11, .them),
            seg("Окей.", 300, 301, .them),
        ]
        var dropped: [S.Drop] = []
        XCTAssertEqual(S.dedupeConsecutiveIdentical(segs, dropped: &dropped).count, 2)
        XCTAssertTrue(dropped.isEmpty)
    }

    func test_consecutiveIdentical_differentSpeakersKept() {
        // Both speakers really do say "Окей" near each other.
        let segs = [seg("Окей.", 10, 11, .them), seg("Окей.", 12, 13, .me)]
        var dropped: [S.Drop] = []
        XCTAssertEqual(S.dedupeConsecutiveIdentical(segs, dropped: &dropped).count, 2)
        XCTAssertTrue(dropped.isEmpty)
    }

    // MARK: - dedupeCrossChannelEcho

    func test_echo_exactDuplicateMeDropped() {
        let segs = [
            seg("давайте задеплоим это в пятницу вечером", 100, 103, .them),
            seg("давайте задеплоим это в пятницу вечером", 101, 104, .me),
        ]
        var dropped: [S.Drop] = []
        let kept = S.dedupeCrossChannelEcho(segs, dropped: &dropped)
        XCTAssertEqual(kept.map(\.speaker), [.them])
        XCTAssertEqual(dropped.first?.reason, "cross-channel-echo")
    }

    func test_echo_fuzzyGarbledCopyDropped() {
        // Echo is recognized with distortions — exact match would miss it.
        let segs = [
            seg("давайте задеплоим это в пятницу вечером", 100, 103, .them),
            seg("давайте задиплоят это в пятницу вечером", 101, 104, .me),
        ]
        var dropped: [S.Drop] = []
        let kept = S.dedupeCrossChannelEcho(segs, dropped: &dropped)
        XCTAssertEqual(kept.map(\.speaker), [.them])
    }

    func test_echo_shortBackchannelKept() {
        // «Да», «Окей» — оба реально говорят рядом; <4 слов не дедупим.
        let segs = [
            seg("Да, окей", 100, 101, .them),
            seg("Да, окей", 100.5, 101.5, .me),
        ]
        var dropped: [S.Drop] = []
        XCTAssertEqual(S.dedupeCrossChannelEcho(segs, dropped: &dropped).count, 2)
    }

    func test_echo_deliberateRepeatLaterKept() {
        // Осознанный повтор фразы собеседника приходит ПОЗЖЕ окна эха.
        let segs = [
            seg("нам нужно закрыть этот контракт до конца месяца", 100, 104, .them),
            seg("нам нужно закрыть этот контракт до конца месяца", 112, 116, .me),
        ]
        var dropped: [S.Drop] = []
        XCTAssertEqual(S.dedupeCrossChannelEcho(segs, dropped: &dropped).count, 2)
        XCTAssertTrue(dropped.isEmpty)
    }

    func test_echo_meLongerThanThemKept() {
        // Обратное эхо: если Me-копия заметно ПОЛНЕЕ — не удаляем (это может
        // быть моя реальная речь, вернувшаяся огрызком в Them-канал).
        let segs = [
            seg("закрыть контракт до конца", 100, 102, .them),
            seg("нам обязательно нужно закрыть этот большой контракт до конца месяца", 100.5, 105, .me),
        ]
        var dropped: [S.Drop] = []
        XCTAssertEqual(S.dedupeCrossChannelEcho(segs, dropped: &dropped).count, 2)
    }

    func test_echo_headphonesNoOp() {
        // Наушники: дублей нет — ничего не удаляется.
        let segs = [
            seg("расскажи про статус проекта", 10, 12, .them),
            seg("статус такой мы почти закончили интеграцию", 13, 17, .me),
        ]
        var dropped: [S.Drop] = []
        XCTAssertEqual(S.dedupeCrossChannelEcho(segs, dropped: &dropped).count, 2)
        XCTAssertTrue(dropped.isEmpty)
    }

    func test_echo_partialOverlapBelowThresholdKept() {
        // Эхо-хвост приклеился к моей реальной фразе — совпадение <80%, целиком не удаляем.
        let segs = [
            seg("мы подпишем договор на следующей неделе после юристов", 100, 104, .them),
            seg("угу да кстати про юристов я им уже написал утром", 102, 106, .me),
        ]
        var dropped: [S.Drop] = []
        XCTAssertEqual(S.dedupeCrossChannelEcho(segs, dropped: &dropped).count, 2)
    }

    // MARK: - filterForeignFragments

    /// 12 confident Russian utterances — enough statistics for the filter.
    private func russianMeeting() -> [StreamSegment] {
        let phrases = [
            "давайте обсудим планы на следующую неделю",
            "мне кажется нужно перенести релиз на понедельник",
            "команда закончила интеграцию платежей вчера вечером",
            "остались вопросы по дизайну главного экрана",
            "пользователи жалуются на медленную загрузку",
            "предлагаю созвониться завтра в одиннадцать утра",
            "бюджет на маркетинг утвердили без изменений",
            "нужно обновить документацию перед демо",
            "тестировщики нашли три критичных бага",
            "апдейт выкатим сначала на десять процентов",
            "метрики удержания выросли за последний месяц",
            "договорились возвращаемся к этому в пятницу",
        ]
        return phrases.enumerated().map { i, t in seg(t, Double(i * 10), Double(i * 10 + 5), i % 2 == 0 ? .me : .them) }
    }

    func test_foreign_shortFragmentDropped() {
        var segs = russianMeeting()
        segs.append(seg("Gracias por ver el video", 130, 132, .them))
        var dropped: [S.Drop] = []
        let kept = S.filterForeignFragments(segs, dropped: &dropped)
        XCTAssertEqual(kept.count, segs.count - 1)
        XCTAssertEqual(dropped.count, 1)
        XCTAssertTrue(dropped[0].reason.hasPrefix("foreign-language-fragment"))
    }

    func test_foreign_longUtteranceNeverDropped() {
        // Собеседник реально заговорил на третьем языке — 6+ слов не трогаем.
        var segs = russianMeeting()
        segs.append(seg("Hola queria comentar el estado del proyecto antes de terminar la reunion", 130, 136, .them))
        var dropped: [S.Drop] = []
        XCTAssertEqual(S.filterForeignFragments(segs, dropped: &dropped).count, segs.count)
        XCTAssertTrue(dropped.isEmpty)
    }

    func test_foreign_bilingualMeetingBothLanguagesKept() {
        // 50/50 RU/EN митинг: оба языка доминантные, между ними не фильтруем.
        var segs: [StreamSegment] = []
        let ru = [
            "давайте начнем с обзора спринта",
            "у нас осталось два дня до дедлайна",
            "нужно согласовать бюджет с финансами",
            "команда работает над новой фичей",
            "отчет будет готов к вечеру пятницы",
            "созвонимся завтра в то же время",
        ]
        let en = [
            "let me share my screen with the roadmap",
            "we shipped the new onboarding flow yesterday",
            "the metrics look good for this quarter",
            "please review the pull request today",
            "our customers love the latest update",
            "the deadline moved to next monday morning",
        ]
        for (i, t) in (ru + en).enumerated() {
            segs.append(seg(t, Double(i * 10), Double(i * 10 + 5), i % 2 == 0 ? .me : .them))
        }
        segs.append(seg("what do you think about this", 300, 302, .them))
        var dropped: [S.Drop] = []
        XCTAssertEqual(S.filterForeignFragments(segs, dropped: &dropped).count, segs.count)
        XCTAssertTrue(dropped.isEmpty)
    }

    func test_foreign_shortMeetingFilterOff() {
        // <10 фраз — статистики нет, фильтр выключен даже для явного чужого языка.
        let segs = [
            seg("привет как дела", 0, 2, .me),
            seg("нормально спасибо", 3, 5, .them),
            seg("Gracias por ver", 6, 7, .them),
        ]
        var dropped: [S.Drop] = []
        XCTAssertEqual(S.filterForeignFragments(segs, dropped: &dropped).count, 3)
        XCTAssertTrue(dropped.isEmpty)
    }

    // MARK: - sanitize (pipeline)

    func test_sanitize_cleanTranscriptIdempotent() {
        let segs = russianMeeting()
        let first = S.sanitize(segs)
        XCTAssertEqual(first.kept, segs)
        XCTAssertTrue(first.dropped.isEmpty)
        let second = S.sanitize(first.kept)
        XCTAssertEqual(second.kept, first.kept)
    }

    func test_sanitize_combinedGarbageAllThreeClassesDropped() {
        var segs = russianMeeting()
        // echo pair
        segs.append(seg("мы решили перенести встречу на среду утром", 200, 203, .them))
        segs.append(seg("мы решили перенести встречу на среду утром", 201, 204, .me))
        // consecutive duplicates
        segs.append(seg("Хорошо.", 210, 211, .them))
        segs.append(seg("Хорошо.", 212, 213, .them))
        segs.append(seg("Хорошо.", 214, 215, .them))
        // foreign fragment
        segs.append(seg("Gracias por ver el video", 220, 222, .them))
        let result = S.sanitize(segs.sorted { $0.startSec < $1.startSec })
        let reasons = Set(result.dropped.map { $0.reason.components(separatedBy: " ").first! })
        XCTAssertTrue(reasons.contains("cross-channel-echo"))
        XCTAssertTrue(reasons.contains("consecutive-duplicate"))
        XCTAssertTrue(reasons.contains("foreign-language-fragment"))
        XCTAssertEqual(result.dropped.count, 4) // 1 echo + 2 dup + 1 foreign
    }

    // MARK: - tokenSimilarity

    func test_tokenSimilarity_bounds() {
        XCTAssertEqual(S.tokenSimilarity(["a", "b"], ["a", "b"]), 1.0)
        XCTAssertEqual(S.tokenSimilarity(["a"], ["b"]), 0.0)
        XCTAssertEqual(S.tokenSimilarity([], ["b"]), 0.0)
    }
}
