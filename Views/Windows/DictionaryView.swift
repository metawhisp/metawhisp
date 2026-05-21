import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Dictionary view with tabs: Corrections | Brands | Snippets.
struct DictionaryView: View {
    @StateObject private var dictionary = CorrectionDictionary.shared
    @State private var selectedTab = 0
    @State private var searchText = ""

    // Add form state
    @State private var newKey = ""
    @State private var newValue = ""

    /// Transient «copied to clipboard» feedback. When a tag's main body is
    /// tapped, we copy its expansion and flip this to the tag's key for
    /// ~1.2 s so the tag renders «✓ copied» instead of the value. Auto-
    /// clears via the same Task that set it.
    @State private var copiedKey: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Rectangle().fill(MW.border).frame(height: MW.hairline)
            tabBar
            Rectangle().fill(MW.border).frame(height: MW.hairline)

            HStack(spacing: 0) {
                // Left sidebar
                VStack(spacing: 0) {
                    addSection
                    Rectangle().fill(MW.border).frame(height: MW.hairline)
                    searchSection
                    Rectangle().fill(MW.border).frame(height: MW.hairline)
                    statsSection
                    Spacer()
                }
                .frame(width: 280)

                Rectangle().fill(MW.border).frame(width: MW.hairline)

                // Right panel
                if currentItems.isEmpty && searchText.isEmpty {
                    emptyState
                } else {
                    itemsList
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(MW.bg)
    }

    // MARK: - Current Data

    private var currentItems: [(key: String, value: String)] {
        let source: [String: String]
        switch selectedTab {
        case 0: source = dictionary.corrections
        case 1: source = dictionary.brands
        default: source = dictionary.snippets
        }
        let all = source.sorted { $0.key < $1.key }
        if searchText.isEmpty { return all }
        let q = searchText.lowercased()
        return all.filter { $0.key.contains(q) || $0.value.lowercased().contains(q) }
    }

    private var tabTitle: String {
        switch selectedTab {
        case 0: return "CORRECTIONS"
        case 1: return "BRANDS"
        default: return "SNIPPETS"
        }
    }

    private var totalCount: Int {
        dictionary.corrections.count + dictionary.brands.count + dictionary.snippets.count
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack {
            Text("Dictionary").font(MW.monoTitle).foregroundStyle(MW.textPrimary)
            Spacer()
            Text("\(totalCount) TOTAL")
                .font(MW.monoSm).foregroundStyle(MW.textMuted)
            BlocksButton(label: "EXPORT", icon: "square.and.arrow.up") { exportCurrent() }
            BlocksButton(label: "IMPORT", icon: "square.and.arrow.down") { importCurrent() }
        }
        .padding(MW.sp16)
    }

    // MARK: - Tab Bar

    private var tabBar: some View {
        HStack(spacing: 0) {
            tabButton("CORRECTIONS", count: dictionary.corrections.count, index: 0)
            tabButton("BRANDS", count: dictionary.brands.count, index: 1)
            tabButton("SNIPPETS", count: dictionary.snippets.count, index: 2)
            Spacer()
        }
        .padding(.horizontal, MW.sp16)
        .padding(.vertical, MW.sp8)
    }

    /// Liquid Glass spec § 7: tab pills, active = glass-flat selectFill,
    /// inactive = ultraThin. No more black-on-white inverted look.
    private func tabButton(_ label: String, count: Int, index: Int) -> some View {
        let isActive = selectedTab == index
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                selectedTab = index
                searchText = ""
                newKey = ""
                newValue = ""
            }
        } label: {
            HStack(spacing: 6) {
                Text(label).font(.system(size: 11, weight: .semibold)).tracking(0.8)
                Text("\(count)").font(MW.monoSm)
            }
            .foregroundStyle(isActive ? MW.textPrimary : MW.textMuted)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background {
                Capsule(style: .continuous)
                    .fill(isActive ? AnyShapeStyle(MW.selectFill) : AnyShapeStyle(.ultraThinMaterial))
            }
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(isActive ? MW.selectRim : MW.border, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Add Section

    private var addSection: some View {
        VStack(alignment: .leading, spacing: MW.sp8) {
            Text(addSectionTitle).mwBadge()

            inputField(placeholder: keyPlaceholder, text: $newKey)

            HStack(spacing: MW.sp4) {
                Image(systemName: "arrow.down").font(.system(size: 8, weight: .medium)).foregroundStyle(MW.textMuted)
                Text(arrowLabel).font(MW.monoSm).foregroundStyle(MW.textMuted)
            }
            .padding(.leading, MW.sp4)

            inputField(placeholder: valuePlaceholder, text: $newValue)

            Button { addItem() } label: {
                HStack(spacing: MW.sp4) {
                    Image(systemName: "plus").font(.system(size: 9, weight: .medium))
                    Text("ADD").font(MW.label).tracking(1.2)
                }
                .foregroundStyle(canAdd ? Color.black : MW.textMuted)
                .frame(maxWidth: .infinity)
                .padding(.vertical, MW.sp8)
                .background(canAdd ? Color.white : MW.surface)
                .overlay(RoundedRectangle(cornerRadius: MW.rSmall, style: .continuous).stroke(MW.border, lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .disabled(!canAdd)

            Text(hintText)
                .font(MW.monoSm).foregroundStyle(MW.textMuted)

            // Load defaults button — available for both Brands (preset
            // capitalization) and Snippets (preset trigger templates with
            // empty values for the user to fill in).
            if selectedTab == 1 || selectedTab == 2 {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        if selectedTab == 1 { dictionary.loadDefaultBrands() }
                        else { dictionary.loadDefaultSnippets() }
                    }
                } label: {
                    HStack(spacing: MW.sp4) {
                        Image(systemName: "arrow.clockwise").font(.system(size: 9, weight: .medium))
                        Text("LOAD DEFAULTS").font(MW.label).tracking(1)
                    }
                    .foregroundStyle(MW.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, MW.sp8)
                    .mwCard(radius: MW.rSmall, elevation: .flat)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(MW.sp16)
    }

    private var addSectionTitle: String {
        switch selectedTab {
        case 0: return "ADD CORRECTION"
        case 1: return "ADD BRAND"
        default: return "ADD SNIPPET"
        }
    }

    private var keyPlaceholder: String {
        switch selectedTab {
        case 0: return "original word..."
        case 1: return "whisper writes..."
        default: return "trigger phrase..."
        }
    }

    private var valuePlaceholder: String {
        switch selectedTab {
        case 0: return "replacement..."
        case 1: return "correct spelling..."
        default: return "expands to..."
        }
    }

    private var arrowLabel: String {
        switch selectedTab {
        case 2: return "EXPANDS TO"
        default: return "REPLACES WITH"
        }
    }

    private var hintText: String {
        switch selectedTab {
        case 0: return "Auto-corrects during transcription"
        case 1: return "Fixes brand capitalization"
        default: return "e.g. \"my email\" → user@mail.com"
        }
    }

    private var canAdd: Bool {
        !newKey.trimmingCharacters(in: .whitespaces).isEmpty
        && !newValue.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: - Search

    private var searchSection: some View {
        VStack(alignment: .leading, spacing: MW.sp8) {
            Text("SEARCH").mwBadge()
            TextField("", text: $searchText, prompt:
                Text("Filter \(tabTitle.lowercased())...")
                    .font(MW.mono).foregroundStyle(MW.textMuted)
            )
            .font(MW.mono).foregroundStyle(MW.textPrimary)
            .textFieldStyle(.roundedBorder)
            // colorScheme(.dark) override removed 2026-05-11 — it forced the
            // rounded-border TextField to render with a dark backplate even
            // in Light mode, producing the "dark control on light card"
            // mismatch reported by the user. Inherits ambient scheme now.
        }
        .padding(MW.sp16)
    }

    // MARK: - Stats

    private var statsSection: some View {
        VStack(alignment: .leading, spacing: MW.sp8) {
            Text("STATS").mwBadge()
            statRow("Corrections", "\(dictionary.corrections.count)")
            statRow("Brands", "\(dictionary.brands.count)")
            statRow("Snippets", "\(dictionary.snippets.count)")
            statRow("Showing", "\(currentItems.count)")
        }
        .padding(MW.sp16)
    }

    private func statRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label.uppercased()).font(MW.monoSm).foregroundStyle(MW.textMuted)
            Spacer()
            Text(value).font(MW.monoSm).foregroundStyle(MW.textPrimary)
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: MW.sp16) {
            Spacer()
            Image(systemName: emptyIcon)
                .font(.system(size: 32, weight: .thin)).foregroundStyle(MW.textMuted)
            Text("NO \(tabTitle) YET")
                .font(MW.mono).foregroundStyle(MW.textSecondary).tracking(1.5)
            Text(emptyHint)
                .font(MW.monoSm).foregroundStyle(MW.textMuted).multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var emptyIcon: String {
        switch selectedTab {
        case 0: return "character.book.closed"
        case 1: return "building.2"
        default: return "text.insert"
        }
    }

    private var emptyHint: String {
        switch selectedTab {
        case 0: return "Add corrections manually or they'll be\nlearned automatically from your edits."
        case 1: return "Add brand names so Whisper spells\nthem correctly. Try \"Load Defaults\"."
        default: return "Add snippets like \"my email\" or\n\"meeting link\" for quick text expansion."
        }
    }

    // MARK: - Items List

    private var itemsList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MW.sp16) {
                HStack(spacing: MW.sp8) {
                    Text(tabTitle).mwBadge()
                    Text("(\(currentItems.count))").font(MW.monoSm).foregroundStyle(MW.textMuted)
                    Spacer()
                    if !currentItems.isEmpty {
                        BlocksButton(label: "CLEAR ALL", icon: "trash") { clearCurrent() }
                    }
                }

                FlowLayout(spacing: 6) {
                    ForEach(currentItems, id: \.key) { item in
                        itemTag(key: item.key, value: item.value)
                    }
                }

                if currentItems.isEmpty && !searchText.isEmpty {
                    Text("No matches for \"\(searchText)\"")
                        .font(MW.mono).foregroundStyle(MW.textMuted).padding(.top, MW.sp8)
                }
            }
            .padding(MW.sp16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Two interactive zones in each tag:
    ///   1. Main body (key → value) — tapping copies `value` to the
    ///      clipboard with a 1.2 s «✓ copied» flash. For EMPTY snippet
    ///      presets (Snippets tab, value == "") the same tap instead
    ///      pre-fills the Add form above with the trigger so the user
    ///      can type their email / LinkedIn / etc. in one move.
    ///   2. X button — removes the entry. Separate `Button` so it doesn't
    ///      trigger the copy/edit handler.
    private func itemTag(key: String, value: String) -> some View {
        let isEmpty = value.isEmpty
        let isSnippet = selectedTab == 2
        let isPresetPlaceholder = isEmpty && isSnippet
        let isCopied = copiedKey == key

        return HStack(spacing: MW.sp4) {
            Button {
                handleTagTap(key: key, value: value, isPresetPlaceholder: isPresetPlaceholder)
            } label: {
                HStack(spacing: MW.sp4) {
                    if selectedTab == 0 {
                        Text(key).font(MW.mono).foregroundStyle(MW.textMuted)
                            .strikethrough(color: MW.textMuted.opacity(0.5))
                    } else {
                        Text(key).font(MW.mono)
                            .foregroundStyle(isPresetPlaceholder ? MW.textPrimary : MW.textMuted)
                    }

                    Image(systemName: "arrow.right")
                        .font(.system(size: 7, weight: .medium)).foregroundStyle(MW.textSecondary)

                    if isCopied {
                        HStack(spacing: 3) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 8, weight: .bold))
                            Text("copied").font(MW.monoSm)
                        }
                        .foregroundStyle(MW.idle)
                    } else if isPresetPlaceholder {
                        Text("tap to fill in").font(MW.mono).italic()
                            .foregroundStyle(MW.textMuted)
                    } else {
                        Text(value).font(MW.mono).foregroundStyle(MW.textPrimary)
                            .lineLimit(1)
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 8, weight: .medium))
                            .foregroundStyle(MW.textMuted.opacity(0.6))
                            .padding(.leading, 2)
                    }
                }
            }
            .buttonStyle(.plain)
            .help(isPresetPlaceholder
                  ? "Tap to fill in this snippet — pre-fills the Add form so you can type your value."
                  : "Tap to copy expansion to clipboard")

            Button {
                withAnimation(.easeInOut(duration: 0.15)) { removeItem(key) }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 7, weight: .medium)).foregroundStyle(MW.textMuted)
            }
            .buttonStyle(.plain)
            .help("Remove")
        }
        .padding(.horizontal, MW.sp8).padding(.vertical, MW.sp4)
        .mwCard(radius: MW.rSmall, elevation: .flat)
        .opacity(isPresetPlaceholder ? 0.7 : 1.0)
    }

    /// Tap handler for the main tag body (the everything-except-X area).
    /// Two paths:
    ///   - Preset placeholder (empty snippet) → pre-fill the Add form so
    ///     the user can type the actual value. Keeps the trigger phrase
    ///     intact, focuses the value field.
    ///   - Filled value → copy to clipboard + briefly flip the tag's UI
    ///     to «✓ copied» state via `copiedKey`.
    private func handleTagTap(key: String, value: String, isPresetPlaceholder: Bool) {
        if isPresetPlaceholder {
            // Pre-fill Add form. User types the value, hits ADD → overwrites
            // the empty preset with their real value.
            newKey = key
            newValue = ""
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
        copiedKey = key
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1200))
            if copiedKey == key { copiedKey = nil }
        }
    }

    // MARK: - Actions

    private func addItem() {
        let k = newKey.trimmingCharacters(in: .whitespaces)
        let v = newValue.trimmingCharacters(in: .whitespaces)
        guard !k.isEmpty, !v.isEmpty else { return }
        withAnimation(.easeInOut(duration: 0.15)) {
            switch selectedTab {
            case 0: dictionary.add(original: k, replacement: v)
            case 1: dictionary.addBrand(original: k, replacement: v)
            default: dictionary.addSnippet(trigger: k, expansion: v)
            }
            newKey = ""
            newValue = ""
        }
    }

    private func removeItem(_ key: String) {
        switch selectedTab {
        case 0: dictionary.remove(key)
        case 1: dictionary.removeBrand(key)
        default: dictionary.removeSnippet(key)
        }
    }

    private func clearCurrent() {
        withAnimation(.easeInOut(duration: 0.15)) {
            switch selectedTab {
            case 0: dictionary.removeAll()
            case 1: dictionary.removeAllBrands()
            default: dictionary.removeAllSnippets()
            }
        }
    }

    private func inputField(placeholder: String, text: Binding<String>) -> some View {
        TextField("", text: text, prompt:
            Text(placeholder).font(MW.mono).foregroundStyle(MW.textMuted)
        )
        .font(MW.mono).foregroundStyle(MW.textPrimary)
        .textFieldStyle(.roundedBorder)
        .colorScheme(.dark)
        .padding(.horizontal, MW.sp4).padding(.vertical, MW.sp4)
    }

    private func exportCurrent() {
        let source: [String: String]
        switch selectedTab {
        case 0: source = dictionary.corrections
        case 1: source = dictionary.brands
        default: source = dictionary.snippets
        }
        guard !source.isEmpty else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "metawhisp-\(tabTitle.lowercased()).json"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            if let data = try? JSONEncoder().encode(source) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    private func importCurrent() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            if let data = try? Data(contentsOf: url),
               let imported = try? JSONDecoder().decode([String: String].self, from: data) {
                for (key, value) in imported {
                    switch selectedTab {
                    case 0: dictionary.add(original: key, replacement: value)
                    case 1: dictionary.addBrand(original: key, replacement: value)
                    default: dictionary.addSnippet(trigger: key, expansion: value)
                    }
                }
            }
        }
    }
}
