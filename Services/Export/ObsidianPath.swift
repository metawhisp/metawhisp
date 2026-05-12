import Foundation

/// Pure-function helpers for ObsidianExporter v2 (ITER-035). Compute folder
/// paths, filenames, slugs — without touching FileManager. Everything here is
/// testable in `ObsidianPathTests.swift` without disk IO.
///
/// Vault layout (date-first for transient entities + project-first for memories):
///
/// ```
/// <Vault>/MetaWhisp/
///   2026-05-12/
///     meetings/14h00--standup-with-sam.md
///     voices/09h15--MetaWhisp.md
///     tasks/T-0001--починить-окно.md
///   Memories/
///     MetaWhisp/2026-05-12--user-prefers-bullets.md
///     General/2026-05-12--bought-milk.md
///   Insights/
///     2026-05-12/09h22--credentials-visible.md
/// ```
enum ObsidianPath {

    // MARK: - Top-level constants

    /// Root subfolder inside the user-picked vault root.
    /// Keeps MetaWhisp data scoped — user's other Obsidian notes are unaffected.
    static let rootSubdir = "MetaWhisp"

    /// Top-level folder for memories (project-first, not date-first).
    static let memoriesSubdir = "Memories"

    /// Top-level folder for surfaced insights (date-first, but separate from
    /// daily transient artefacts so they're easier to scan as a stream).
    static let insightsSubdir = "Insights"

    /// Default "project bucket" name when a memory has no project tag.
    static let defaultProjectBucket = "General"

    /// Default "project bucket" name when a voice/conversation has no
    /// `Conversation.primaryProject` assigned. Differs from memories' default
    /// intentionally — for transient artefacts we want the user to notice
    /// the missing tag and reassign.
    static let defaultUntaggedConversation = "Untagged"

    // MARK: - Date formatters

    /// `2026-05-12`. ISO date used as folder name (date-first hierarchy)
    /// AND as date prefix in memory filenames.
    static func dateFolder(for date: Date, calendar: Calendar = .current) -> String {
        let f = DateFormatter()
        f.calendar = calendar
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = calendar.timeZone
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    /// `14h00` — within-day ordering prefix. Hours-minutes format chosen over
    /// `HH:mm` because `:` is reserved on some filesystems and ugly in
    /// Obsidian's URL encoding. `h` separator keeps it human-readable.
    static func timestampPrefix(for date: Date, calendar: Calendar = .current) -> String {
        let f = DateFormatter()
        f.calendar = calendar
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = calendar.timeZone
        f.dateFormat = "HH'h'mm"
        return f.string(from: date)
    }

    // MARK: - Slug

    /// Convert arbitrary text (transcript head / task description / memory
    /// content) into a filesystem-safe slug suitable for use inside a
    /// markdown filename.
    ///
    /// Rules:
    /// - Preserve Cyrillic letters (юзер активно пишет на русском)
    /// - Drop emoji and symbol clusters
    /// - Collapse whitespace and punctuation to single `-`
    /// - Lowercase ASCII; keep Cyrillic as-is (no .lowercased() — it would
    ///   work but Obsidian users typically capitalize titles, мы оставляем
    ///   original case for the first letter only via `keepingCase`)
    /// - Strip leading/trailing dashes
    /// - Cap at `maxLength` (default 60) to avoid path length issues
    static func slugForFilename(
        _ text: String,
        maxLength: Int = 60,
        keepingCase: Bool = false
    ) -> String {
        // 1. Strip emoji / symbol / control chars, but KEEP punctuation
        // so Step 2 can split on it (dots, apostrophes, slashes become dashes
        // instead of disappearing — `metawhisp.com` → `metawhisp-com`, not `metawhispcom`).
        let filtered = text.unicodeScalars.filter { scalar in
            let category = scalar.properties.generalCategory
            switch category {
            case .lowercaseLetter, .uppercaseLetter, .titlecaseLetter,
                 .modifierLetter, .otherLetter,
                 .decimalNumber:
                return true
            case .spaceSeparator, .lineSeparator, .paragraphSeparator:
                return true
            case .dashPunctuation, .connectorPunctuation,
                 .openPunctuation, .closePunctuation,
                 .initialPunctuation, .finalPunctuation, .otherPunctuation:
                return true  // kept — Step 2 splits on these
            default:
                // Strips: math/currency/modifier symbols (incl. emoji), control,
                // format, surrogate, private-use, unassigned.
                return false
            }
        }
        let cleaned = String(String.UnicodeScalarView(filtered))

        // 2. Split on any whitespace OR punctuation cluster → join with single dash.
        let separators = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
        let parts = cleaned
            .components(separatedBy: separators)
            .filter { !$0.isEmpty }
        var joined = parts.joined(separator: "-")

        // 3. Collapse repeated dashes (defensive — shouldn't happen but cheap).
        while joined.contains("--") {
            joined = joined.replacingOccurrences(of: "--", with: "-")
        }

        // 4. Trim leading/trailing dashes.
        joined = joined.trimmingCharacters(in: CharacterSet(charactersIn: "-"))

        // 5. Lowercase ASCII (Cyrillic stays as-is because Swift's lowercased()
        // would actually lowercase Cyrillic too — caller can opt out).
        if !keepingCase {
            joined = joined.lowercased()
        }

        // 6. Cap length — but don't cut mid-Cyrillic-codepoint.
        if joined.count > maxLength {
            let endIndex = joined.index(joined.startIndex, offsetBy: maxLength)
            joined = String(joined[..<endIndex])
            // Trim trailing dash if cap landed mid-word.
            joined = joined.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        }

        // 7. Fallback if everything got filtered out.
        if joined.isEmpty {
            return "untitled"
        }
        return joined
    }

    // MARK: - Project bucket name

    /// Sanitize a project name to be safe as a folder name. Reuses slug
    /// logic but caps shorter (folder names don't need 60 chars).
    static func projectFolderName(_ rawProject: String?) -> String {
        guard let p = rawProject?.trimmingCharacters(in: .whitespacesAndNewlines),
              !p.isEmpty else {
            return defaultProjectBucket
        }
        let slug = slugForFilename(p, maxLength: 40, keepingCase: true)
        return slug.isEmpty ? defaultProjectBucket : slug
    }

    /// Same for conversation-side (voices/meetings) — different default bucket.
    static func conversationProjectFolderName(_ rawProject: String?) -> String {
        guard let p = rawProject?.trimmingCharacters(in: .whitespacesAndNewlines),
              !p.isEmpty else {
            return defaultUntaggedConversation
        }
        let slug = slugForFilename(p, maxLength: 40, keepingCase: true)
        return slug.isEmpty ? defaultUntaggedConversation : slug
    }

    // MARK: - Full path builders (relative to vault root)

    /// `MetaWhisp/2026-05-12/meetings/14h00--standup-with-sam.md`
    static func meetingPath(
        date: Date,
        title: String,
        calendar: Calendar = .current
    ) -> String {
        let day = dateFolder(for: date, calendar: calendar)
        let time = timestampPrefix(for: date, calendar: calendar)
        let slug = slugForFilename(title)
        return "\(rootSubdir)/\(day)/meetings/\(time)--\(slug).md"
    }

    /// `MetaWhisp/2026-05-12/voices/09h15--MetaWhisp.md`
    static func voicePath(
        date: Date,
        project: String?,
        calendar: Calendar = .current
    ) -> String {
        let day = dateFolder(for: date, calendar: calendar)
        let time = timestampPrefix(for: date, calendar: calendar)
        let proj = conversationProjectFolderName(project)
        return "\(rootSubdir)/\(day)/voices/\(time)--\(proj).md"
    }

    /// `MetaWhisp/2026-05-12/tasks/T-0001--починить-окно.md`
    ///
    /// `taskID` is a stable numeric or string identifier so the file path
    /// survives task description edits. Prefer the Postgres-style `T-NNNN`
    /// from caller (zero-padded so lex sort matches numeric).
    static func taskPath(
        date: Date,
        taskID: String,
        description: String,
        calendar: Calendar = .current
    ) -> String {
        let day = dateFolder(for: date, calendar: calendar)
        let slug = slugForFilename(description)
        return "\(rootSubdir)/\(day)/tasks/\(taskID)--\(slug).md"
    }

    /// `MetaWhisp/Memories/<project>/2026-05-12--user-prefers-bullets.md`
    static func memoryPath(
        date: Date,
        project: String?,
        content: String,
        calendar: Calendar = .current
    ) -> String {
        let day = dateFolder(for: date, calendar: calendar)
        let slug = slugForFilename(content)
        let proj = projectFolderName(project)
        return "\(rootSubdir)/\(memoriesSubdir)/\(proj)/\(day)--\(slug).md"
    }

    /// `MetaWhisp/Insights/2026-05-12/09h22--credentials-visible.md`
    static func insightPath(
        date: Date,
        headline: String?,
        body: String,
        calendar: Calendar = .current
    ) -> String {
        let day = dateFolder(for: date, calendar: calendar)
        let time = timestampPrefix(for: date, calendar: calendar)
        let text = (headline?.isEmpty == false) ? headline! : body
        let slug = slugForFilename(text)
        return "\(rootSubdir)/\(insightsSubdir)/\(day)/\(time)--\(slug).md"
    }
}
