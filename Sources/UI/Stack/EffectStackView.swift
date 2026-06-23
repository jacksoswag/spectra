import SwiftUI

/// The active display's effect chain, shown as a grid of square tiles — one per
/// effect, each with an on/off switch. Tap a tile to select it; its parameters
/// (Strength, Opacity, Blend, and the effect's own controls) appear in the inspector
/// below. Effects render in grid order (left to right, top to bottom); drag a tile
/// onto another to reorder. Add / duplicate / remove / save live in the footer.
struct EffectStackView: View {
    let engine: SpectraEngine
    @Bindable var stack: EffectStack
    /// Save the current chain as a preset (surfaced in the footer, where the chain
    /// is built, so the action is discoverable without hunting in the library).
    var onSavePreset: (() -> Void)?
    @State private var showingLibrary = false
    @State private var renamingInstance: UUID?
    @State private var renameText = ""
    @State private var showingClearConfirm = false
    @State private var showSketchHelp = false

    private let columns = [GridItem(.adaptive(minimum: 96, maximum: 140), spacing: Theme.Spacing.sm)]

    /// The sketch (draw-on-screen) effect; its first appearance triggers the one-time help popup.
    private var stackHasSketch: Bool {
        stack.effects.contains { $0.descriptorID == "interaction.pencilDraw" }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if stack.effects.isEmpty {
                emptyState
            } else {
                grid
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
        // First time the sketch effect lands in the stack (added directly or via the Pencil Sketch
        // preset), show the one-time draw/erase help. `initial: true` also catches a stack that
        // already has it when the view appears.
        .onChange(of: stackHasSketch, initial: true) { _, hasSketch in
            if hasSketch && !engine.settings.hasSeenSketchHelp {
                engine.settings.hasSeenSketchHelp = true
                showSketchHelp = true
            }
        }
        .sheet(isPresented: $showSketchHelp) {
            SketchHelpView { showSketchHelp = false }
        }
    }

    private var header: some View {
        HStack {
            Label("Effect Stack", systemImage: "square.grid.2x2")
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

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: Theme.Spacing.sm) {
                ForEach(stack.effects) { instance in
                    EffectTile(
                        engine: engine, stack: stack, instance: instance,
                        isSelected: stack.selection == instance.id,
                        select: { stack.selection = instance.id },
                        rename: { renameText = instance.name ?? engine.registry.descriptor(instance.descriptorID)?.name ?? ""; renamingInstance = instance.id })
                        .draggable(instance.id.uuidString)
                        .dropDestination(for: String.self) { items, _ in
                            guard let dragged = items.first else { return false }
                            return handleDrop(dragged, onto: instance)
                        }
                }
            }
            .padding(Theme.Spacing.md)
        }
        .scrollContentBackground(.hidden)
    }

    /// Reorder: dropping a tile onto another moves it to that tile's position.
    private func handleDrop(_ draggedID: String, onto target: EffectInstance) -> Bool {
        guard let id = UUID(uuidString: draggedID), id != target.id,
              let to = stack.index(of: target.id) else { return false }
        stack.move(id: id, toIndex: to)
        return true
    }

    private var emptyState: some View {
        VStack(spacing: Theme.Spacing.sm) {
            Image(systemName: "square.grid.2x2")
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
            Button { showingClearConfirm = true } label: { Image(systemName: "xmark.bin") }
                .help("Clear all").accessibilityLabel("Clear all effects").disabled(stack.effects.isEmpty)
        }
        .buttonStyle(.borderless)
        .padding(Theme.Spacing.sm)
        .disabled(!engine.canEdit)   // free tier: editing is a licensed feature
        .confirmationDialog("Clear all effects?", isPresented: $showingClearConfirm, titleVisibility: .visible) {
            Button("Clear All", role: .destructive) { stack.clear() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes every effect from this display's stack. It can't be undone.")
        }
    }
}

/// One square effect tile: category-tinted icon, name, and an on/off switch. Tapping
/// the tile body selects it (revealing its parameters in the inspector); the switch
/// toggles it without changing the selection.
private struct EffectTile: View {
    let engine: SpectraEngine
    let stack: EffectStack
    let instance: EffectInstance
    let isSelected: Bool
    var select: () -> Void
    var rename: () -> Void

    private var descriptor: EffectDescriptor? { engine.registry.descriptor(instance.descriptorID) }
    private var isEnabled: Bool { stack[instance.id]?.isEnabled ?? instance.isEnabled }

    var body: some View {
        VStack(spacing: Theme.Spacing.xs) {
            HStack {
                Image(systemName: descriptor?.iconSystemName ?? "questionmark")
                    .font(.title2)
                    .foregroundStyle(descriptor.map { Theme.categoryTint($0.category) } ?? .secondary)
                Spacer()
                Toggle("", isOn: Binding(
                    get: { isEnabled },
                    set: { stack.setEnabled($0, on: instance.id) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
            }
            Spacer(minLength: 0)
            Text(instance.name ?? descriptor?.name ?? instance.descriptorID)
                .font(.caption.weight(.medium))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .opacity(isEnabled ? 1 : 0.45)
        .padding(Theme.Spacing.sm)
        .frame(height: 92, alignment: .topLeading)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .fill(isSelected ? Theme.accent.opacity(0.14) : Color.secondary.opacity(0.08)))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .strokeBorder(isSelected ? Theme.accent : Color.clear, lineWidth: 2))
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
        .onTapGesture { select() }
        .contextMenu {
            Button("Rename…", action: rename)
            Button("Duplicate") { stack.duplicate(instance.id) }
            Button(isEnabled ? "Disable" : "Enable") { stack.toggleEnabled(instance.id) }
            Divider()
            Button("Remove", role: .destructive) { stack.remove(instance.id) }
        }
    }
}
