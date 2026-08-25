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

    init() {
        panel.onClick = { [weak self] index in
            guard let self else { return }
            self.selection = index
            self.commit()
        }
    }

    var isOpen: Bool { panel.isVisible }

    // MARK: - Opening

    func open() {
        entries = WindowList.fillMissingTitles(WindowList.current(
            includeMinimized: Prefs.includeMinimized))
        guard !entries.isEmpty else { return }

        // Start on the window behind the current one — a single Option-Tab is
        // "go back to what I was just doing", exactly as on Windows.
        selection = entries.count > 1 ? 1 : 0
        panel.show(entries: entries, selected: selection, on: screenForPanel())
        startCaptures()
    }

    func step(_ delta: Int) {
        guard !entries.isEmpty else { return }
        selection = (selection + delta + entries.count) % entries.count
        panel.select(selection)
    }

    func commit() {
        defer { close() }
        guard entries.indices.contains(selection) else { return }
        AXWindows.focus(entries[selection])
    }

    func cancel() {
        close()
    }

    private func close() {
        captureTask?.cancel()
        captureTask = nil
        panel.hide()
        let ids = Set(entries.map { $0.id })
        Task { await Thumbnails.shared.prune(keeping: ids) }
        entries = []
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
