import Foundation
import SwiftData

/// Index record for a file discovered during folder scan.
/// Mirrors `IndexedFileRecord` (`desktop/Desktop/Sources/FileIndexing/IndexedFileRecord.swift`).
/// spec://BACKLOG#Phase3.E1
@Model
final class IndexedFile {
    var id: UUID
    /// Absolute path on disk.
    var path: String
    var filename: String
    var fileExtension: String?
    /// FileTypeCategory raw value — document / code / image / video / audio / spreadsheet / presentation / archive / data / other.
    var fileType: String
    var sizeBytes: Int64
    /// Top-level scanned folder (e.g. user's Obsidian vault path).
    var folder: String
    /// Depth relative to scanned folder (0 = root level).
    var depth: Int
    var fileCreatedAt: Date?
    var fileModifiedAt: Date?
    var indexedAt: Date
    /// Set when FileMemoryExtractor has processed this file's content. Null = pending.
    var contentExtractedAt: Date?
    /// Raw file text (for .md/.txt/etc.), capped at 20 KB. Populated by `FileIndexerService.backfillContent`.
    /// Enables substring search + chat RAG over note contents.
    /// spec://iterations/ITER-004-file-rag#scope.1
    var contentText: String?

    init(
        path: String,
        filename: String,
        fileExtension: String?,
        fileType: String,
        sizeBytes: Int64,
        folder: String,
        depth: Int,
        fileCreatedAt: Date? = nil,
        fileModifiedAt: Date? = nil
    ) {
        self.id = UUID()
        self.path = path
        self.filename = filename
        self.fileExtension = fileExtension
        self.fileType = fileType
        self.sizeBytes = sizeBytes
        self.folder = folder
        self.depth = depth
        self.fileCreatedAt = fileCreatedAt
        self.fileModifiedAt = fileModifiedAt
        self.indexedAt = Date()
        self.contentExtractedAt = nil
        self.contentText = nil
    }

    /// Hard cap for per-file content stored in DB (20 KB). Obsidian notes typically <5 KB.
    static let maxContentBytes = 20_000

    /// Categorize by extension — mirrors FileTypeCategory enum.
    static func category(for fileExtension: String?) -> String {
        guard let ext = fileExtension?.lowercased() else { return "other" }
        switch ext {
        case "pdf", "doc", "docx", "txt", "rtf", "md", "pages", "odt":
            return "document"
        case "swift", "py", "js", "ts", "tsx", "jsx", "go", "rs", "java", "cpp", "c", "h",
             "rb", "php", "kt", "scala", "sh", "bash", "zsh", "r", "m", "mm", "lua", "pl",
             "ex", "exs", "hs", "clj", "dart", "vue", "svelte":
            return "code"
        case "png", "jpg", "jpeg", "gif", "svg", "psd", "ai", "sketch", "webp", "ico", "tiff", "bmp", "heic":
            return "image"
        case "mp4", "mov", "avi", "mkv", "webm", "flv", "wmv", "m4v":
            return "video"
        case "mp3", "wav", "aac", "m4a", "flac", "ogg", "wma", "aiff":
            return "audio"
        case "xlsx", "xls", "csv", "numbers", "tsv", "ods":
            return "spreadsheet"
        case "pptx", "ppt", "key", "odp":
            return "presentation"
        case "zip", "tar", "gz", "dmg", "rar", "7z", "bz2", "xz", "pkg", "iso":
            return "archive"
        case "json", "xml", "yaml", "yml", "sql", "db", "sqlite", "plist", "toml", "ini", "cfg", "conf":
            return "data"
        default:
            return "other"
        }
    }

    /// True for file types we can read and feed to LLM memory extraction (text-like).
    static func isExtractable(_ fileExtension: String?) -> Bool {
        guard let ext = fileExtension?.lowercased() else { return false }
        return ["md", "txt", "rtf", "markdown"].contains(ext)
    }
}
