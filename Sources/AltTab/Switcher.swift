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

    /// A pass is `listing` from the keystroke until the window list arrives,
    /// and `open` from then until the modifier goes up. Keys pressed during
    /// the listing are not lost: they are held and applied when it lands.
    private enum Phase { case idle, listing, open }
    private var phase: Phase = .idle
    private var pendingSteps = 0
    private var pendingCommit = false

    /// Gathering the list touches other processes, so it never runs on the main
    /// thread. Serial: two overlapping passes would only fight each other.
    private let listing = DispatchQueue(label: "br.com.nasralla.alttab.windows",
                                        qos: .userInteractive)
    /// Rises with every open, so a slow listing for a pass the user already
    /// abandoned is dropped instead of appearing late.
    private var generation = 0

    init() {
        panel.onClick = { [weak self] index in
            guard let self, self.phase == .open else { return }
            self.selection = index
            self.commit()
        }
    }

    var isOpen: Bool { phase != .idle }

    // MARK: - Opening

    func open(modifier: NSEvent.ModifierFlags) {
        if phase != .idle { close() }
        heldModifier = modifier
        phase = .listing
        pendingSteps = 0
        pendingCommit = false
        generation += 1
        let pass = generation
        let includeMinimized = Prefs.includeMinimized
        let includeOtherSpaces = Prefs.includeOtherSpaces
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier

        listing.async { [weak self] in
            // Accessibility calls live here, off the main thread, where they
            // cannot hold up the app or anything else on this Mac.
            let found = WindowList.current(includeMinimized: includeMinimized,
                                           includeOtherSpaces: includeOtherSpaces,
                                           frontPID: frontPID)
            Task { @MainActor [weak self] in
                self?.didList(found, pass: pass)
            }
        }
    }

    private func didList(_ found: WindowList.Listing, pass: Int) {
        guard pass == generation, phase == .listing else { return }
        guard !found.entries.isEmpty else { phase = .idle; return }

        entries = found.entries
        // The window you are in is, by definition, the one used last.
        if found.firstIsCurrent { WindowHistory.shared.touch(entries[0].id) }
        // Start on the window behind the current one — a single press is "go
        // back to what I was just doing", as on Windows — plus whatever the
        // user already pressed while the list was being gathered. With no
        // current window (an empty desktop) the first one is already "back".
        let start = found.firstIsCurrent && entries.count > 1 ? 1 : 0
        selection = Self.wrap(start + pendingSteps, count: entries.count)
        pendingSteps = 0

        if pendingCommit {
            // The modifier was already released: the whole gesture was one
            // quick tap, which means "the previous window". Switch to it
            // without ever showing the grid.
            pendingCommit = false
            let target = entries[selection]
            entries = []
            phase = .idle
            focus(target)
            return
        }

        phase = .open
        panel.show(entries: entries, selected: selection, on: screenForPanel())
        startWatchdog()
        startCaptures()
    }

    func step(_ delta: Int) {
        switch phase {
        case .listing:
            pendingSteps += delta
        case .open:
            guard !entries.isEmpty else { return }
            selection = Self.wrap(selection + delta, count: entries.count)
            panel.select(selection)
        case .idle:
            break
        }
    }

    func commit() {
        switch phase {
        case .listing:
            pendingCommit = true
        case .open:
            let target = entries.indices.contains(selection) ? entries[selection] : nil
            close()
            if let target { focus(target) }
        case .idle:
            break
        }
    }

    func cancel() {
        close()
    }

    /// Focusing talks to another process; keep it off the frame that is
    /// dismissing the panel so the panel disappears immediately either way.
    private func focus(_ target: WindowEntry) {
        WindowHistory.shared.touch(target.id)
        DispatchQueue.global(qos: .userInteractive).async { AXWindows.focus(target) }
    }

    private static func wrap(_ value: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return ((value % count) + count) % count
    }

    private func close() {
        generation += 1          // orphan any listing still in flight
        phase = .idle
        pendingSteps = 0
        pendingCommit = false
        watchdog?.invalidate()
        watchdog = nil
        captureTask?.cancel()
        captureTask = nil
        panel.hide()
        let ids = Set(entries.map { $0.id })
        entries = []
        Task { await Thumbnails.shared.prune(keeping: ids) }
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
                guard let self, self.phase == .open else { return }
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

    /// Captures run after the panel is already on screen and fill themselves
    /// in as they arrive. Capturing all of them up front would delay the panel
    /// by exactly the amount of time that makes a switcher feel broken.
    private func startCaptures() {
        captureTask?.cancel()
        let wanted = entries
        captureTask = Task { [weak self] in
            // Whatever is still in the cache goes up at once, so reopening
            // the switcher never flashes icons where pictures just were.
            let warm = await Thumbnails.shared.cachedImages(for: wanted.map { $0.id })
            if Task.isCancelled { return }
            await MainActor.run {
                for (id, image) in warm { self?.panel.apply(image: image, for: id) }
            }

            await Thumbnails.shared.prepare()

            // A few at a time, front-most first: one at a time left the far
            // tiles empty for a second, all at once starved the capture service.
            let batchSize = 3
            var start = 0
            while start < wanted.count {
                if Task.isCancelled { return }
                let batch = Array(wanted[start ..< min(start + batchSize, wanted.count)])
                await withTaskGroup(of: Void.self) { group in
                    for entry in batch {
                        group.addTask {
                            guard let image = await Thumbnails.shared.image(for: entry) else { return }
                            if Task.isCancelled { return }
                            await MainActor.run { self?.panel.apply(image: image, for: entry.id) }
                        }
                    }
                }
                start += batchSize
            }
        }
    }
}
