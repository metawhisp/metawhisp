import Foundation
import SwiftData

/// Scans user-picked folders and indexes file metadata into `IndexedFile` records.
/// Does NOT read content — that's the FileMemoryExtractor's job.
/// Copied: skip-folder list, maxDepth, maxFileSize, batch insert, package-extension leaf treatment.
/// Diverged: we let user pick folders per user ask on 2026-04-19.
/// spec://BACKLOG#Phase3.E1
@MainActor
final class FileIndexerService: ObservableObject {
    @Published var isScanning = false
    @Published var lastRun: Date?
    @Published var lastScanSummary: String?

    private let settings = AppSettings.shared
    private var modelContainer: ModelContainer?
    private var timerTask: Task<Void, Never>?

    /// Noise folders we never recurse into.
    private let skipFolders: Set<String> = [
        ".Trash", "node_modules", ".git", "__pycache__", ".venv", "venv",
        ".cache", ".npm", ".yarn", "Pods", "DerivedData", ".build",
        "build", "dist", ".next", ".nuxt", "target", "vendor",
        "Library", ".local", ".cargo", ".rustup", ".obsidian",
        ".idea", ".vscode",
    ]

    /// Package-like extensions treated as opaque leaves (don't recurse into them).
    private let packageExtensions: Set<String> = [
        "app", "framework", "bundle", "plugin", "kext",
        "xcodeproj", "xcworkspace", "playground",
    ]

    private let maxDepth = 8 // Obsidian vaults can be deeper than default 3
    private let maxFileSize: Int64 = 500 * 1024 * 1024 // 500 MB
    private let batchSize = 200

    func configure(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    func startPeriodic(interval: TimeInterval = 21600) {
        timerTask?.cancel()
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard let self, !Task.isCancelled else { return }
                await self.scanAll()
            }
        }
        NSLog("[FileIndexer] ✅ Periodic scans every %.0fs", interval)
    }

    func stopPeriodic() {
        timerTask?.cancel()
        timerTask = nil
    }

    /// Scan all configured folders. Adds new files, updates metadata for existing.
    func scanAll() async {
        guard !isScanning else { return }
        guard settings.fileIndexingEnabled else {
            NSLog("[FileIndexer] Disabled — skipping")
            return
        }
        let folders = settings.indexedFolders
        guard !folders.isEmpty else {
            NSLog("[FileIndexer] No folders configured — skipping")
            return
        }
        isScanning = true
        defer {
            isScanning = false
            lastRun = Date()
        }

        var totalAdded = 0
        var totalUpdated = 0
        for folderPath in folders {
            let (added, updated) = await scanFolder(folderPath)
            totalAdded += added
            totalUpdated += updated
        }
        lastScanSummary = "Added \(totalAdded), updated \(totalUpdated) across \(folders.count) folder(s)"
        NSLog("[FileIndexer] ✅ %@", lastScanSummary ?? "")

        // Always follow metadata scan with content backfill — cheap disk-only pass, no LLM calls.
        // Ensures periodic scans (every 6h) also keep chat RAG in sync without a separate timer.
        // spec://iterations/ITER-004-file-rag#scope.2
        await backfillContent()
    }

    /// Scan one folder — returns (added, updated).
    func scanFolder(_ folderPath: String) async -> (added: Int, updated: Int) {
        guard let container = modelContainer else { return (0, 0) }
        let rootURL = URL(fileURLWithPath: (folderPath as NSString).expandingTildeInPath)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: rootURL.path, isDirectory: &isDir), isDir.boolValue else {
            NSLog("[FileIndexer] Folder does not exist: %@", rootURL.path)
            return (0, 0)
        }

        let ctx = ModelContext(container)
        // Existing index: path → IndexedFile, to detect updates/skip.
        let existingByPath = fetchExistingByPath(in: ctx, underFolder: folderPath)

        var added = 0
        var updated = 0
        var batchCount = 0

        walk(rootURL, root: folderPath, depth: 0) { url, depth in
            let path = url.path
            let filename = url.lastPathComponent
            let ext = url.pathExtension.isEmpty ? nil : url.pathExtension
            let attrs = (try? FileManager.default.attributesOfItem(atPath: path)) ?? [:]
            let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            if size > self.maxFileSize { return }
            let created = attrs[.creationDate] as? Date
            let modified = attrs[.modificationDate] as? Date

            if let existing = existingByPath[path] {
                // Update metadata if modified.
                if existing.fileModifiedAt != modified || existing.sizeBytes != size {
                    existing.sizeBytes = size
                    existing.fileModifiedAt = modified
                    existing.indexedAt = Date()
                    // Reset contentExtractedAt so extractor re-runs on changed content.
                    existing.contentExtractedAt = nil
                    updated += 1
                    batchCount += 1
                }
                return
            }

            let record = IndexedFile(
                path: path,
                filename: filename,
                fileExtension: ext,
                fileType: IndexedFile.category(for: ext),
                sizeBytes: size,
                folder: folderPath,
                depth: depth,
                fileCreatedAt: created,
                fileModifiedAt: modified
            )
            ctx.insert(record)
            added += 1
            batchCount += 1

            if batchCount >= self.batchSize {
                try? ctx.save()
                batchCount = 0
            }
        }
        try? ctx.save()
        NSLog("[FileIndexer] %@ → +%d new, %d updated", folderPath, added, updated)
        return (added, updated)
    }

    /// Recursive walk honoring skipFolders + maxDepth + packageExtensions.
    private func walk(_ url: URL, root: String, depth: Int, onFile: (URL, Int) -> Void) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else {
            return
        }
        for entry in entries {
            // Symlink? Skip to avoid loops.
            let vals = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if vals?.isSymbolicLink == true { continue }
            let name = entry.lastPathComponent
            let ext = entry.pathExtension.lowercased()

            if vals?.isDirectory == true {
                if skipFolders.contains(name) { continue }
                // Treat packages as leaves — don't recurse, but don't index either.
                if packageExtensions.contains(ext) { continue }
                if depth + 1 > maxDepth { continue }
                walk(entry, root: root, depth: depth + 1, onFile: onFile)
            } else {
                onFile(entry, depth)
            }
        }
    }

    /// Pre-fetch existing records under one folder keyed by full path.
    private func fetchExistingByPath(in ctx: ModelContext, underFolder folderPath: String) -> [String: IndexedFile] {
        var desc = FetchDescriptor<IndexedFile>(
            predicate: #Predicate<IndexedFile> { $0.folder == folderPath }
        )
        desc.fetchLimit = 100_000
        let items = (try? ctx.fetch(desc)) ?? []
        return Dictionary(uniqueKeysWithValues: items.map { ($0.path, $0) })
    }

    // MARK: - Content backfill (ITER-004)

    /// Read file content from disk for all extractable IndexedFile rows where `contentText == nil`
    /// and save truncated text (cap `IndexedFile.maxContentBytes` = 20 KB per file). Zero LLM calls.
    ///
    /// Runs BEFORE `FileMemoryExtractor.runPass()` — so chat RAG can query content even for files
    /// whose LLM memory extraction already completed (existing 287 files before ITER-004).
    /// Also re-reads when `contentText` is empty after an update reset.
    /// spec://iterations/ITER-004-file-rag#scope.2
    func backfillContent() async {
        guard let container = modelContainer else { return }
        guard settings.fileIndexingEnabled else { return }

        let ctx = ModelContext(container)
        // Fetch extractable files missing content. Overfetch and filter by extension client-side —
        // SwiftData predicates don't easily express the isExtractable() categorization.
        var desc = FetchDescriptor<IndexedFile>(
            predicate: #Predicate<IndexedFile> { $0.contentText == nil },
            sortBy: [SortDescriptor(\.indexedAt, order: .reverse)]
        )
        desc.fetchLimit = 1000  // sweep up to 1000/pass; periodic scan handles the tail.
        let candidates = ((try? ctx.fetch(desc)) ?? [])
            .filter { IndexedFile.isExtractable($0.fileExtension) }

        guard !candidates.isEmpty else {
            NSLog("[FileIndexer] Content backfill: no pending files")
            return
        }

        let maxBytes = IndexedFile.maxContentBytes
        var saved = 0
        var skipped = 0
        var batchCount = 0
        for file in candidates {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: file.path)) else {
                skipped += 1
                continue
            }
            if data.count > 2 * 1024 * 1024 { skipped += 1; continue } // 2 MB safety cap on raw read
            guard let text = String(data: data, encoding: .utf8) else { skipped += 1; continue }

            // Truncate stored text to keep DB footprint bounded.
            file.contentText = text.count > maxBytes ? String(text.prefix(maxBytes)) : text
            saved += 1
            batchCount += 1
            if batchCount >= batchSize {
                try? ctx.save()
                batchCount = 0
            }
        }
        try? ctx.save()
        NSLog("[FileIndexer] ✅ Content backfill: %d saved, %d skipped", saved, skipped)
    }
}
