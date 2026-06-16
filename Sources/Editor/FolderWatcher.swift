import Foundation

/// Watches a directory with a kernel file-system event source and coalesces
/// bursts of writes into a single debounced callback. Spectra uses this on the
/// library folder so shader files an author drops in are imported and hot-reloaded
/// without a relaunch.
final class FolderWatcher: @unchecked Sendable {
    private let url: URL
    private let onChange: @Sendable () -> Void
    private let queue = DispatchQueue(label: "com.spectra.folderwatch")
    private var source: DispatchSourceFileSystemObject?
    private var descriptor: Int32 = -1
    private var debounce: DispatchWorkItem?

    init(url: URL, onChange: @escaping @Sendable () -> Void) {
        self.url = url
        self.onChange = onChange
    }

    func start() {
        queue.async { [weak self] in self?.openSource() }
    }

    private func openSource() {
        guard source == nil else { return }
        descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .rename, .delete, .attrib],
            queue: queue)
        src.setEventHandler { [weak self] in self?.schedule() }
        src.setCancelHandler { [weak self] in
            guard let self else { return }
            if self.descriptor >= 0 { close(self.descriptor); self.descriptor = -1 }
        }
        source = src
        src.resume()
    }

    private func schedule() {
        debounce?.cancel()
        let work = DispatchWorkItem { [onChange] in onChange() }
        debounce = work
        queue.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    func stop() {
        queue.async { [weak self] in
            self?.source?.cancel()
            self?.source = nil
        }
    }

    deinit { source?.cancel() }
}
