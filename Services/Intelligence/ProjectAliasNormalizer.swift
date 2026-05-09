import Foundation

/// Returns a canonical-form string used ONLY for comparing project aliases.
/// Two aliases whose canonical forms are equal are treated as the same project.
///
/// Pipeline:
/// 1. Transliterate Cyrillic / other scripts → Latin (`Голосок` → `Golosok`)
/// 2. Lowercase
/// 3. Drop non-alphanumeric (emoji, punctuation, symbols) — but KEEP spaces
///    so word boundaries survive for the Levenshtein step downstream.
/// 4. Collapse internal whitespace runs → single space
/// 5. Trim leading/trailing whitespace
///
/// The original string is preserved in `ProjectAlias.aliasesJSON` for display;
/// canonicalization is purely for the dedup decision.
///
/// Bug history (2026-05-08): `ProjectAggregator.resolveCanonical` did
/// `localizedCaseInsensitiveCompare` only — missed transliteration, emoji,
/// punctuation. ~52 alias rows ended up with ~46 duplicates of ~10 real
/// projects. See `specs/health-reports/` and the WAL ITER-032 entry.
enum ProjectAliasNormalizer {
    static func canonicalize(_ raw: String) -> String {
        // 1. Transliterate to Latin (NFD-friendly normalization). Apple's
        //    `.toLatin` handles Cyrillic, Greek, etc. → ASCII-ish Latin.
        let transliterated = raw.applyingTransform(.toLatin, reverse: false) ?? raw

        // 2. Lowercase using locale-independent fold.
        let lower = transliterated.lowercased()

        // 3. Keep alphanumeric + space; drop everything else (emoji,
        //    punctuation, symbols, combining marks).
        let kept = String(lower.unicodeScalars.compactMap { scalar -> Character? in
            if CharacterSet.alphanumerics.contains(scalar) { return Character(scalar) }
            if scalar == " " { return Character(scalar) }
            return nil
        })

        // 4. Collapse multiple whitespace into one + 5. trim.
        let collapsed = kept
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return collapsed
    }
}
