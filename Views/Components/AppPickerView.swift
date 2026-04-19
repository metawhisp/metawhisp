import AppKit
import SwiftUI

/// Displays a list of installed/running apps for selection.
/// Used in Settings → Screen Context to build blacklist/whitelist.
///
/// Implements spec://intelligence/FEAT-0002#app-picker
struct AppPickerView: View {
    /// Already-selected bundle IDs (hide from picker)
    let excludedBundleIDs: Set<String>
    let onSelect: (AppInfo) -> Void
    let onClose: () -> Void

    @State private var searchText = ""
    @State private var apps: [AppInfo] = []

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("SELECT APP").font(MW.monoLg).tracking(1.5).foregroundStyle(MW.textPrimary)
                Spacer()
                Button { onClose() } label: {
                    Image(systemName: "xmark").font(.system(size: 11)).foregroundStyle(MW.textMuted)
                }
                .buttonStyle(.plain)
            }
            .padding(16)

            Rectangle().fill(MW.border).frame(height: MW.hairline)

            // Search
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 10)).foregroundStyle(MW.textMuted)
                TextField("", text: $searchText,
                          prompt: Text("Search apps...").foregroundStyle(MW.textMuted))
                    .font(MW.mono)
                    .textFieldStyle(.plain)
                    .foregroundStyle(MW.textPrimary)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(MW.surface)

            Rectangle().fill(MW.border).frame(height: MW.hairline)

            // List
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(filteredApps) { app in
                        AppPickerRow(app: app) {
                            onSelect(app)
                        }
                        Rectangle().fill(MW.border).frame(height: MW.hairline).opacity(0.5)
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
        .frame(width: 400, height: 500)
        .background(MW.bg)
        .onAppear { loadApps() }
    }

    private var filteredApps: [AppInfo] {
        let available = apps.filter { !excludedBundleIDs.contains($0.bundleID) }
        guard !searchText.isEmpty else { return available }
        let query = searchText.lowercased()
        return available.filter {
            $0.name.lowercased().contains(query) || $0.bundleID.lowercased().contains(query)
        }
    }

    private func loadApps() {
        apps = InstalledApps.list()
    }
}

// MARK: - Row

struct AppPickerRow: View {
    let app: AppInfo
    let onTap: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                if let icon = app.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 20, height: 20)
                } else {
                    Image(systemName: "app").font(.system(size: 18)).foregroundStyle(MW.textMuted)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(app.name).font(MW.mono).foregroundStyle(MW.textPrimary)
                    Text(app.bundleID).font(MW.monoSm).foregroundStyle(MW.textMuted).lineLimit(1)
                }
                Spacer()
                Image(systemName: "plus").font(.system(size: 10, weight: .medium))
                    .foregroundStyle(isHovered ? MW.textPrimary : MW.textMuted)
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(isHovered ? MW.surface : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - AppInfo

struct AppInfo: Identifiable, Hashable {
    var id: String { bundleID }
    let bundleID: String
    let name: String
    let icon: NSImage?

    static func == (lhs: AppInfo, rhs: AppInfo) -> Bool {
        lhs.bundleID == rhs.bundleID
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(bundleID)
    }
}

// MARK: - Installed apps enumeration

/// Scans `/Applications` and `~/Applications` for installed apps.
/// Also includes currently running apps. Deduped by bundleID.
enum InstalledApps {
    static func list() -> [AppInfo] {
        var seen = Set<String>()
        var result: [AppInfo] = []

        // 1. Running apps
        for app in NSWorkspace.shared.runningApplications {
            guard let bundleID = app.bundleIdentifier,
                  let name = app.localizedName,
                  !seen.contains(bundleID) else { continue }
            // Skip backgroundOnly / agents
            if app.activationPolicy == .prohibited { continue }
            seen.insert(bundleID)
            result.append(AppInfo(bundleID: bundleID, name: name, icon: app.icon))
        }

        // 2. Scan /Applications and ~/Applications
        let appDirs = [
            URL(fileURLWithPath: "/Applications"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
        ]

        for dir in appDirs {
            guard let contents = try? FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for url in contents where url.pathExtension == "app" {
                guard let bundle = Bundle(url: url),
                      let bundleID = bundle.bundleIdentifier,
                      !seen.contains(bundleID) else { continue }

                let name = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
                    ?? bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                    ?? url.deletingPathExtension().lastPathComponent

                let icon = NSWorkspace.shared.icon(forFile: url.path)
                icon.size = NSSize(width: 20, height: 20)

                seen.insert(bundleID)
                result.append(AppInfo(bundleID: bundleID, name: name, icon: icon))
            }
        }

        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
