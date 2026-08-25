import AppKit

/// Drives one pass through the switcher: open, step, commit.
///
/// The window list is taken once, when the shortcut fires, and then held still.
/// Re-reading it while the user cycles would let the order shift under their
/// fingers, which is the single most infuriating thing a switcher can do.
@MainActor
final class Switcher {
    private let panel = SwitcherPanel()
    private var entries: [WindowEntry] = []
    private var selection = 0
    private var captureTask: Task<Void, Never>?
    private var watchdog: Timer?
    /// Which modifier has to stay down for this pass to remain open.
    private var heldModifier: NSEvent.ModifierFlags = .option

    /// Gathering the list touches other processes, so it never runs on the main
    /// thread. Serial: two overlapping passes would only fight each other.
    private let listing = DispatchQueue(label: "br.com.nasralla.alttab.windows",
                                        qos: .userInteractive)
    /// Rises with every open, so a slow listing for a pass the user already
    /// abandoned is dropped instead of appearing late.
    private var generation = 0

    init() {
        panel.onClick = { [weak self] index in
            guard let self else { return }
            self.selection = index
            self.commit()
        }
    }

    var isOpen: Bool { panel.isVisible }

    // MARK: - Opening

    func open(modifier: NSEvent.ModifierFlags) {
        heldModifier = modifier
        generation += 1
        let pass = generation
        let includeMinimized = Prefs.includeMinimized

        listing.async { [weak self] in
            // Accessibility calls live here, off the main thread, where they
            // cannot hold up the app or anything else on this Mac.
            let found = WindowList.fillMissingTitles(
                WindowList.current(includeMinimized: includeMinimized))

            Task { @MainActor [weak self] in
                guard let self, pass == self.generation, !found.isEmpty else { return }
                self.entries = found
                // Start on the window behind the current one — a single press
                // is "go back to what I was just doing", as on Windows.
                self.selection = found.count > 1 ? 1 : 0
                self.panel.show(entries: found, selected: self.selection,
                                on: self.screenForPanel())
                self.startWatchdog()
                self.startCaptures()
            }
        }
    }

    func step(_ delta: Int) {
        guard !entries.isEmpty else { return }
        selection = (selection + delta + entries.count) % entries.count
        panel.select(selection)
    }

    func commit() {
        let target = entries.indices.contains(selection) ? entries[selection] : nil
        close()
        guard let target else { return }
        // Focusing talks to another process; keep it off the frame that is
        // dismissing the panel so the panel disappears immediately either way.
        DispatchQueue.global(qos: .userInitiated).async { AXWindows.focus(target) }
    }

    func cancel() {
        close()
    }

    private func close() {
        generation += 1          // orphan any listing still in flight
        watchdog?.invalidate()
        watchdog = nil
        captureTask?.cancel()
        captureTask = nil
        panel.hide()
        let ids = Set(entries.map { $0.id })
        Task { await Thumbnails.shared.prune(keeping: ids) }
        entries = []
    }

    /// The panel floats above everything and accepts clicks, so one that got
    /// stuck would eat them across the screen. Nothing should be able to strand
    /// it: if the modifier is no longer physically held — a release that was
    /// missed because the tap was disabled, a Space change, a crash mid-cycle —
    /// this closes it on the next tick.
    private func startWatchdog() {
        watchdog?.invalidate()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isOpen else { return }
                if !NSEvent.modifierFlags.contains(self.heldModifier) {
                    self.commit()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }

    /// Where the mouse is, so the switcher appears on the display the user is
    /// actually looking at.
    private func screenForPanel() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
    }

    // MARK: - Previews

    /// Captures run after the panel is already on screen, one at a time, and
    /// fill themselves in as they arrive. Capturing all of them up front would
    /// delay the panel by exactly the amount of time that makes a switcher feel
    /// broken.
    private func startCaptures() {
        captureTask?.cancel()
        let wanted = entries
        captureTask = Task { [weak self] in
            for entry in wanted {
                if Task.isCancelled { return }
                guard let image = await Thumbnails.shared.image(for: entry) else { continue }
                if Task.isCancelled { return }
                await MainActor.run { self?.panel.apply(image: image, for: entry.id) }
            }
        }
    }
}
