import SwiftUI

/// Optional per-item actions the library can offer. The left-panel library wires
/// all of these; the lightweight add-sheet leaves them nil and shows only "Add".
struct EffectLibraryActions {
    var edit: ((EffectDescriptor) -> Void)?
    var duplicate: ((EffectDescriptor) -> Void)?
    var delete: ((EffectDescriptor) -> Void)?
    var export: ((EffectDescriptor) -> Void)?
    /// Reveal an imported raw-shader file in Finder (advanced users edit it there).
    var revealInFinder: ((EffectDescriptor) -> Void)?
    var toggleFavorite: ((EffectDescriptor) -> Void)?
    var isFavorite: ((EffectDescriptor) -> Bool)?
    var isInStack: ((EffectDescriptor) -> Bool)?
    /// Whether this custom effect is a composed effect (editable in the composer)
    /// versus an imported raw shader (edited externally).
    var isComposite: ((EffectDescriptor) -> Bool)?
    /// A generated preview thumbnail for the effect, if any.
    var thumbnail: ((EffectDescriptor) -> Image?)?
    /// Toggle the effect's presence in the active stack (the library "enable" toggle).
    var toggleEnabled: ((EffectDescriptor) -> Void)?

    static let none = EffectLibraryActions()
}

/// Searchable, categorised browser of every available effect and custom shader.
/// This is Spectra's primary interface: the left panel of the workspace and, in a
/// lighter form, the add sheet invoked from the stack.
struct EffectLibraryView: View {
    let engine: SpectraEngine
    var actions: EffectLibraryActions = .none
    /// Optional predicate to restrict which effects appear (e.g. the composer
    /// shows only built-in building blocks).
    var filter: ((EffectDescriptor) -> Bool)?
    /// When provided, the library offers a multi-select mode that adds all chosen
    /// effects to the stack at once.
    var multiSelect: (([EffectDescriptor]) -> Void)?
    var onAdd: (EffectDescriptor) -> Void

    @State private var query = ""
    @State private var selectedCategory: EffectCategory?
    @State private var favoritesOnly = false
    @State private var selectedTag: String?
    @State private var selectionMode = false
    @State private var selected: Set<String> = []

    private var allTags: [String] {
        Set(engine.registry.descriptors.flatMap(\.tags)).sorted()
    }

    private var results: [EffectDescriptor] {
        var items = engine.registry.search(query)
        if let filter { items = items.filter(filter) }
        if let selectedCategory { items = items.filter { $0.category == selectedCategory } }
        if let selectedTag { items = items.filter { $0.tags.contains(selectedTag) } }
        if favoritesOnly, let isFavorite = actions.isFavorite {
            items = items.filter { isFavorite($0) }
        }
        return items
    }

    private var grouped: [EffectCategory: [EffectDescriptor]] {
        Dictionary(grouping: results, by: \.category)
    }

    private var presentCategories: [EffectCategory] {
        EffectCategory.allCases.filter { grouped[$0] != nil }
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            if selectionMode { selectionBar }
            Divider()
            if results.isEmpty {
                ContentUnavailableView.search(text: query.isEmpty ? "effects" : query)
                    .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(presentCategories) { category in
                        Section(category.displayName) {
                            ForEach(grouped[category] ?? []) { descriptor in
                                EffectRow(
                                    descriptor: descriptor, actions: actions,
                                    selectionMode: selectionMode, isSelected: selected.contains(descriptor.id)) {
                                    if selectionMode { toggleSelected(descriptor) } else { onAdd(descriptor) }
                                }
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
    }

    private var selectionBar: some View {
        HStack {
            Text("\(selected.count) selected").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Clear") { selected.removeAll() }.disabled(selected.isEmpty)
            Button {
                let chosen = engine.registry.descriptors.filter { selected.contains($0.id) }
                multiSelect?(chosen)
                selected.removeAll()
                selectionMode = false
            } label: { Label("Add \(selected.count) to Stack", systemImage: "plus") }
                .buttonStyle(.borderedProminent)
                .disabled(selected.isEmpty)
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.sm)
    }

    private func toggleSelected(_ descriptor: EffectDescriptor) {
        if selected.contains(descriptor.id) { selected.remove(descriptor.id) }
        else { selected.insert(descriptor.id) }
    }

    private var searchBar: some View {
        VStack(spacing: Theme.Spacing.sm) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search \(engine.registry.descriptors.count) effects…", text: $query)
                    .textFieldStyle(.plain)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.tertiary)
                }
                Menu {
                    Button("All Tags") { selectedTag = nil }
                    Divider()
                    ForEach(allTags, id: \.self) { tag in
                        Button { selectedTag = tag } label: {
                            Label(tag, systemImage: selectedTag == tag ? "checkmark" : "tag")
                        }
                    }
                } label: {
                    Image(systemName: selectedTag == nil ? "tag" : "tag.fill")
                        .foregroundStyle(selectedTag == nil ? .secondary : Theme.accent)
                }
                .menuStyle(.borderlessButton).fixedSize()
                .help("Filter by tag")
                if multiSelect != nil {
                    Button {
                        selectionMode.toggle(); if !selectionMode { selected.removeAll() }
                    } label: {
                        Image(systemName: selectionMode ? "checkmark.circle.fill" : "checklist")
                            .foregroundStyle(selectionMode ? Theme.accent : .secondary)
                    }
                    .buttonStyle(.plain).help("Select multiple")
                }
            }
            .padding(Theme.Spacing.sm)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: Theme.Radius.sm))

            if let selectedTag {
                HStack(spacing: Theme.Spacing.xs) {
                    Label(selectedTag, systemImage: "tag.fill").font(.caption2)
                    Button { self.selectedTag = nil } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                    Spacer()
                }
                .foregroundStyle(Theme.accent)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Spacing.xs) {
                    CategoryChip(title: "All", systemImage: "square.grid.2x2",
                                 isSelected: selectedCategory == nil && !favoritesOnly) {
                        selectedCategory = nil; favoritesOnly = false
                    }
                    if actions.isFavorite != nil {
                        CategoryChip(title: "Favorites", systemImage: favoritesOnly ? "star.fill" : "star",
                                     isSelected: favoritesOnly) {
                            favoritesOnly.toggle()
                            if favoritesOnly { selectedCategory = nil }
                        }
                    }
                    ForEach(engine.registry.categories) { category in
                        CategoryChip(title: category.displayName, systemImage: category.iconSystemName,
                                     isSelected: selectedCategory == category) {
                            selectedCategory = selectedCategory == category ? nil : category
                            favoritesOnly = false
                        }
                    }
                }
            }
        }
        .padding(Theme.Spacing.md)
    }
}

/// A single scannable library row: icon/thumbnail, name and one-line summary,
/// and trailing favorite + add/remove controls. Tapping the row adds the effect
/// (or toggles its selection in multi-select mode).
private struct EffectRow: View {
    let descriptor: EffectDescriptor
    let actions: EffectLibraryActions
    var selectionMode: Bool = false
    var isSelected: Bool = false
    var onPrimary: () -> Void

    private var favorite: Bool { actions.isFavorite?(descriptor) ?? false }
    private var inStack: Bool { actions.isInStack?(descriptor) ?? false }

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            if let thumb = actions.thumbnail?(descriptor) {
                thumb.resizable().aspectRatio(contentMode: .fill)
                    .frame(width: 30, height: 20)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            } else {
                Image(systemName: descriptor.iconSystemName)
                    .foregroundStyle(Theme.categoryTint(descriptor.category))
                    .frame(width: 24)
            }

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(descriptor.name).font(.callout.weight(.medium)).lineLimit(1)
                    if descriptor.isCustom {
                        Image(systemName: "wand.and.stars").font(.caption2).foregroundStyle(.purple)
                    }
                }
                Text(descriptor.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }

            Spacer()

            if selectionMode {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Theme.accent : .secondary)
            } else {
                if let toggleFavorite = actions.toggleFavorite {
                    Button { toggleFavorite(descriptor) } label: {
                        Image(systemName: favorite ? "star.fill" : "star")
                            .foregroundStyle(favorite ? .yellow : .secondary)
                    }
                    .buttonStyle(.plain)
                }
                if let toggleEnabled = actions.toggleEnabled {
                    Button { toggleEnabled(descriptor) } label: {
                        Image(systemName: inStack ? "checkmark.circle.fill" : "plus.circle")
                            .foregroundStyle(inStack ? Theme.positive : Theme.accent)
                    }
                    .buttonStyle(.plain)
                    .help(inStack ? "Remove from stack" : "Add to stack")
                } else {
                    Image(systemName: "plus.circle").foregroundStyle(Theme.accent)
                }
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture { onPrimary() }
        .listRowBackground(rowBackground)
        .contextMenu { menu }
    }

    @ViewBuilder
    private var rowBackground: some View {
        if (selectionMode && isSelected) || (!selectionMode && inStack) {
            Theme.accent.opacity(0.12)
        } else {
            Color.clear
        }
    }

    @ViewBuilder
    private var menu: some View {
        Button("Add to Stack", systemImage: "plus") { onPrimary() }
        if let toggleFavorite = actions.toggleFavorite {
            Button(favorite ? "Remove Favorite" : "Add Favorite",
                   systemImage: favorite ? "star.slash" : "star") { toggleFavorite(descriptor) }
        }
        if descriptor.isCustom {
            Divider()
            let composite = actions.isComposite?(descriptor) ?? false
            if composite {
                if let edit = actions.edit {
                    Button("Edit", systemImage: "pencil") { edit(descriptor) }
                }
                if let duplicate = actions.duplicate {
                    Button("Duplicate & Edit", systemImage: "plus.square.on.square") { duplicate(descriptor) }
                }
            } else if let reveal = actions.revealInFinder {
                Button("Reveal in Finder", systemImage: "folder") { reveal(descriptor) }
            }
            if let export = actions.export {
                Button("Export…", systemImage: "square.and.arrow.up") { export(descriptor) }
            }
            if let delete = actions.delete {
                Button("Delete", systemImage: "trash", role: .destructive) { delete(descriptor) }
            }
        }
    }
}

/// Modal sheet wrapper for adding an effect from the stack.
struct EffectLibrarySheet: View {
    let engine: SpectraEngine
    var onAdd: (EffectDescriptor) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Add Effect").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(Theme.Spacing.lg)
            Divider()
            EffectLibraryView(engine: engine) { descriptor in
                onAdd(descriptor)
            }
        }
        .frame(width: 720, height: 560)
    }
}

struct CategoryChip: View {
    let title: String
    let systemImage: String
    let isSelected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.medium))
                .padding(.horizontal, Theme.Spacing.sm)
                .padding(.vertical, 5)
                .background(isSelected ? Theme.accent : Color.clear, in: Capsule())
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .overlay(Capsule().strokeBorder(Color.primary.opacity(isSelected ? 0 : 0.15)))
        }
        .buttonStyle(.plain)
    }
}
