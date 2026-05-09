import Foundation

/// Wagner-Fischer minimum edit distance.
///
/// Used by `ProjectClusterDecision` to merge typo near-duplicates. Standard
/// algorithm; O(m·n) time, O(n) space (single-row DP). For our use case
/// (project names ≤ 60 chars), the constant factors are irrelevant.
enum Levenshtein {
    /// Returns the minimum number of single-character edits (insert, delete,
    /// substitute) required to turn `a` into `b`. Symmetric in (a, b).
    static func distance(_ a: String, _ b: String) -> Int {
        let aChars = Array(a)
        let bChars = Array(b)
        let m = aChars.count
        let n = bChars.count
        if m == 0 { return n }
        if n == 0 { return m }

        // Single-row DP. `prev[j]` = distance(a[..<i-1], b[..<j]).
        var prev = Array(0...n)
        var curr = Array(repeating: 0, count: n + 1)

        for i in 1...m {
            curr[0] = i
            for j in 1...n {
                let cost = aChars[i - 1] == bChars[j - 1] ? 0 : 1
                curr[j] = min(
                    curr[j - 1] + 1,        // insertion
                    prev[j] + 1,            // deletion
                    prev[j - 1] + cost      // substitution / match
                )
            }
            swap(&prev, &curr)
        }
        return prev[n]
    }
}
