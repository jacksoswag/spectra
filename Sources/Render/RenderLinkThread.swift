import Foundation
import QuartzCore

/// A dedicated thread whose only job is to run a `CFRunLoop` that hosts a
/// `CAMetalDisplayLink`, so the link's callbacks fire OFF the main run loop.
///
/// On the main run loop the callback was delayed whenever SwiftUI (the Studio window) was
/// doing a layout pass — the callback landed one display tick late, so the already-delivered
/// captured frame sat an extra ~16ms in the mailbox before pickup (the measured "+16ms when
/// the Studio is open"). Here nothing else competes for the loop, so the tick is punctual.
///
/// Two gotchas baked in:
/// 1. The loop runs in `.default` mode, NOT `.common`. `.common` is a pseudo-mode that
///    services no sources directly — running it returns instantly and the overlay goes black
///    (this exact mistake was hit before). The display link is *added* to `.common` (which
///    includes `.default`), so it is serviced while the loop runs `.default`.
/// 2. A dummy Mach port is added so the loop has a source from the start — a run loop with
///    nothing to service returns immediately, which would spin the thread hot.
///
/// The link object itself is still created/paused/invalidated from the main thread (those are
/// thread-safe and keep the proven Space-carry lifecycle unchanged); only the per-frame
/// callback executes here. `perform`/`performSync` marshal occasional work (teardown cleanup)
/// onto this thread so it serializes with the in-flight callback.
final class RenderLinkThread {
    private var thread: Thread?
    /// The run loop to add the display link to. Valid only after `start()` returns.
    private(set) var runLoop: RunLoop?
    private let ready = DispatchSemaphore(value: 0)

    /// Start the thread and block until its run loop is live, so a caller can immediately add
    /// the display link to `runLoop`. Idempotent.
    func start(name: String) {
        guard thread == nil else { return }
        let t = Thread { [weak self] in
            let loop = RunLoop.current
            // Keep the loop alive: with no input sources, `run` returns immediately.
            loop.add(NSMachPort(), forMode: .default)
            self?.runLoop = loop
            self?.ready.signal()
            while !Thread.current.isCancelled {
                // Bounded wait, NOT .distantFuture. The CAMetalDisplayLink stops delivering
                // callbacks when its layer's window is re-ordered/elevated on a Space carry;
                // once it goes quiet the only remaining source is the keep-alive port (which
                // never fires), so an unbounded run would block here FOREVER and never service
                // the replacement link that `rebuildDisplayLink` adds from the main thread — the
                // overlay stays frozen on a stale frame even though the watchdog rebuilt the
                // clock (confirmed via /tmp diag: pres stuck while rebuildLink fired repeatedly).
                // A short ceiling lets the loop re-enter and pick up a freshly-added link; the
                // active path is unaffected (the link fires far more often than this). `wake()`
                // makes pickup instant when a link is added.
                loop.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1))
            }
        }
        t.name = name
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
        ready.wait()   // happens-before barrier: `runLoop` is visible once this returns
    }

    /// Wake the loop so a link just added (from another thread) is serviced on the next cycle
    /// instead of waiting out the bounded run above. Called right after `add(to:forMode:)`.
    func wake() {
        if let cf = runLoop?.getCFRunLoop() { CFRunLoopWakeUp(cf) }
    }

    /// Schedule a block to run on the link thread (after any in-flight callback). No-op if not
    /// started.
    func perform(_ block: @escaping () -> Void) {
        guard let cf = runLoop?.getCFRunLoop() else { return }
        CFRunLoopPerformBlock(cf, CFRunLoopMode.defaultMode.rawValue, block)
        CFRunLoopWakeUp(cf)
    }

    /// Run a block on the link thread and block the caller until it completes. Used by
    /// teardown so pool/history cleanup serializes with the last callback before the thread
    /// stops.
    func performSync(_ block: @escaping () -> Void) {
        guard runLoop != nil else { return }
        let done = DispatchSemaphore(value: 0)
        perform { block(); done.signal() }
        done.wait()
    }

    func stop() {
        thread?.cancel()
        if let cf = runLoop?.getCFRunLoop() { CFRunLoopWakeUp(cf) }
        thread = nil
        runLoop = nil
    }
}
