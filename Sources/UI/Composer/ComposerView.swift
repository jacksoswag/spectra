import SwiftUI
import UniformTypeIdentifiers

/// The visual effect composer: Spectra's single in-app authoring surface. Users
/// build a new effect by stacking built-in building blocks, tuning each with the
/// standard inspector, watching a live preview, choosing which parameters to
/// expose, and editing metadata. Saving registers it as a reusable library
/// effect. (Advanced users author raw Metal externally and drop the file into the
/// library folder, where it is imported automatically.)
struct ComposerView: View {
    let engine: SpectraEngine
    var onClose: () -> Void

    @State private var stack = EffectStack()
    @State private var name: String
    @State private var subtitle: String
    @State private var category: EffectCategory
    @State private var tagText: String
    @State private var exposures: [ComposerExposure]
    @State private var editingID: String?
    @State private var showingAddStage = false
    @State private var status: String?

    init(engine: SpectraEngine, existing: ComposedEffect? = nil, fork: Bool = false, onClose: @escaping () -> Void) {
        self.engine = engine
        self.onClose = onClose
        if let existing {
            _name = State(initialValue: fork ? "\(existing.name) Copy" : existing.name)
            _subtitle = State(initialValue: existing.subtitle)
            _category = State(initialValue: existing.category)
            _tagText = State(initialValue: existing.tags.filter { $0 != "composed" }.joined(separator: ", "))
            _editingID = State(initialValue: fork ? nil : existing.id)
            // Rebuild the working stack and exposure mapping from the saved effect.
            let instances = existing.stages.map { stage in
                EffectInstance(descriptorID: stage.descriptorID, values: stage.values, universal: stage.universal)
            }
            let instanceIDs = instances.map(\.id)
            let working = EffectStack(chain: EffectChain(effects: instances))
            _stack = State(initialValue: working)
            _exposures = State(initialValue: existing.exposed.compactMap { exposed in
                guard exposed.stageIndex < instanceIDs.count else { return nil }
                return ComposerExposure(
                    instanceID: instanceIDs[exposed.stageIndex],
                    paramID: exposed.sourceParamID, label: exposed.label)
            })
        } else {
            _name = State(initialValue: "My Effect")
            _subtitle = State(initialValue: "Composed effect")
            _category = State(initialValue: .custom)
            _tagText = State(initialValue: "")
            _editingID = State(initialValue: nil)
            _stack = State(initialValue: EffectStack())
            _exposures = State(initialValue: [])
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                stagePanel
                    .frame(minWidth: 220, idealWidth: 240, maxWidth: 320)
                VStack(spacing: Theme.Spacing.sm) {
                    PreviewView(
                        engine: engine, displayID: engine.selectedDisplayID,
                        chainProvider: { engine.resolve(stack.chain()) }, showsIdleHint: false)
                        .frame(minHeight: 180)
                    InspectorView(engine: engine, stack: stack)
                }
                .padding(Theme.Spacing.sm)
                .frame(minWidth: 320)
                detailsPanel
                    .frame(minWidth: 280, idealWidth: 300, maxWidth: 360)
            }
        }
        .frame(width: 1040, height: 680)
        .sheet(isPresented: $showingAddStage) {
            BuildingBlockSheet(engine: engine) { descriptor in stack.add(descriptor) }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Text(editingID == nil ? "New Effect" : "Edit Effect").font(.title2.bold())
            if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
            Spacer()
            Button("Close") { onClose() }.keyboardShortcut(.cancelAction)
            Button { save() } label: { Label("Save", systemImage: "square.and.arrow.down") }
                .buttonStyle(.borderedProminent)
                .disabled(!canSave)
            Button("Save & Add") { if save() { addToStackAndClose() } }
                .disabled(!canSave)
        }
        .padding(Theme.Spacing.md)
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && !stack.effects.isEmpty
    }

    // MARK: Stage panel (left)

    private var stagePanel: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Building Blocks", systemImage: "square.stack.3d.up")
                    .font(.headline)
                Spacer()
                Button { showingAddStage = true } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
            }
            .padding(Theme.Spacing.md)
            Divider()
            if stack.effects.isEmpty {
                VStack(spacing: Theme.Spacing.sm) {
                    Image(systemName: "square.stack.3d.up.slash")
                        .font(.largeTitle).foregroundStyle(.tertiary)
                    Text("Add building blocks").font(.callout).foregroundStyle(.secondary)
                    Button { showingAddStage = true } label: { Label("Add Block", systemImage: "plus") }
                        .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $stack.selection) {
                    ForEach(stack.effects) { instance in
                        HStack(spacing: Theme.Spacing.sm) {
                            let descriptor = engine.registry.descriptor(instance.descriptorID)
                            Image(systemName: descriptor?.iconSystemName ?? "questionmark")
                                .foregroundStyle(descriptor.map { Theme.categoryTint($0.category) } ?? .secondary)
                                .frame(width: 20)
                            Text(descriptor?.name ?? instance.descriptorID).font(.callout)
                            Spacer()
                        }
                        .tag(instance.id)
                        .listRowSeparator(.hidden)
                        .contextMenu {
                            Button("Duplicate") { stack.duplicate(instance.id) }
                            Button("Remove", role: .destructive) { stack.remove(instance.id) }
                        }
                    }
                    .onMove { stack.move(fromOffsets: $0, toOffset: $1) }
                    .onDelete { offsets in offsets.map { stack.effects[$0].id }.forEach { stack.remove($0) } }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
        .background(.background)
    }

    // MARK: Details panel (right)

    private var detailsPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                InspectorSection(title: "Details") {
                    labeledField("Name") { TextField("Name", text: $name).textFieldStyle(.roundedBorder) }
                    labeledField("Description") { TextField("Description", text: $subtitle).textFieldStyle(.roundedBorder) }
                    HStack {
                        Text("Category").font(.callout)
                        Spacer()
                        Picker("", selection: $category) {
                            ForEach(EffectCategory.allCases) { Text($0.displayName).tag($0) }
                        }.labelsHidden().frame(maxWidth: 160)
                    }
                    labeledField("Tags") { TextField("comma, separated", text: $tagText).textFieldStyle(.roundedBorder) }
                }

                InspectorSection(title: "Exposed Parameters") {
                    if stack.effects.isEmpty {
                        Text("Add building blocks, then choose which of their parameters to expose on the finished effect.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(stack.effects.enumerated()), id: \.element.id) { _, instance in
                            exposureGroup(for: instance)
                        }
                    }
                }
            }
            .padding(Theme.Spacing.lg)
        }
    }

    @ViewBuilder
    private func exposureGroup(for instance: EffectInstance) -> some View {
        if let descriptor = engine.registry.descriptor(instance.descriptorID), !descriptor.parameters.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text(descriptor.name).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(descriptor.parameters) { parameter in
                    exposureRow(instance: instance, parameter: parameter)
                }
            }
        }
    }

    @ViewBuilder
    private func exposureRow(instance: EffectInstance, parameter: EffectParameter) -> some View {
        let index = exposures.firstIndex { $0.instanceID == instance.id && $0.paramID == parameter.id }
        HStack(spacing: Theme.Spacing.sm) {
            Toggle(isOn: Binding(
                get: { index != nil },
                set: { on in
                    if on {
                        exposures.append(ComposerExposure(
                            instanceID: instance.id, paramID: parameter.id, label: parameter.name))
                    } else if let index {
                        exposures.remove(at: index)
                    }
                })) { Text(parameter.name).font(.caption) }
                .toggleStyle(.checkbox)
            if let index {
                TextField("label", text: Binding(
                    get: { exposures[index].label },
                    set: { exposures[index].label = $0 }))
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
            }
        }
    }

    private func labeledField<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            content()
        }
    }

    // MARK: Save

    @discardableResult
    private func save() -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !stack.effects.isEmpty else { return false }

        let instances = stack.effects
        let stages = instances.map { ComposedStage($0) }
        let indexByInstance = Dictionary(uniqueKeysWithValues: instances.enumerated().map { ($1.id, $0) })
        var exposed: [ExposedParameter] = []
        for (i, exposure) in exposures.enumerated() {
            guard let stageIndex = indexByInstance[exposure.instanceID] else { continue }
            exposed.append(ExposedParameter(
                id: "p\(i)", label: exposure.label.isEmpty ? exposure.paramID : exposure.label,
                stageIndex: stageIndex, sourceParamID: exposure.paramID))
        }
        let isAnimated = instances.contains { engine.registry.descriptor($0.descriptorID)?.isAnimated ?? false }
        let tags = tagText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty } + ["composed"]

        let id = editingID ?? "composed.\(UUID().uuidString.prefix(8))"
        // Resolve the working chain for the thumbnail before saving.
        let thumbnail = engine.thumbnailRenderer.renderBase64PNG(chain: engine.resolve(stack.chain()))

        let effect = ComposedEffect(
            id: id, name: trimmed, subtitle: subtitle, category: category,
            tags: Array(Set(tags)).sorted(), stages: stages, exposed: exposed,
            isAnimated: isAnimated, thumbnailPNGBase64: thumbnail,
            createdAt: Date(), modifiedAt: Date())
        engine.saveComposedEffect(effect)
        editingID = id
        status = "Saved “\(trimmed)”."
        return true
    }

    private func addToStackAndClose() {
        guard let id = editingID, let descriptor = engine.registry.descriptor(id) else { return }
        engine.addToActiveStack(descriptor)
        onClose()
    }
}

/// A composer-local record of an exposed parameter, keyed by the working
/// instance id so it survives reordering until converted at save time.
private struct ComposerExposure: Identifiable {
    let id = UUID()
    var instanceID: UUID
    var paramID: String
    var label: String
}

/// Add sheet restricted to built-in building blocks (no custom/composed items,
/// to keep composites flat and non-recursive).
private struct BuildingBlockSheet: View {
    let engine: SpectraEngine
    var onAdd: (EffectDescriptor) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Add Building Block").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(Theme.Spacing.lg)
            Divider()
            EffectLibraryView(engine: engine, filter: { !$0.isCustom }) { descriptor in onAdd(descriptor) }
        }
        .frame(width: 720, height: 560)
    }
}

/// `FileDocument` for exporting a custom shader as JSON / `.spectra`.
struct ShaderFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    let shader: CustomShader

    init(shader: CustomShader) { self.shader = shader }
    init(configuration: ReadConfiguration) throws {
        let data = configuration.file.regularFileContents ?? Data()
        shader = try JSONStore.decode(CustomShader.self, from: data)
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: try JSONStore.encode(SpectraDocument.shader(shader)))
    }
}

/// `FileDocument` for exporting a composed effect.
struct ComposedEffectDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    let effect: ComposedEffect

    init(effect: ComposedEffect) { self.effect = effect }
    init(configuration: ReadConfiguration) throws {
        let data = configuration.file.regularFileContents ?? Data()
        effect = try JSONStore.decode(ComposedEffect.self, from: data)
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: try JSONStore.encode(SpectraDocument.composed(effect)))
    }
}
