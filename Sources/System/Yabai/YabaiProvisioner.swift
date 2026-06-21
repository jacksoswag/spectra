import Foundation

/// Makes yabai "part of the app": installs it via Homebrew if missing, starts its
/// service, and (for window opacity) installs the scripting addition behind a single
/// admin-password prompt. So the user does nothing manual beyond approving that one
/// prompt and, on a stock Mac, the one-time SIP step that only they can perform.
///
/// The privileged step is ported from `os-mods/deploy-yabai.sh`: pin the binary's
/// SHA-256 in a `sudoers.d` entry for passwordless `--load-sa`, validate it with
/// `visudo -cf`, and re-hash to close the TOCTOU window. It runs once as root inside a
/// single `do shell script ... with administrator privileges`, then subsequent launches
/// load the addition passwordlessly via that pinned entry.
final class YabaiProvisioner: @unchecked Sendable {
    enum Status: Equatable, Sendable {
        case unknown
        case notInstalled        // yabai absent (will auto-install on enable)
        case installing          // Homebrew install in progress
        case starting            // bringing the service up
        case authorizing         // waiting on the admin prompt for the scripting addition
        case sipRequired         // opacity needs SIP disabled (one-time Recovery step)
        case ready               // service up: tiling and layout work
        case opacityReady        // scripting addition loaded: opacity and blur work too
        case failed(String)
    }

    private let queue = DispatchQueue(label: "com.spectra.yabai.provision")
    private var weStartedService = false

    private static let sudoersPath = "/etc/sudoers.d/yabai"

    private var brewPath: String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    private func yabaiPath() -> String? {
        ["/opt/homebrew/bin/yabai", "/usr/local/bin/yabai"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // MARK: - Read-only probe (no install, no prompt)

    /// Report the current state without side effects, for the inspector. Never installs,
    /// starts, or prompts. `needsOpacity` decides whether SIP/scripting-addition state matters.
    func probe(needsOpacity: Bool, _ status: @escaping @Sendable (Status) -> Void) {
        queue.async {
            let result = self.probeNow(needsOpacity: needsOpacity)
            DispatchQueue.main.async { status(result) }
        }
    }

    private func probeNow(needsOpacity: Bool) -> Status {
        guard let yabai = yabaiPath() else { return .notInstalled }
        guard serviceRunning(yabai) else { return .ready }   // installed; service will start on enable
        guard needsOpacity else { return .ready }
        if !sipDisabled() { return .sipRequired }
        // The pinned sudoers entry is a read-only proxy for "opacity already set up".
        return FileManager.default.fileExists(atPath: Self.sudoersPath) ? .opacityReady : .ready
    }

    // MARK: - Active provisioning (may install, start, prompt)

    /// Ensure yabai is installed and running, and (when `needsOpacity`) that the scripting
    /// addition is loaded. Emits status transitions on the main thread; the terminal status
    /// is `.ready`, `.opacityReady`, `.sipRequired`, or `.failed`.
    func provision(needsOpacity: Bool, _ status: @escaping @Sendable (Status) -> Void) {
        queue.async {
            func emit(_ s: Status) { DispatchQueue.main.async { status(s) } }

            var path = self.yabaiPath()
            if path == nil {
                guard let brew = self.brewPath else {
                    emit(.failed("yabai isn't installed and Homebrew wasn't found to install it.")); return
                }
                emit(.installing)
                _ = self.run(brew, ["install", "koekeishiya/formulae/yabai"])
                path = self.yabaiPath()
                guard path != nil else { emit(.failed("Homebrew couldn't install yabai.")); return }
            }
            guard let yabai = path else { emit(.failed("yabai is unavailable.")); return }

            if !self.serviceRunning(yabai) {
                emit(.starting)
                _ = self.run(yabai, ["--start-service"])
                self.weStartedService = true
                for _ in 0..<12 where !self.serviceRunning(yabai) { Thread.sleep(forTimeInterval: 0.3) }
            }
            guard self.serviceRunning(yabai) else { emit(.failed("yabai's service didn't come up.")); return }

            guard needsOpacity else { emit(.ready); return }

            if !self.sipDisabled() { emit(.sipRequired); return }

            // Already pinned from a prior run: load the addition passwordlessly, no prompt.
            if self.run("/usr/bin/sudo", ["-n", yabai, "--load-sa"]).status == 0 {
                emit(.opacityReady); return
            }
            emit(.authorizing)
            if self.installScriptingAddition(yabai: yabai) {
                emit(.opacityReady)
            } else {
                emit(.failed("The scripting addition wasn't loaded (admin prompt declined?)."))
            }
        }
    }

    /// Stop the yabai service on quit, but only if Spectra is the one that started it.
    func stopServiceIfStarted() {
        queue.sync {
            guard weStartedService, let yabai = yabaiPath() else { return }
            _ = run(yabai, ["--stop-service"])
            weStartedService = false
        }
    }

    // MARK: - Privileged scripting-addition install (one admin prompt)

    /// Pin the binary hash for passwordless `--load-sa`, validate the sudoers file, and load
    /// the addition, all as root in one prompt. Returns false if the user cancels or it fails.
    private func installScriptingAddition(yabai: String) -> Bool {
        guard let hash = sha256(of: yabai) else { return false }
        let user = NSUserName()
        // One root shell line: write + lock + validate + re-hash guard + load. No inner double
        // quotes, so AppleScript escaping reduces to the printf newline.
        let shell = "HASH=$(/usr/bin/shasum -a 256 \(yabai)|/usr/bin/cut -d' ' -f1); "
            + "[ $HASH = \(hash) ] || exit 4; "
            + "/usr/bin/printf '\(user) ALL=(root) NOPASSWD: sha256:%s \(yabai) --load-sa\\n' $HASH > \(Self.sudoersPath) && "
            + "/bin/chmod 0440 \(Self.sudoersPath) && "
            + "/usr/sbin/visudo -cf \(Self.sudoersPath) && "
            + "[ $(/usr/bin/shasum -a 256 \(yabai)|/usr/bin/cut -d' ' -f1) = $HASH ] && "
            + "\(yabai) --load-sa || { /bin/rm -f \(Self.sudoersPath); exit 5; }"
        return runAsAdministrator(shell)
    }

    /// Run a shell command as root via one `do shell script ... with administrator privileges`
    /// prompt. Returns true on success (status 0), false on cancel or non-zero exit.
    private func runAsAdministrator(_ shellCommand: String) -> Bool {
        let escaped = shellCommand
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let apple = "do shell script \"\(escaped)\" with administrator privileges"
        return run("/usr/bin/osascript", ["-e", apple]).status == 0
    }

    // MARK: - Probes

    private func serviceRunning(_ yabai: String) -> Bool {
        run(yabai, ["-m", "query", "--displays"]).status == 0
    }

    private func sipDisabled() -> Bool {
        run("/usr/bin/csrutil", ["status"]).out.lowercased().contains("disabled")
    }

    private func sha256(of path: String) -> String? {
        let r = run("/usr/bin/shasum", ["-a", "256", path])
        guard r.status == 0 else { return nil }
        return r.out.split(separator: " ").first.map(String.init)
    }

    @discardableResult
    private func run(_ path: String, _ args: [String]) -> (status: Int32, out: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
