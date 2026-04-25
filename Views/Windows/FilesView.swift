import SwiftData
import SwiftUI

/// Files — lists indexed files from user-picked folders.
/// Header has "Scan Now" button that runs FileIndexerService + FileMemoryExtractor inline.
///
/// spec://BACKLOG#Phase3.E1
struct FilesView: View {
    @Query(sort: \IndexedFile.indexedAt, order: .reverse) private var files: [IndexedFile]
    @ObservedObject private var settings = AppSettings.shared

    @State private var isWorking = false
    @State private var workingMessage: String?
    @State private var searchQuery: String = ""

    /// Files filtered by `searchQuery` (case-insensitive, matches filename OR contentText).
    /// Empty query = show all. Non-empty = flat filtered set, still grouped by folder below.
    /// spec://iterations/ITER-004-file-rag#scope.5
    private var filteredFiles: [IndexedFile] {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return files }
        return files.filter { f in
            if f.filename.lowercased().contains(q) { return true }
            if let c = f.contentText, c.lowercased().contains(q) { return true }
            return false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle().fill(MW.border).frame(height: MW.hairline)
            if !files.isEmpty && settings.fileIndexingEnabled {
                searchBar
                Rectangle().fill(MW.border).frame(height: MW.hairline)
            }
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11)).foregroundStyle(MW.textMuted)
            TextField("Search filename or note contents…", text: $searchQuery)
                .textFieldStyle(.plain)
                .font(MW.mono)
                .foregroundStyle(MW.textPrimary)
            if !searchQuery.isEmpty {
                Text("\(filteredFiles.count) / \(files.count)")
                    .font(MW.monoSm).foregroundStyle(MW.textMuted)
                Button {
                    searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11)).foregroundStyle(MW.textMuted)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("FILES")
                    .font(MW.monoLg).foregroundStyle(MW.textPrimary).tracking(2)
                Spacer()
                if settings.fileIndexingEnabled {
                    Button(action: scanNow) {
                        HStack(spacing: 4) {
                            if isWorking {
                                ProgressView().controlSize(.mini)
                            } else {
                                Image(systemName: "arrow.clockwise").font(.system(size: 10))
                            }
                            Text(isWorking ? "SCANNING…" : "SCAN NOW")
                                .font(MW.label).tracking(0.6)
                        }
                        .foregroundStyle(MW.textSecondary)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .overlay(RoundedRectangle(cornerRadius: MW.rSmall, style: .continuous).stroke(MW.border, lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                    .disabled(isWorking)
                }
                Text("\(files.count) indexed")
                    .font(MW.monoSm).foregroundStyle(MW.textMuted)
            }
            if let msg = workingMessage {
                Text(msg).font(MW.monoSm).foregroundStyle(MW.textSecondary)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    @ViewBuilder
    private var content: some View {
        if !settings.fileIndexingEnabled {
            disabledState
        } else if settings.indexedFolders.isEmpty {
            emptyConfigState
        } else if files.isEmpty {
            emptyScanState
        } else if filteredFiles.isEmpty {
            // Active query returned zero hits — honest feedback instead of a blank list.
            searchEmptyState
        } else {
            list
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(settings.indexedFolders, id: \.self) { folder in
                    let folderFiles = filteredFiles.filter { $0.folder == folder }
                    if !folderFiles.isEmpty {
                        folderSection(folder: folder, files: folderFiles)
                    }
                }
            }
            .padding(16)
        }
    }

    private var searchEmptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "doc.text.magnifyingglass").font(.system(size: 28)).foregroundStyle(MW.textMuted)
            Text("No matches for \"\(searchQuery)\"")
                .font(MW.monoLg).foregroundStyle(MW.textSecondary)
            Text("Searched \(files.count) files by filename and content.")
                .font(MW.monoSm).foregroundStyle(MW.textMuted)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func folderSection(folder: String, files: [IndexedFile]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text((folder as NSString).abbreviatingWithTildeInPath)
                .font(MW.label).tracking(1.0).foregroundStyle(MW.textMuted)
                .padding(.top, 8).padding(.bottom, 4)
            ForEach(files.prefix(200)) { file in
                row(file)
            }
            if files.count > 200 {
                Text("… and \(files.count - 200) more")
                    .font(MW.monoSm).foregroundStyle(MW.textMuted)
                    .padding(.top, 4)
            }
        }
    }

    private func row(_ file: IndexedFile) -> some View {
        HStack(spacing: 10) {
            Image(systemName: iconFor(fileType: file.fileType))
                .font(.system(size: 12))
                .foregroundStyle(MW.textMuted)
                .frame(width: 18, alignment: .center)
            Text(file.filename)
                .font(MW.mono).foregroundStyle(MW.textPrimary)
                .lineLimit(1)
            Spacer()
            // Indexed-for-chat indicator (ITER-004): contentText is populated → chat RAG can find it.
            if file.contentText != nil {
                Image(systemName: "sparkle.magnifyingglass")
                    .font(.system(size: 10))
                    .foregroundStyle(MW.textSecondary)
                    .help("Indexed for chat search")
            }
            // Memory-extracted indicator: LLM has processed this file for durable facts.
            if file.contentExtractedAt != nil {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 9))
                    .foregroundStyle(MW.textMuted)
                    .help("Memories extracted")
            }
            Text(formatBytes(file.sizeBytes))
                .font(MW.monoSm).foregroundStyle(MW.textMuted)
            if let mod = file.fileModifiedAt {
                Text(mod.formatted(date: .abbreviated, time: .omitted))
                    .font(MW.monoSm).foregroundStyle(MW.textMuted)
            }
        }
        .padding(.vertical, 4)
    }

    private func iconFor(fileType: String) -> String {
        switch fileType {
        case "document": return "doc.text"
        case "code": return "chevron.left.forwardslash.chevron.right"
        case "image": return "photo"
        case "video": return "play.rectangle"
        case "audio": return "music.note"
        case "spreadsheet": return "tablecells"
        case "presentation": return "rectangle.on.rectangle"
        case "archive": return "archivebox"
        case "data": return "cylinder"
        default: return "doc"
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let fmt = ByteCountFormatter()
        fmt.countStyle = .file
        return fmt.string(fromByteCount: bytes)
    }

    // MARK: - Empty / disabled states

    private var disabledState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "folder.badge.questionmark").font(.system(size: 32)).foregroundStyle(MW.textMuted)
            Text("File indexing is off")
                .font(MW.monoLg).foregroundStyle(MW.textSecondary)
            Text("Enable in Settings and pick a folder (e.g. your Obsidian vault). MetaWhisp scans text files and extracts personal facts into Memories.")
                .font(MW.mono).foregroundStyle(MW.textMuted)
                .multilineTextAlignment(.center).frame(maxWidth: 380)
            Button("Open Settings") {
                NotificationCenter.default.post(name: .switchMainTab, object: MainWindowView.SidebarTab.settings)
            }
            .font(MW.mono)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var emptyConfigState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "folder.badge.plus").font(.system(size: 32)).foregroundStyle(MW.textMuted)
            Text("No folders configured")
                .font(MW.monoLg).foregroundStyle(MW.textSecondary)
            Text("Pick a folder in Settings — your Obsidian vault, notes directory, or any place with text files.")
                .font(MW.mono).foregroundStyle(MW.textMuted)
                .multilineTextAlignment(.center).frame(maxWidth: 380)
            Button("Open Settings") {
                NotificationCenter.default.post(name: .switchMainTab, object: MainWindowView.SidebarTab.settings)
            }
            .font(MW.mono)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var emptyScanState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "folder").font(.system(size: 32)).foregroundStyle(MW.textMuted)
            Text("Nothing indexed yet")
                .font(MW.monoLg).foregroundStyle(MW.textSecondary)
            Text("Click SCAN NOW above to index \(settings.indexedFolders.count) folder(s) — up to 8 levels deep, skipping .git / node_modules / etc.")
                .font(MW.mono).foregroundStyle(MW.textMuted)
                .multilineTextAlignment(.center).frame(maxWidth: 380)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Actions

    private func scanNow() {
        isWorking = true
        workingMessage = "Scanning folders…"
        Task { @MainActor in
            guard let app = AppDelegate.shared else {
                workingMessage = "FileIndexer not available"
                isWorking = false
                return
            }
            // scanAll() now does metadata + content backfill (ITER-004) in one pass.
            await app.fileIndexer.scanAll()
            workingMessage = app.fileIndexer.lastScanSummary ?? "Scan done"
            workingMessage = (workingMessage ?? "") + " · Extracting memories…"
            await app.fileMemoryExtractor.runPass()
            if let extractSummary = app.fileMemoryExtractor.lastSummary {
                workingMessage = extractSummary
            }
            isWorking = false
        }
    }
}
