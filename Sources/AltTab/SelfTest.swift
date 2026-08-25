import AppKit

/// Offscreen renderers and probes used to produce the images in docs/ and to
/// check the window list without launching the app. Not reachable from the UI.
enum SelfTest {

    /// `--selftest-windows`: what the switcher would list, right now.
    /// The fastest way to tell whether the permissions are actually in place.
    static func printWindows() {
        print("Accessibility: \(Permissions.hasAccessibility ? "granted" : "MISSING")")
        print("Screen Recording: \(Permissions.hasScreenRecording ? "granted" : "missing (no previews, no titles)")")

        let entries = WindowList.fillMissingTitles(WindowList.current())
        print("\n\(entries.count) windows:\n")
        for (index, entry) in entries.enumerated() {
            let size = "\(Int(entry.frame.width))×\(Int(entry.frame.height))"
            let flag = entry.isMinimized ? " [minimized]" : ""
            print(String(format: "%2d. %-22s %@%@",
                         index + 1, (entry.appName as NSString).utf8String!,
                         "\(entry.displayTitle)  (\(size))", flag))
        }

        // The point of the app, stated as a check: apps owning more than one
        // window have to appear more than once.
        let byApp = Dictionary(grouping: entries, by: { $0.appName })
        let multi = byApp.filter { $0.value.count > 1 }
        if multi.isEmpty {
            print("\nno app currently has two windows open")
        } else {
            print("\napps listed more than once, one row per window:")
            for (app, windows) in multi.sorted(by: { $0.value.count > $1.value.count }) {
                print("  \(app): \(windows.count)")
            }
        }
    }

    /// `--selftest-tap`: proves the event tap survives a blocked main thread.
    ///
    /// This is the regression test for the freeze. With the tap on the main run
    /// loop, blocking the main thread stalled every keystroke and click on the
    /// Mac until it finished, and the system eventually disabled the tap. On a
    /// thread of its own it should still be enabled afterwards.
    ///
    /// Runs for about three seconds and exits on its own.
    static func runTapCheck() {
        guard Permissions.hasAccessibility else {
            print("Accessibility: MISSING — cannot create an event tap without it")
            exit(1)
        }
        let hotkey = Hotkey(shortcut: Prefs.shortcut)
        guard hotkey.start() else {
            print("FAIL: event tap could not be created")
            exit(1)
        }
        print("ok   event tap created")

        // Block the main thread hard, the way a wedged accessibility call did.
        print("...  blocking the main thread for 2.5 s")
        Thread.sleep(forTimeInterval: 2.5)

        let alive = hotkey.isRunning
        print(alive ? "ok   tap thread still alive after the block"
                    : "FAIL tap thread died during the block")
        hotkey.stop()
        print(alive ? "\ntap: all checks passed" : "\ntap: FAILED")
        exit(alive ? 0 : 1)
    }

    /// `--selftest-switcher <path>`: draws the panel with stand-in windows, so
    /// the documentation image never contains anybody's real screen.
    @MainActor
    static func renderSwitcher(to path: String) {
        let panel = SwitcherPanel()
        // Icons come from apps every Mac has, so the documentation image never
        // shows what happens to be running on the machine that built it.
        // Looked up by bundle id, not by path: the system apps move between
        // releases and their folder names are localized.
        func icon(_ bundleID: String) -> NSImage? {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            else { return nil }
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        let samples: [(String, String, String)] = [
            ("Safari", "Painel de controle — perfil Trabalho", "com.apple.Safari"),
            ("Safari", "nasmac.app — perfil Pessoal", "com.apple.Safari"),
            ("Terminal", "swift build -c release", "com.apple.Terminal"),
            ("Finder", "Downloads", "com.apple.finder"),
            ("Mail", "Caixa de entrada (3)", "com.apple.mail"),
            ("Notas", "Lista de compras", "com.apple.Notes"),
            ("Calendário", "Agosto de 2026", "com.apple.iCal"),
        ]
        let entries = samples.enumerated().map { index, sample in
            WindowEntry(id: CGWindowID(1000 + index), pid: 0, appName: sample.0,
                        title: sample.1,
                        frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                        isMinimized: false, icon: icon(sample.2))
        }
        panel.show(entries: entries, selected: 1, on: NSScreen.main)

        guard let content = panel.contentView,
              let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds)
        else { return }
        content.cacheDisplay(in: content.bounds, to: rep)
        panel.hide()
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
        print("wrote \(path)")
    }
}
