import SwiftUI
import UniformTypeIdentifiers

/// The two faces of the library. Presets are whole looks you apply in one tap;
/// effects are the building blocks you stack and tune.
enum LibraryTab: String, CaseIterable, Identifiable {
    case presets = "Presets"
    case effects = "Effects"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .presets: "square.grid.2x2.fill"
        case .effects: "slider.horizontal.3"
        }
    }
}

/// The unified left panel. One switch moves between ready-made **Presets** (apply
/// a complete look) and individual **Effects** (building blocks). This replaces
/// the old split where effects lived here while presets were hidden behind a
/// toolbar menu and a separate sheet. A single contextual "+" handles saving,
/// importing, and authoring.
struct LibraryView: View {
    let engine: SpectraEngine
    let effectActions: EffectLibraryActions
    var onAddEffect: (EffectDescriptor) -> Void
    var onMultiAddEffects: ([EffectDescriptor]) -> Void
    var onNewEffect: () -> Void
    var onImport: () -> Void
    var onSavePreset: () -> Void
    var onExportPreset: (Preset) -> Void

    // Remembers where the user last was. Presets is the cold-start default (an
    // instant look in one tap); returning users land back on their last tab.
    // @AppStorage binds a RawRepresentable<String> enum directly (macOS 11+), storing the same
    // raw string under the same key as the old hand-rolled round-trip.
    @AppStorage("spectra.libraryTab") private var tab = LibraryTab.presets

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.Spacing.sm) {
                Picker("", selection: $tab.animation(.easeInOut(duration: 0.15))) {
                    ForEach(LibraryTab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Menu {
                    addMenuItems
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help(tab == .presets ? "Save or import a preset" : "Create or import an effect")
            }
            .padding(Theme.Spacing.md)

            Divider()

            switch tab {
            case .presets:
                PresetsPanel(engine: engine, onExport: onExportPreset)
            case .effects:
                EffectLibraryView(
                    engine: engine, actions: effectActions,
                    multiSelect: onMultiAddEffects, onAdd: onAddEffect)
            }
        }
        .background(.background)
    }

    @ViewBuilder
    private var addMenuItems: some View {
        switch tab {
        case .presets:
            Button("Save Current as Preset…", systemImage: "square.and.arrow.down") { onSavePreset() }
                .disabled(engine.activeStack?.effects.isEmpty ?? true)
            Button("Import…", systemImage: "tray.and.arrow.down") { onImport() }
        case .effects:
            Button("New Effect…", systemImage: "wand.and.stars") { onNewEffect() }
            Button("Import…", systemImage: "tray.and.arrow.down") { onImport() }
            Divider()
            Button("Open Library Folder", systemImage: "folder") { engine.openLibraryFolder() }
        }
    }
}

// MARK: - Presets panel

/// A scannable, searchable preset browser sized for the side panel. Tap a preset
/// to apply it; the active one is checked. Grouped by category.
private struct PresetsPanel: View {
    let engine: SpectraEngine
    var onExport: (Preset) -> Void
    @State private var query = ""
    @State private var category: String?
    @State private var selectedTag: String?
    @State private var renamingPreset: Preset?
    @State private var renameText = ""
    // Custom-category management (add / rename), driven from the filter-chip row.
    @State private var addingCategory = false
    @State private var renamingCategory: String?
    @State private var categoryNameText = ""

    /// Every custom tag in the library, surfaced as filter chips. A preset saved
    /// with a new tag makes that tag appear here automatically.
    private var allTags: [String] {
        Array(Set(engine.presets.all.flatMap(\.tags)))
            .filter { !$0.isEmpty }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private var results: [Preset] {
        var items = engine.presets.search(query)
        if let category { items = items.filter { $0.category == category } }
        if let selectedTag { items = items.filter { $0.tags.contains(selectedTag) } }
        return items
    }

    private var grouped: [(category: String, presets: [Preset])] {
        engine.presets.categories.compactMap { cat in
            let items = results.filter { $0.category == cat }
            return items.isEmpty ? nil : (cat, items)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            if results.isEmpty {
                ContentUnavailableView.search(text: query.isEmpty ? "presets" : query)
                    .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(grouped, id: \.category) { group in
                        Section(group.category) {
                            ForEach(group.presets) { preset in
                                PresetRow(engine: engine, preset: preset, isActive: isActive(preset),
                                          onExport: onExport, onRename: beginRename)
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
        .alert("Rename Preset", isPresented: Binding(
            get: { renamingPreset != nil }, set: { if !$0 { renamingPreset = nil } })) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                if let preset = renamingPreset { engine.presets.rename(preset, to: renameText) }
                renamingPreset = nil
            }
            Button("Cancel", role: .cancel) { renamingPreset = nil }
        }
        .alert("New Category", isPresented: $addingCategory) {
            TextField("Category name", text: $categoryNameText)
            Button("Create") {
                let name = categoryNameText.trimmingCharacters(in: .whitespacesAndNewlines)
                engine.presets.addCategory(name)
                if !name.isEmpty { category = name }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Group your saved presets under a custom category. Deleting a category later keeps its presets — they move back to “My Presets.”")
        }
        .alert("Rename Category", isPresented: Binding(
            get: { renamingCategory != nil }, set: { if !$0 { renamingCategory = nil } })) {
            TextField("Category name", text: $categoryNameText)
            Button("Rename") {
                if let old = renamingCategory {
                    let new = categoryNameText.trimmingCharacters(in: .whitespacesAndNewlines)
                    engine.presets.renameCategory(old, to: new)
                    if category == old { category = new.isEmpty ? nil : new }
                }
                renamingCategory = nil
            }
            Button("Cancel", role: .cancel) { renamingCategory = nil }
        }
    }

    private func beginRename(_ preset: Preset) {
        renameText = preset.name
        renamingPreset = preset
    }

    private func isActive(_ preset: Preset) -> Bool {
        engine.activePresetName == preset.name
    }

    private var searchBar: some View {
        VStack(spacing: Theme.Spacing.sm) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search \(engine.presets.all.count) presets…", text: $query)
                    .textFieldStyle(.plain)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.tertiary)
                }
            }
            .padding(Theme.Spacing.sm)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: Theme.Radius.sm))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Spacing.xs) {
                    CategoryChip(title: "All", systemImage: "square.grid.2x2",
                                 isSelected: category == nil && selectedTag == nil) {
                        category = nil
                        selectedTag = nil
                    }
                    ForEach(engine.presets.categories, id: \.self) { cat in
                        CategoryChip(title: cat, systemImage: PresetCategory.icon(for: cat),
                                     isSelected: category == cat) {
                            category = category == cat ? nil : cat
                        }
                        .contextMenu {
                            if !PresetCategory.isBuiltIn(cat) {
                                Button("Rename…", systemImage: "pencil") {
                                    categoryNameText = cat
                                    renamingCategory = cat
                                }
                                Button("Delete", systemImage: "trash", role: .destructive) {
                                    if category == cat { category = nil }
                                    engine.presets.deleteCategory(cat)
                                }
                            }
                        }
                    }
                    CategoryChip(title: "New Category", systemImage: "folder.badge.plus",
                                 isSelected: false) {
                        categoryNameText = ""
                        addingCategory = true
                    }
                    ForEach(allTags, id: \.self) { tag in
                        CategoryChip(title: tag, systemImage: "tag", isSelected: selectedTag == tag) {
                            selectedTag = selectedTag == tag ? nil : tag
                        }
                    }
                }
            }
        }
        .padding(Theme.Spacing.md)
    }
}

private struct PresetRow: View {
    let engine: SpectraEngine
    let preset: Preset
    let isActive: Bool
    var onExport: (Preset) -> Void
    var onRename: (Preset) -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: preset.displayIcon)
                .foregroundStyle(isActive ? Theme.accent : .secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 1) {
                Text(preset.name).font(.callout.weight(.medium)).lineLimit(1)
                if !preset.summary.isEmpty {
                    Text(preset.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }

            Spacer()

            if !engine.canApply(preset) {
                Image(systemName: "lock.fill").foregroundStyle(.secondary)
                    .help("Unlock the full version to use this preset")
            } else if isActive {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent)
            }

            Menu {
                actions
            } label: {
                Image(systemName: "ellipsis.circle").foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Rename, delete, or export this preset")
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture { engine.apply(preset) }
        .listRowBackground(isActive ? Theme.accent.opacity(0.12) : Color.clear)
        .contextMenu { actions }
    }

    @ViewBuilder
    private var actions: some View {
        Button("Apply", systemImage: "checkmark.circle") { engine.apply(preset) }
        Button("Export…", systemImage: "square.and.arrow.up") { onExport(preset) }
        if !preset.isBuiltIn {
            Divider()
            Button("Rename…", systemImage: "pencil") { onRename(preset) }
            Button("Delete", systemImage: "trash", role: .destructive) {
                engine.presets.delete(preset)
            }
        }
    }
}

// MARK: - Preset document

/// Minimal `FileDocument` for exporting a preset as JSON so looks can be shared.
struct PresetFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    let preset: Preset

    init(preset: Preset) { self.preset = preset }

    init(configuration: ReadConfiguration) throws {
        let data = configuration.file.regularFileContents ?? Data()
        self.preset = try JSONStore.decode(Preset.self, from: data)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let data = try JSONStore.encode(SpectraDocument.preset(preset))
        return FileWrapper(regularFileWithContents: data)
    }
}
