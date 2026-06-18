import SwiftUI
import UniformTypeIdentifiers

/// The root Studio surface: one coherent workspace, no modes. Three columns left
/// to right — the live performance dashboard, the Effect Library (presets and
/// effects), and the active effect stack with its parameters. Effects render
/// directly on the desktop, so there's no separate preview. Creating, editing,
/// duplicating, and importing all funnel through the single shader editor
/// presented over this surface.
struct StudioView: View {
    @Bindable var engine: SpectraEngine
    @Environment(\.openWindow) private var openWindow

    @State private var editorTarget: EditorTarget?
    @State private var showingImporter = false
    @State private var savingPreset = false
    @State private var exportingShader: CustomShader?
    @State private var exportingComposite: ComposedEffect?
    @State private var exportingPreset: Preset?
    @State private var notice: Notice?

    var body: some View {
        workspace
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ControlWindowConfigurator(engine: engine))
        .toolbar { toolbar }
        .sheet(item: $editorTarget) { target in
            ComposerView(engine: engine, existing: target.composite, fork: target.isFork) {
                editorTarget = nil
            }
        }
        .sheet(isPresented: $savingPreset) {
            SaveChainAsPresetSheet(engine: engine)
        }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: ImportSupport.contentTypes,
            allowsMultipleSelection: true,
            onCompletion: handleImport)
        .fileExporter(
            isPresented: Binding(get: { exportingShader != nil }, set: { if !$0 { exportingShader = nil } }),
            document: exportingShader.map { ShaderFileDocument(shader: $0) },
            contentType: .json,
            defaultFilename: exportingShader?.name ?? "Effect") { _ in exportingShader = nil }
        .fileExporter(
            isPresented: Binding(get: { exportingComposite != nil }, set: { if !$0 { exportingComposite = nil } }),
            document: exportingComposite.map { ComposedEffectDocument(effect: $0) },
            contentType: .json,
            defaultFilename: exportingComposite?.name ?? "Effect") { _ in exportingComposite = nil }
        .fileExporter(
            isPresented: Binding(get: { exportingPreset != nil }, set: { if !$0 { exportingPreset = nil } }),
            document: exportingPreset.map { PresetFileDocument(preset: $0) },
            contentType: .json,
            defaultFilename: exportingPreset?.name ?? "Preset") { _ in exportingPreset = nil }
        .alert(item: $notice) { notice in
            Alert(title: Text(notice.title), message: Text(notice.message), dismissButton: .default(Text("OK")))
        }
    }

    // MARK: - Workspace

    private var workspace: some View {
        VStack(spacing: 0) {
            if !engine.permissionAuthorized {
                PermissionBanner(engine: engine)
            }
            HSplitView {
                PerformanceView(engine: engine)
                    .frame(minWidth: 240, idealWidth: 300, maxWidth: 420)
                libraryPanel
                    .frame(minWidth: 230, idealWidth: 280)
                rightPanel
                    .frame(minWidth: 250, idealWidth: 300, maxWidth: 460)
            }
            .frame(minHeight: 320)
        }
    }

    // MARK: Centre — Effect Library

    private var libraryPanel: some View {
        LibraryView(
            engine: engine,
            effectActions: libraryActions,
            onAddEffect: { engine.addToActiveStack($0) },
            onMultiAddEffects: { descriptors in descriptors.forEach { engine.addToActiveStack($0) } },
            onNewEffect: { editorTarget = .new },
            onImport: { showingImporter = true },
            onSavePreset: { savingPreset = true },
            onExportPreset: { exportingPreset = $0 })
    }

    private var libraryActions: EffectLibraryActions {
        EffectLibraryActions(
            edit: { descriptor in
                if let composite = engine.composedEffects.effect(for: descriptor.id) {
                    editorTarget = .edit(composite)
                }
            },
            duplicate: { descriptor in
                if let composite = engine.composedEffects.effect(for: descriptor.id) {
                    editorTarget = .duplicate(composite)
                }
            },
            delete: { descriptor in engine.deleteCustomShader(descriptor.id) },
            export: { descriptor in
                if let composite = engine.composedEffects.effect(for: descriptor.id) {
                    exportingComposite = composite
                } else {
                    exportingShader = engine.customShaders.shaders.first { $0.id == descriptor.id }
                }
            },
            revealInFinder: { _ in engine.openLibraryFolder() },
            toggleFavorite: { descriptor in engine.settings.toggleFavorite(descriptor.id) },
            isFavorite: { descriptor in engine.settings.isFavorite(descriptor.id) },
            isInStack: { descriptor in engine.isInActiveStack(descriptor.id) },
            isComposite: { descriptor in engine.composedEffects.effect(for: descriptor.id) != nil },
            thumbnail: { descriptor in
                engine.composedEffects.effect(for: descriptor.id)?.thumbnailImage.map { Image(nsImage: $0) }
            },
            toggleEnabled: { descriptor in engine.toggleInActiveStack(descriptor) })
    }

    // MARK: Right — Effect Stack

    private var rightPanel: some View {
        Group {
            if let stack = engine.activeStack {
                EffectStackView(engine: engine, stack: stack, onSavePreset: { savingPreset = true })
            } else {
                ContentUnavailableView(
                    "No Active Chain",
                    systemImage: "square.3.layers.3d",
                    description: Text("Select a display to edit its effect stack."))
            }
        }
        .background(.background)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            TransportButton(engine: engine)
        }

        ToolbarItemGroup(placement: .principal) {
            if engine.displays.count > 1 {
                Picker("Display", selection: Binding(
                    get: { engine.selectedDisplayID ?? engine.displays.first?.id },
                    set: { engine.selectedDisplayID = $0 })) {
                    ForEach(engine.displays) { display in
                        Text(display.name).tag(Optional(display.id))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 200)
            }
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                openWindow(id: "settings")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .help("Open settings")
        }
    }

    // MARK: - Import

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            notice = Notice(title: "Import Failed", message: error.localizedDescription)
        case .success(let urls):
            var imported = 0
            var failures: [String] = []
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    _ = try engine.importFile(at: url)
                    imported += 1
                } catch {
                    failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
            if !failures.isEmpty {
                notice = Notice(title: imported > 0 ? "Partially Imported" : "Import Failed",
                                message: failures.joined(separator: "\n"))
            }
        }
    }
}

// MARK: - Editor target

/// The composer's entry points: a fresh effect, editing a composite, or forking
/// one. (Raw imported shaders are edited externally, not in the composer.)
enum EditorTarget: Identifiable {
    case new
    case edit(ComposedEffect)
    case duplicate(ComposedEffect)

    var id: String {
        switch self {
        case .new: "new"
        case .edit(let effect): "edit-\(effect.id)"
        case .duplicate(let effect): "duplicate-\(effect.id)"
        }
    }

    var composite: ComposedEffect? {
        switch self {
        case .new: nil
        case .edit(let effect), .duplicate(let effect): effect
        }
    }

    var isFork: Bool { if case .duplicate = self { true } else { false } }
}

/// Acceptable file types for the unified importer: `.metal`, `.shader`, `.json`,
/// and `.spectra`. Built from registered UTIs with text fallbacks so loosely
/// typed shader files still pass the open panel's filter.
enum ImportSupport {
    static var contentTypes: [UTType] {
        var types: [UTType] = [.json, .sourceCode, .plainText]
        let byIdentifier = ["com.spectra.preset"].compactMap { UTType($0) }
        let byExtension = ["spectra", "metal", "shader"].compactMap { UTType(filenameExtension: $0) }
        types.append(contentsOf: byIdentifier)
        types.append(contentsOf: byExtension)
        // De-duplicate while preserving order.
        var seen = Set<UTType>()
        return types.filter { seen.insert($0).inserted }
    }
}

private struct Notice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

// MARK: - Transport (the single on/off control)

/// One button drives the whole on/off system: a green ▶ to start, a red ◼ to
/// stop. It replaces the old power toggle, the per-display toggle, and the pause
/// button — there is no separate "paused" or "this display" state any more.
private struct TransportButton: View {
    @Bindable var engine: SpectraEngine

    var body: some View {
        Button {
            engine.toggleEnabled()
        } label: {
            Label(engine.isEnabled ? "Stop" : "Start",
                  systemImage: engine.isEnabled ? "stop.fill" : "play.fill")
                .foregroundStyle(engine.isEnabled ? Color.red : Color.green)
        }
        .help(engine.isEnabled ? "Stop effects" : "Start effects")
    }
}

// MARK: - Preset sheets

/// Captures the active chain as a named preset.
private struct SaveChainAsPresetSheet: View {
    let engine: SpectraEngine
    @Environment(\.dismiss) private var dismiss
    @State private var name = "My Preset"
    @State private var summary = ""
    @State private var tagsText = ""
    @State private var category: PresetCategory = .user

    /// Custom, comma-separated tags. Each becomes a filter chip in the preset list.
    private var parsedTags: [String] {
        tagsText.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Text("Create Preset").font(.title2.bold())
            TextField("Name", text: $name).textFieldStyle(.roundedBorder)
            TextField("Description", text: $summary).textFieldStyle(.roundedBorder)
            VStack(alignment: .leading, spacing: 2) {
                TextField("Tags (comma-separated)", text: $tagsText).textFieldStyle(.roundedBorder)
                Text("Your tags become filter chips in the preset list on the left.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Picker("Category", selection: $category) {
                ForEach(PresetCategory.allCases) { Text($0.displayName).tag($0) }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    engine.saveCurrentAsPreset(name: name, category: category,
                                               summary: summary, tags: parsedTags)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(Theme.Spacing.lg)
        .frame(width: 400)
    }
}
