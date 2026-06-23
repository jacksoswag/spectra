import SwiftUI
import UniformTypeIdentifiers

/// The root Studio surface: one coherent workspace, no modes. The Effect Library
/// (presets and effects) sits on the left; the right panel switches between the
/// active **Effects** stack (with its parameters below) and the **Glass** desktop
/// treatments. The live performance dashboard collapses into a drawer along the
/// bottom. Effects render directly on the desktop, so there's no separate preview.
/// Creating, editing, duplicating, and importing all funnel through the single shader
/// editor presented over this surface.
struct StudioView: View {
    @Bindable var engine: SpectraEngine
    @Environment(\.openWindow) private var openWindow

    /// Which surface the right panel shows: the effect stack or the Glass treatments.
    private enum RightTab: String, CaseIterable, Identifiable {
        case effects = "Effects"
        case glass = "Glass"
        var id: String { rawValue }
    }
    @State private var rightTab: RightTab = .effects

    @State private var editorTarget: EditorTarget?
    @State private var showingImporter = false
    @State private var savingPreset = false
    @State private var exportingShader: CustomShader?
    @State private var exportingComposite: ComposedEffect?
    @State private var exportingPreset: Preset?
    @State private var notice: Notice?
    @State private var pendingShaderImport: PendingShaderImport?

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
            onCompletion: requestImport)
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
        .confirmationDialog(
            "Import custom shader code?",
            isPresented: Binding(get: { pendingShaderImport != nil }, set: { if !$0 { pendingShaderImport = nil } })) {
            Button("Import", role: .destructive) {
                if let pending = pendingShaderImport { performImport(pending.urls) }
                pendingShaderImport = nil
            }
            Button("Cancel", role: .cancel) { pendingShaderImport = nil }
        } message: {
            Text("These files contain Metal shader code that runs on your GPU every frame. Only import shaders from sources you trust.")
        }
        .sheet(isPresented: Binding(
            get: { engine.license.gatePrompted },
            set: { if !$0 { engine.license.gatePrompted = false } })) {
            LicenseGateView(engine: engine) { engine.license.gatePrompted = false }
        }
        // First-run welcome (previously hosted by the now-removed Worlds RootView).
        .sheet(isPresented: Binding(
            get: { !engine.settings.hasSeenWelcome },
            set: { if !$0 { engine.settings.hasSeenWelcome = true } })) {
            WelcomeView(engine: engine) { engine.settings.hasSeenWelcome = true }
        }
    }

    // MARK: - Workspace

    private var workspace: some View {
        VStack(spacing: 0) {
            if !engine.permissionAuthorized {
                PermissionBanner(engine: engine)
            }
            if let message = engine.statusMessage {
                StatusBanner(message: message) { engine.dismissStatusMessage() }
            }
            UpgradeBanner(engine: engine)
            HSplitView {
                libraryPanel
                    .frame(minWidth: 230, idealWidth: 280)
                rightPanel
                    .frame(minWidth: 300, idealWidth: 360, maxWidth: 560)
            }
            .frame(minHeight: 320)
            // Performance lives in a collapsible drawer pinned to the bottom, hidden
            // by default so the workspace stays focused on building looks.
            PerformanceDrawer(engine: engine)
        }
    }

    // MARK: Centre — Effect Library

    private var libraryPanel: some View {
        LibraryView(
            engine: engine,
            effectActions: libraryActions,
            onAddEffect: { engine.addToActiveStack($0) },
            onMultiAddEffects: { descriptors in descriptors.forEach { engine.addToActiveStack($0) } },
            onNewEffect: { engine.canEdit ? (editorTarget = .new) : engine.license.promptGate() },
            onImport: { showingImporter = true },
            onSavePreset: { engine.canEdit ? (savingPreset = true) : engine.license.promptGate() },
            onExportPreset: { exportingPreset = $0 })
    }

    private var libraryActions: EffectLibraryActions {
        EffectLibraryActions(
            edit: { descriptor in
                guard engine.canEdit else { engine.license.promptGate(); return }
                if let composite = engine.composedEffects.effect(for: descriptor.id) {
                    editorTarget = .edit(composite)
                }
            },
            duplicate: { descriptor in
                guard engine.canEdit else { engine.license.promptGate(); return }
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

    // MARK: Right — Effects stack / Glass

    private var rightPanel: some View {
        VStack(spacing: 0) {
            // The two faces of the panel: the per-display effect stack, or the global
            // Glass desktop treatments. Glass replaces the stack entirely when selected.
            Picker("", selection: $rightTab.animation(.easeInOut(duration: 0.15))) {
                ForEach(RightTab.allCases) { tab in Text(tab.rawValue).tag(tab) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(Theme.Spacing.md)

            Divider()

            switch rightTab {
            case .effects: effectsPanel
            case .glass: GlassStackView(engine: engine)
            }
        }
        .background(.background)
    }

    @ViewBuilder
    private var effectsPanel: some View {
        if let stack = engine.activeStack {
            // Stack grid on top; the selected effect's parameter sliders below. The
            // inspector reads `stack.selection`, so tapping a tile reveals its controls.
            VSplitView {
                EffectStackView(engine: engine, stack: stack, onSavePreset: { savingPreset = true })
                    .frame(minHeight: 180, idealHeight: 280)
                InspectorView(engine: engine, stack: stack)
                    .frame(minHeight: 180)
            }
        } else {
            ContentUnavailableView(
                "No Active Chain",
                systemImage: "square.grid.2x2",
                description: Text("Select a display to edit its effect stack."))
        }
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
            Toggle(isOn: Binding(
                get: { engine.settings.showInScreenshots },
                set: { engine.setShowInScreenshots($0) })) {
                Label("Show in Screenshots", systemImage: "camera.viewfinder")
            }
            .toggleStyle(.button)
            .help(engine.settings.showInScreenshots
                  ? "Effects appear in screenshots and screen recordings. Turn off to hide the overlay from capture."
                  : "Effects are hidden from screenshots and screen recordings. Turn on to include them.")

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

    /// Triage the picked files. Raw `.metal`/`.shader` files compile to GPU code that
    /// runs every frame, so they route through a trust confirmation first; everything
    /// else imports straight away.
    // ponytail: confirmation keys on the raw-shader extension, the obvious code case.
    // A shader embedded inside a .spectra/.json document still imports unconfirmed; add
    // a pre-decode peek there if shared documents become a real distribution channel.
    private func requestImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            notice = Notice(title: "Import Failed", message: error.localizedDescription)
        case .success(let urls):
            let rawShaderExtensions: Set<String> = ["metal", "shader"]
            if urls.contains(where: { rawShaderExtensions.contains($0.pathExtension.lowercased()) }) {
                pendingShaderImport = PendingShaderImport(urls: urls)
            } else {
                performImport(urls)
            }
        }
    }

    private func performImport(_ urls: [URL]) {
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

/// A set of picked files awaiting the user's trust confirmation before raw shader
/// code is compiled and run.
private struct PendingShaderImport: Identifiable {
    let id = UUID()
    let urls: [URL]
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
    @State private var category: String = PresetCategory.userName
    /// nil = use the category's icon (the generic default).
    @State private var icon: String?

    private static let iconChoices = [
        "sparkles", "paintpalette", "camera.filters", "film", "tv", "wand.and.stars",
        "moon.stars", "sun.max", "leaf", "flame", "bolt", "drop", "cube", "circle.hexagongrid",
    ]

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
            TextField("Description (optional)", text: $summary).textFieldStyle(.roundedBorder)

            VStack(alignment: .leading, spacing: 4) {
                Text("Icon (optional)").font(.caption).foregroundStyle(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Theme.Spacing.sm) {
                        iconButton(nil)
                        ForEach(Self.iconChoices, id: \.self) { iconButton($0) }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                TextField("Tags (comma-separated, optional)", text: $tagsText).textFieldStyle(.roundedBorder)
                Text("Your tags become filter chips in the preset list on the left.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Picker("Category", selection: $category) {
                ForEach(engine.presets.saveTargets, id: \.self) { Text($0).tag($0) }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    engine.saveCurrentAsPreset(name: name, category: category,
                                               summary: summary, icon: icon, tags: parsedTags)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(Theme.Spacing.lg)
        .frame(width: 400)
    }

    private func iconButton(_ symbol: String?) -> some View {
        let isSelected = icon == symbol
        return Button { icon = symbol } label: {
            Image(systemName: symbol ?? PresetCategory.icon(for: category))
                .frame(width: 30, height: 30)
                .background(isSelected ? Theme.accent.opacity(0.25) : Color.clear,
                            in: RoundedRectangle(cornerRadius: Theme.Radius.sm))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.sm)
                    .strokeBorder(isSelected ? Theme.accent : Color.secondary.opacity(0.3)))
        }
        .buttonStyle(.plain)
        .help(symbol == nil ? "Default (category icon)" : symbol!)
    }
}
