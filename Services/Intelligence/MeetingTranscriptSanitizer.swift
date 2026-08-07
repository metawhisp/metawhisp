import Foundation
import NaturalLanguage

/// Pure text-level cleanup for the finalize meeting-transcript path (ITER-060
/// Phase 1). Три измеренных класса мусора на 114 реальных транскриптах
/// (2026-08-07 аудит): 863 кросс-канальных эхо-дубля, 410 повторных петель,
/// 2-5 иноязычных обрывков на митинг. Каждый шаг возвращает выброшенное с
/// причиной — владелец (AppDelegate) пишет это в SuspectTranscriptLog, ничего
/// не удаляется молча.
enum MeetingTranscriptSanitizer {

    struct SanitizeResult: Equatable {
        var kept: [StreamSegment]
        var dropped: [Drop]
    }

    struct Drop: Equatable {
        let segment: StreamSegment
        let reason: String
    }

    // MARK: - Repetition-loop collapse (per utterance)

    /// Collapse a decoder stutter-loop — the same 1-4-word n-gram repeated 3+
    /// times CONSECUTIVELY — down to its first instance. «как как как как
    /// будет» → «как будет»; «я думаю что я думаю что я думаю что» → «я думаю
    /// что». Natural doubles («да да», «очень-очень») are untouched (threshold
    /// is 3). Comparison is case/punctuation-insensitive; the FIRST instance's
    /// original formatting is what survives.
    static func collapseRepetitionLoops(_ text: String) -> String {
        let tokens = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard tokens.count >= 3 else { return text }
        func norm(_ s: String) -> String {
            s.lowercased().trimmingCharacters(in: .punctuationCharacters)
        }
        let normed = tokens.map(norm)
        var out: [String] = []
        var i = 0
        var collapsed = false
        while i < tokens.count {
            var advanced = false
            // Longest gram first so a phrase loop wins over its inner word loop.
            for gram in stride(from: 4, through: 1, by: -1) {
                guard i + gram * 3 <= tokens.count else { continue }
                let pattern = Array(normed[i ..< i + gram])
                // A pattern that is pure punctuation after normalization can't loop.
                guard pattern.contains(where: { !$0.isEmpty }) else { continue }
                var runs = 1
                var j = i + gram
                while j + gram <= tokens.count, Array(normed[j ..< j + gram]) == pattern {
                    runs += 1
                    j += gram
                }
                if runs >= 3 {
                    out.append(contentsOf: tokens[i ..< i + gram]) // keep first instance
                    i += gram * runs
                    collapsed = true
                    advanced = true
                    break
                }
            }
            if !advanced {
                out.append(tokens[i])
                i += 1
            }
        }
        return collapsed ? out.joined(separator: " ") : text
    }

    // MARK: - Full sanitize pipeline (merged segments)

    /// Run all cross-segment cleanups in order: consecutive-identical dedup →
    /// cross-channel echo dedup → foreign-fragment filter.
    static func sanitize(_ merged: [StreamSegment]) -> SanitizeResult {
        var dropped: [Drop] = []
        var kept = dedupeConsecutiveIdentical(merged, dropped: &dropped)
        kept = dedupeCrossChannelEcho(kept, dropped: &dropped)
        kept = filterForeignFragments(kept, dropped: &dropped)
        return SanitizeResult(kept: kept, dropped: dropped)
    }

    // MARK: - Consecutive identical utterances («Окей.» ×5 as separate segments)

    /// Collapse runs of the SAME normalized text from the SAME speaker within a
    /// short window (decoder loop across utterance boundaries). Keeps the first.
    /// A legitimate repeat minutes later survives via the 30s gap guard.
    private static let consecutiveDedupMaxGapSec: Double = 30

    static func dedupeConsecutiveIdentical(_ segments: [StreamSegment], dropped: inout [Drop]) -> [StreamSegment] {
        var kept: [StreamSegment] = []
        for seg in segments {
            if let prev = kept.last,
               prev.speaker == seg.speaker,
               seg.startSec - prev.startSec <= consecutiveDedupMaxGapSec {
                let a = normalizedTokens(prev.text)
                let b = normalizedTokens(seg.text)
                if !a.isEmpty, a == b {
                    dropped.append(Drop(segment: seg, reason: "consecutive-duplicate"))
                    continue
                }
            }
            kept.append(seg)
        }
        return kept
    }

    // MARK: - Cross-channel echo dedup (speakers → mic bleed)

    /// The мик слышит динамики: собеседник's speech shows up a second time as a
    /// garbled «Me:» copy. Решение юзера (2026-08-07): при совпадении удаляется
    /// ВСЕГДА Me-копия — системный канал чистый цифровой сигнал, микрофонная
    /// версия — искажённое эхо.
    ///
    /// Guards (corner cases согласованы):
    /// - ≥4 слов — «Да»/«Окей» оба говорят рядом, короткое не дедупим;
    /// - similarity ≥0.8 по нормализованным токенам — эхо распознаётся с
    ///   искажениями, точное равенство не поймало бы;
    /// - Me-копия НЕ заметно длиннее Them (×1.5) — иначе это может быть
    ///   обратное эхо (мой голос вернулся через канал собеседника), удалять
    ///   Me значило бы терять мою реальную речь;
    /// - окно startSec: Me в [themStart − 2, themStart + 6] — эхо приходит
    ///   почти мгновенно (плюс до ~5с известного рассинхрона эпох каналов);
    ///   осознанный повтор фразы приходит позже и выживает.
    private static let echoWindowBeforeSec: Double = 2
    private static let echoWindowAfterSec: Double = 6
    private static let echoMinWords = 4
    private static let echoSimilarityThreshold: Double = 0.8
    private static let echoMaxLengthRatio: Double = 1.5

    static func dedupeCrossChannelEcho(_ segments: [StreamSegment], dropped: inout [Drop]) -> [StreamSegment] {
        let themSegments = segments.filter { $0.speaker == .them }
        guard !themSegments.isEmpty else { return segments }

        var kept: [StreamSegment] = []
        for seg in segments {
            guard seg.speaker == .me else {
                kept.append(seg)
                continue
            }
            let meTokens = normalizedTokens(seg.text)
            guard meTokens.count >= echoMinWords else {
                kept.append(seg)
                continue
            }
            let isEcho = themSegments.contains { them in
                let delta = seg.startSec - them.startSec
                guard delta >= -echoWindowBeforeSec, delta <= echoWindowAfterSec else { return false }
                let themTokens = normalizedTokens(them.text)
                guard !themTokens.isEmpty,
                      Double(meTokens.count) <= Double(themTokens.count) * echoMaxLengthRatio
                else { return false }
                return tokenSimilarity(meTokens, themTokens) >= echoSimilarityThreshold
            }
            if isEcho {
                dropped.append(Drop(segment: seg, reason: "cross-channel-echo"))
            } else {
                kept.append(seg)
            }
        }
        return kept
    }

    // MARK: - Foreign-fragment filter (language-agnostic)

    /// Drop short low-plausibility fragments whose language contradicts the
    /// meeting's own dominant languages. НИКАКИХ зашитых языков: доминантные
    /// языки вычисляются из самого митинга (любая пара/тройка у любого юзера).
    ///
    /// Guards: фильтр off при <10 надёжно определённых фраз (нет статистики);
    /// язык с долей ≥20% — «свой» (билингвальный митинг не трогаем); фразы от
    /// 6 слов не удаляются никогда (собеседник реально заговорил на третьем
    /// языке); дроп только при уверенности распознавателя ≥0.7 (кириллические
    /// языки различаются моделью NL, не алфавитом).
    private static let foreignMinMeetingUtterances = 10
    private static let foreignDominantShare = 0.2
    private static let foreignMaxWords = 6
    private static let foreignMinConfidence = 0.7

    static func filterForeignFragments(_ segments: [StreamSegment], dropped: inout [Drop]) -> [StreamSegment] {
        let detections: [(index: Int, lang: String, confidence: Double)] = segments.enumerated().compactMap { i, seg in
            guard let d = detectLanguage(seg.text) else { return nil }
            return (i, d.lang, d.confidence)
        }
        let confident = detections.filter { $0.confidence >= 0.5 }
        guard confident.count >= foreignMinMeetingUtterances else { return segments }

        var shares: [String: Int] = [:]
        for d in confident { shares[d.lang, default: 0] += 1 }
        let dominant = Set(shares.filter { Double($0.value) / Double(confident.count) >= foreignDominantShare }.keys)
        guard !dominant.isEmpty else { return segments }

        let byIndex = Dictionary(uniqueKeysWithValues: detections.map { ($0.index, $0) })
        var kept: [StreamSegment] = []
        for (i, seg) in segments.enumerated() {
            if let d = byIndex[i],
               d.confidence >= foreignMinConfidence,
               !dominant.contains(d.lang),
               normalizedTokens(seg.text).count < foreignMaxWords {
                dropped.append(Drop(segment: seg, reason: "foreign-language-fragment (\(d.lang))"))
            } else {
                kept.append(seg)
            }
        }
        return kept
    }

    /// Dominant language of a text via the OS recognizer, or nil when it has
    /// no hypothesis. Language-agnostic by construction.
    static func detectLanguage(_ text: String) -> (lang: String, confidence: Double)? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let (lang, prob) = recognizer.languageHypotheses(withMaximum: 1).first else { return nil }
        return (lang.rawValue, prob)
    }

    // MARK: - Shared helpers

    private static func normalizedTokens(_ text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty }
    }

    /// Dice coefficient over token multisets: 2·|common| / (|a| + |b|).
    static func tokenSimilarity(_ a: [String], _ b: [String]) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var counts: [String: Int] = [:]
        for t in a { counts[t, default: 0] += 1 }
        var common = 0
        for t in b where (counts[t] ?? 0) > 0 {
            counts[t]! -= 1
            common += 1
        }
        return Double(2 * common) / Double(a.count + b.count)
    }
}
