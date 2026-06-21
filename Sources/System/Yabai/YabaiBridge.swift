import Foundation

/// Drives the `yabai` window manager CLI on behalf of the Window Transparency and
/// Window Layout system effects. Spectra cannot make real windows transparent or
/// move them from inside its own process; yabai (a Dock-level tool) can, so Spectra
/// acts as the control surface.
///
/// All work runs on a private serial queue because each call shells out to a
/// blocking `Process`. The bridge snapshots the user's yabai config before its first
/// change and restores it on deactivate, quit, or — via the on-disk snapshot — on the
/// next launch after a crash, so a dead Spectra never leaves windows stuck dimmed.
///
/// Lifted and reshaped from `os-mods/adaptive-menubar/Yabai.swift`.
final class YabaiBridge: @unchecked Sendable {
    /// Whether yabai is usable, surfaced to the inspector so the rows can gate.
    enum Availability: String, Sendable {
        case notInstalled   // no yabai binary on disk
        case notRunning     // installed, but the message socket isn't answering
        case ready          // the service answers queries

        var isReady: Bool { self == .ready }
    }

    /// Snapshot of the yabai config keys Spectra changes, so they can be put back.
    private struct Snapshot: Codable {
        var activeOpacity: Double
        var normalOpacity: Double
        var windowOpacityEnabled: Bool
        var blurEnabled: Bool
        var blurRadius: Int
        var spaceLayout: String
        var windowGap: Int
        var topPadding: Int
        var bottomPadding: Int
        var leftPadding: Int
        var rightPadding: Int
    }

    private let queue = DispatchQueue(label: "com.spectra.yabai")
    private let binaryPath: String?
    private var snapshot: Snapshot?
    /// Tracks which subsystems applied changes that need restoring; cleared when all have been restored.
    private var pendingRestores: Set<String> = []
    private static let snapshotFile = AppPaths.supportDirectory.appendingPathComponent("yabai-snapshot.json")

    init() {
        binaryPath = Self.locateBinary()
    }

    private static func locateBinary() -> String? {
        let candidates = ["/opt/homebrew/bin/yabai", "/usr/local/bin/yabai", "/run/current-system/sw/bin/yabai"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // MARK: - Availability

    private func availabilityNow() -> Availability {
        guard binaryPath != nil else { return .notInstalled }
        // `query --displays` answers only when the service is up and the socket is live.
        let probe = run(["-m", "query", "--displays"])
        return probe.status == 0 ? .ready : .notRunning
    }

    // MARK: - Transparency

    /// Apply global window opacity (and optional backdrop blur). Snapshots the prior
    /// config on the first call so `restoreTransparency` can put it back.
    func applyTransparency(active: Double, normal: Double, blurRadius: Double) {
        queue.async {
            guard self.availabilityNow().isReady else { return }
            self.captureSnapshotIfNeeded()
            self.pendingRestores.insert("transparency")
            self.setConfig("window_opacity", "on")
            self.setConfig("active_window_opacity", String(format: "%.3f", active))
            self.setConfig("normal_window_opacity", String(format: "%.3f", normal))
            if blurRadius > 0.5 {
                self.setConfig("window_blur", "on")
                self.setConfig("window_blur_radius", String(Int(blurRadius.rounded())))
            } else {
                self.setConfig("window_blur", "off")
            }
        }
    }

    /// Hand windows back fully opaque.
    func restoreTransparency() {
        queue.async {
            guard self.binaryPath != nil else { return }
            self.restoreOpaque()
            self.pendingRestores.remove("transparency")
            self.clearSnapshotIfFullyRestored()
        }
    }

    /// Turn window opacity off and reset both values to 1.0. Always restores to fully opaque
    /// rather than a captured value, so a prior unclean exit can't leave windows stuck dimmed.
    private func restoreOpaque() {
        setConfig("window_opacity", "off")
        setConfig("active_window_opacity", "1.0000")
        setConfig("normal_window_opacity", "1.0000")
        setConfig("window_blur", "off")
    }

    // MARK: - Layout

    /// Apply a tiling layout to the current Space plus global gap/padding.
    /// `layout`: 0 = bsp (tile), 1 = stack, 2 = float (management off).
    func applyLayout(layout: Int, gap: Double, padding: Double) {
        queue.async {
            guard self.availabilityNow().isReady else { return }
            self.captureSnapshotIfNeeded()
            self.pendingRestores.insert("layout")
            let name = ["bsp", "stack", "float"][max(0, min(2, layout))]
            self.run(["-m", "space", "--layout", name])
            self.setConfig("window_gap", String(Int(gap.rounded())))
            for edge in ["top", "bottom", "left", "right"] {
                self.setConfig("\(edge)_padding", String(Int(padding.rounded())))
            }
        }
    }

    /// Restore the Space layout and gap/padding to the snapshot (or float if none).
    func restoreLayout() {
        queue.async {
            guard self.binaryPath != nil else { return }
            let snap = self.snapshot
            self.run(["-m", "space", "--layout", snap?.spaceLayout ?? "float"])
            if let gap = snap?.windowGap { self.setConfig("window_gap", String(gap)) }
            if let snap {
                self.setConfig("top_padding", String(snap.topPadding))
                self.setConfig("bottom_padding", String(snap.bottomPadding))
                self.setConfig("left_padding", String(snap.leftPadding))
                self.setConfig("right_padding", String(snap.rightPadding))
            }
            self.pendingRestores.remove("layout")
            self.clearSnapshotIfFullyRestored()
        }
    }

    /// Synchronously restore opacity/blur and the Space layout from the snapshot, for
    /// quit time when an async restore might not run before the process exits. A no-op
    /// when nothing was changed (no snapshot taken).
    func shutdownRestore() {
        queue.sync {
            guard binaryPath != nil, let snap = snapshot else { return }
            restoreOpaque()
            run(["-m", "space", "--layout", snap.spaceLayout])
            setConfig("window_gap", String(snap.windowGap))
            setConfig("top_padding", String(snap.topPadding))
            setConfig("bottom_padding", String(snap.bottomPadding))
            setConfig("left_padding", String(snap.leftPadding))
            setConfig("right_padding", String(snap.rightPadding))
            snapshot = nil
            pendingRestores = []
            try? FileManager.default.removeItem(at: Self.snapshotFile)
        }
    }

    // MARK: - Crash recovery

    /// Restore from a snapshot left on disk by a previous run that didn't exit cleanly.
    /// Call once at launch before any apply; a no-op when the file is absent.
    func restoreFromDiskIfDirty() {
        queue.async {
            guard self.binaryPath != nil,
                  let snap = JSONStore.load(Snapshot.self, from: Self.snapshotFile) else { return }
            self.snapshot = snap
            guard self.availabilityNow().isReady else { return }   // can't restore now; keep the file for next launch
            self.restoreOpaque()
            self.run(["-m", "space", "--layout", snap.spaceLayout])
            self.snapshot = nil
            try? FileManager.default.removeItem(at: Self.snapshotFile)
        }
    }

    // MARK: - Snapshot internals

    private func captureSnapshotIfNeeded() {
        guard snapshot == nil else { return }
        let snap = Snapshot(
            activeOpacity: queryDouble("active_window_opacity") ?? 1.0,
            normalOpacity: queryDouble("normal_window_opacity") ?? 1.0,
            windowOpacityEnabled: queryString("window_opacity") == "on",
            blurEnabled: queryString("window_blur") == "on",
            blurRadius: Int(queryDouble("window_blur_radius") ?? 0),
            spaceLayout: querySpaceLayout() ?? "float",
            windowGap: Int(queryDouble("window_gap") ?? 0),
            topPadding: Int(queryDouble("top_padding") ?? 0),
            bottomPadding: Int(queryDouble("bottom_padding") ?? 0),
            leftPadding: Int(queryDouble("left_padding") ?? 0),
            rightPadding: Int(queryDouble("right_padding") ?? 0))
        snapshot = snap
        AppPaths.ensureDirectories()
        try? JSONStore.save(snap, to: Self.snapshotFile)
    }

    /// Drop the snapshot only when every subsystem that applied changes has been restored.
    /// A partial restore (e.g. only transparency) leaves the snapshot intact so the
    /// remaining subsystem (layout) can still read it and clear it on its own restore.
    private func clearSnapshotIfFullyRestored() {
        guard pendingRestores.isEmpty else { return }
        snapshot = nil
        try? FileManager.default.removeItem(at: Self.snapshotFile)
    }

    // MARK: - CLI

    private func setConfig(_ key: String, _ value: String) {
        run(["-m", "config", key, value])
    }

    private func queryDouble(_ key: String) -> Double? {
        let r = run(["-m", "config", key])
        return Double(r.out.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func queryString(_ key: String) -> String? {
        let r = run(["-m", "config", key])
        return r.status == 0 ? r.out.trimmingCharacters(in: .whitespacesAndNewlines) : nil
    }

    private func querySpaceLayout() -> String? {
        let r = run(["-m", "query", "--spaces", "--space"])
        guard r.status == 0, let data = r.out.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj["type"] as? String
    }

    @discardableResult
    private func run(_ args: [String]) -> (status: Int32, out: String) {
        guard let binaryPath else { return (-1, "") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return (-1, "")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
