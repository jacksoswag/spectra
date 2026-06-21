import SwiftUI

/// The ordered, layered list of effects for the active display. Supports
/// selection, drag reordering, enable/disable, duplicate, remove, rename, and
/// grouping (create, rename, enable, collapse, ungroup). Effects render top to
/// bottom; grouped effects stay contiguous.
struct EffectStackView: View {
    let engine: SpectraEngine
    @Bindable var stack: EffectStack
    /// Save the current chain as a preset (surfaced in the footer, where the chain
    /// is built, so the action is discoverable without hunting in the library).
    var onSavePreset: (() -> Void)?
    @State private var showingLibrary = false
    @State private var renamingInstance: UUID?
    @State private var renamingGroup: UUID?
    @State private var renameText = ""
    @State private var showingClearConfirm = false

    /// One visible line in the stack: a group header or an effect row. Collapsed
    /// groups contribute only their header.
    private enum Row: Identifiable {
        case group(EffectGroup)
        case effect(EffectInstance, grouped: Bool)
        var id: String {
            switch self {
            case .group(let g): "g-\(g.id)"
            case .effect(let e, _): "e-\(e.id)"
            }
        }
    }

    private var rows: [Row] {
        var result: [Row] = []
        var emitted = Set<UUID>()
        for instance in stack.effects {
            if let gid = instance.groupID, let group = stack.groups.first(where: { $0.id == gid }) {
                if !emitted.contains(gid) {
                    emitted.insert(gid)
                    result.append(.group(group))
                }
                if !group.isCollapsed { result.append(.effect(instance, grouped: true)) }
            } else {
                result.append(.effect(instance, grouped: false))
            }
        }
        return result
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if stack.effects.isEmpty {
                emptyState
            } else {
                list
            }
            Divider()
            footer
        }
        .sheet(isPresented: $showingLibrary) {
            EffectLibrarySheet(engine: engine) { descriptor in stack.add(descriptor) }
        }
        .alert("Rename Effect", isPresented: Binding(
            get: { renamingInstance != nil }, set: { if !$0 { renamingInstance = nil } })) {
            TextField("Name", text: $renameText)
            Button("Rename") { if let id = renamingInstance { stack.rename(id, to: renameText) }; renamingInstance = nil }
            Button("Cancel", role: .cancel) { renamingInstance = nil }
        }
        .alert("Rename Group", isPresented: Binding(
            get: { renamingGroup != nil }, set: { if !$0 { renamingGroup = nil } })) {
            TextField("Name", text: $renameText)
            Button("Rename") { if let id = renamingGroup { stack.renameGroup(id, to: renameText) }; renamingGroup = nil }
            Button("Cancel", role: .cancel) { renamingGroup = nil }
        }
    }

    private var header: some View {
        HStack {
            Label("Effect Stack", systemImage: "square.3.layers.3d")
                .font(.headline)
            Spacer()
            Text("\(stack.effects.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(.quaternary, in: Capsule())
        }
        .padding(Theme.Spacing.md)
    }

    private var list: some View {
        List(selection: $stack.selection) {
            ForEach(rows) { row in
                switch row {
                case .group(let group):
                    GroupHeaderRow(
                        stack: stack, group: group,
                        rename: { renameText = group.name; renamingGroup = group.id })
                        .listRowSeparator(.hidden)
                        .selectionDisabled()
                case .effect(let instance, let grouped):
                    EffectStackRow(engine: engine, stack: stack, instance: instance)
                        .padding(.leading, grouped ? Theme.Spacing.md : 0)
                        .tag(instance.id)
                        .listRowSeparator(.hidden)
                        .contextMenu { rowMenu(instance) }
                }
            }
            .onMove(perform: moveRows)
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
    }

    /// Translate a drag on the visible rows into a move of the underlying effect
    /// list. Group headers are not draggable; dropping next to an effect uses
    /// that effect's real index as the target.
    private func moveRows(from source: IndexSet, to destination: Int) {
        let rows = self.rows
        guard let sourceRow = source.first else { return }
        guard case let .effect(moved, _) = rows[sourceRow] else { return }

        // Find the real target index in stack.effects from the destination row.
        let targetEffectID: UUID?
        if destination >= rows.count {
            targetEffectID = nil
        } else {
            // Walk forward from destination to the next effect row.
            var idx = destination
            var found: UUID?
            while idx < rows.count {
                if case let .effect(inst, _) = rows[idx] { found = inst.id; break }
                idx += 1
            }
            targetEffectID = found
        }
        let targetIndex = targetEffectID.flatMap { stack.index(of: $0) } ?? stack.effects.count
        stack.move(id: moved.id, toIndex: targetIndex)
    }

    private var emptyState: some View {
        VStack(spacing: Theme.Spacing.sm) {
            Image(systemName: "square.3.layers.3d.slash")
                .font(.largeTitle).foregroundStyle(.tertiary)
            Text("No effects yet").font(.headline).foregroundStyle(.secondary)
            Button { showingLibrary = true } label: { Label("Add Effect", systemImage: "plus") }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var footer: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Button { showingLibrary = true } label: { Image(systemName: "plus") }
                .help("Add effect").accessibilityLabel("Add effect")
            Button { if let id = stack.selection { stack.duplicate(id) } } label: { Image(systemName: "plus.square.on.square") }
                .help("Duplicate").accessibilityLabel("Duplicate effect").disabled(stack.selection == nil)
            Button { stack.removeSelected() } label: { Image(systemName: "trash") }
                .help("Remove").accessibilityLabel("Remove effect").disabled(stack.selection == nil)
            Spacer()
            if let editable = engine.editablePresetForSelectedDisplay {
                Button { engine.updatePreset(editable) } label: { Image(systemName: "square.and.pencil") }
                    .help("Update the “\(editable.name)” preset with this stack")
                    .accessibilityLabel("Update \(editable.name) preset")
                    .disabled(stack.effects.isEmpty)
            }
            if let onSavePreset {
                Button { onSavePreset() } label: { Image(systemName: "square.and.arrow.down") }
                    .help("Create a new preset from this stack").accessibilityLabel("Create preset").disabled(stack.effects.isEmpty)
            }
            Button { groupSelected() } label: { Image(systemName: "rectangle.3.group") }
                .help("Group selected effect").accessibilityLabel("Group selected effect").disabled(stack.selection == nil)
            Button { showingClearConfirm = true } label: { Image(systemName: "xmark.bin") }
                .help("Clear all").accessibilityLabel("Clear all effects").disabled(stack.effects.isEmpty)
        }
        .buttonStyle(.borderless)
        .padding(Theme.Spacing.sm)
        .confirmationDialog("Clear all effects?", isPresented: $showingClearConfirm, titleVisibility: .visible) {
            Button("Clear All", role: .destructive) { stack.clear() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes every effect from this display's stack. It can't be undone.")
        }
    }

    @ViewBuilder
    private func rowMenu(_ instance: EffectInstance) -> some View {
        Button("Rename…") {
            renameText = instance.name ?? engine.registry.descriptor(instance.descriptorID)?.name ?? ""
            renamingInstance = instance.id
        }
        Button("Duplicate") { stack.duplicate(instance.id) }
        Button(instance.isEnabled ? "Disable" : "Enable") { stack.toggleEnabled(instance.id) }
        Menu("Move to Group") {
            Button("New Group") {
                let g = stack.createGroup(named: "Group \(stack.groups.count + 1)", members: [instance.id])
                _ = g
            }
            ForEach(stack.groups) { group in
                Button(group.name) { stack.setGroup(group.id, for: instance.id) }
            }
            if instance.groupID != nil {
                Divider()
                Button("Remove from Group") { stack.setGroup(nil, for: instance.id) }
            }
        }
        Divider()
        Button("Remove", role: .destructive) { stack.remove(instance.id) }
    }

    private func groupSelected() {
        guard let id = stack.selection else { return }
        _ = stack.createGroup(named: "Group \(stack.groups.count + 1)", members: [id])
    }
}

/// A group header row: collapse chevron, name, enable toggle, and a menu.
private struct GroupHeaderRow: View {
    let stack: EffectStack
    let group: EffectGroup
    var rename: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Button { stack.toggleGroupCollapsed(group.id) } label: {
                Image(systemName: group.isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.borderless)
            Image(systemName: "rectangle.3.group.fill").foregroundStyle(Theme.accent)
            Text(group.name).font(.subheadline.weight(.semibold))
                .opacity(group.isEnabled ? 1 : 0.5)
            Spacer()
            Button { stack.setGroupEnabled(!group.isEnabled, groupID: group.id) } label: {
                Image(systemName: group.isEnabled ? "eye" : "eye.slash")
                    .foregroundStyle(group.isEnabled ? Theme.accent : .secondary)
            }
            .buttonStyle(.borderless)
            Menu {
                Button("Rename…", action: rename)
                Button(group.isEnabled ? "Disable Group" : "Enable Group") {
                    stack.setGroupEnabled(!group.isEnabled, groupID: group.id)
                }
                Divider()
                Button("Ungroup", role: .destructive) { stack.ungroup(group.id) }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton).fixedSize()
        }
        .padding(.vertical, 3)
        .padding(.horizontal, Theme.Spacing.xs)
        .background(Theme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: Theme.Radius.sm))
    }
}

private struct EffectStackRow: View {
    let engine: SpectraEngine
    let stack: EffectStack
    let instance: EffectInstance

    private var descriptor: EffectDescriptor? { engine.registry.descriptor(instance.descriptorID) }

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: descriptor?.iconSystemName ?? "questionmark")
                .foregroundStyle(descriptor.map { Theme.categoryTint($0.category) } ?? .secondary)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(instance.name ?? descriptor?.name ?? instance.descriptorID)
                    .font(.callout.weight(.medium))
                    .opacity(instance.isEnabled ? 1 : 0.5)
                // Strength lives once, in the inspector's Universal section (with
                // opacity and blend), rather than being duplicated on every row.
                if let descriptor {
                    Text(descriptor.category.displayName)
                        .font(.caption2).foregroundStyle(.secondary)
                        .opacity(instance.isEnabled ? 1 : 0.5)
                }
            }

            Button { stack.toggleEnabled(instance.id) } label: {
                Image(systemName: instance.isEnabled ? "eye" : "eye.slash")
                    .foregroundStyle(instance.isEnabled ? Theme.accent : .secondary)
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 2)
    }
}
