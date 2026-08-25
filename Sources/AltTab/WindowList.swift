import AppKit

/// One switchable window.
///
/// The unit here is the *window*, never the app. Two Chrome profiles are two
/// entries, a second Finder window is its own entry, and an app with no windows
/// does not appear at all — which is the whole point of this app and the thing
/// macOS's own Command-Tab refuses to do.
struct WindowEntry {
    /// The window server's id. Unique while the window exists.
    let id: CGWindowID
    let pid: pid_t
    /// "Google Chrome" — the process's name, for the subtitle.
    let appName: String
    /// The window's own title. Empty when the title is not readable.
    let title: String
    /// Screen coordinates, top-left origin (CoreGraphics convention).
    let frame: CGRect
    let isMinimized: Bool
    /// Resolved once at construction. Looking this up per tile, per keystroke,
    /// meant asking the workspace for the same icon a dozen times a second.
    let icon: NSImage?

    init(id: CGWindowID, pid: pid_t, appName: String, title: String,
         frame: CGRect, isMinimized: Bool, icon: NSImage? = nil) {
        self.id = id
        self.pid = pid
        self.appName = appName
        self.title = title
        self.frame = frame
        self.isMinimized = isMinimized
        self.icon = icon ?? NSRunningApplication(processIdentifier: pid)?.icon
    }

    /// What the row reads: the window's title, falling back to the app name so
    /// a row is never blank.
    var displayTitle: String { title.isEmpty ? appName : title }

    var app: NSRunningApplication? {
        NSRunningApplication(processIdentifier: pid)
    }
}

enum WindowList {
    /// Anything smaller than this is a tooltip, a shadow or a status popover,
    /// not something a person means to switch to. Measured against the real
    /// noise: helper windows come through at 64×64, 18×18 and 14×14.
    private static let minimumSide: CGFloat = 80

    /// Which processes are allowed to own a switchable window.
    ///
    /// This is the filter that does the real work. The window server happily
    /// reports well over a hundred windows, and layer 0 alone still leaves
    /// dozens of them: autofill panels, theme widgets, cursor services, save
    /// dialogs owned by view services. What separates a window a person thinks
    /// of as a window is the owner being an actual app — one with a Dock icon
    /// and a menu bar, which is exactly `.regular`.
    private static func regularApps() -> Set<pid_t> {
        Set(NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .map { $0.processIdentifier })
    }

    /// Every user window on this Mac, front-most first.
    ///
    /// `.optionOnScreenOnly` returns them already ordered front-to-back, which
    /// is the order the switcher wants: the window you just left is second in
    /// the list, so one press of Tab goes back to it.
    static func current(includeMinimized: Bool = true) -> [WindowEntry] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let allowed = regularApps()

        var entries: [WindowEntry] = []
        var seen = Set<CGWindowID>()

        func collect(_ options: CGWindowListOption, offScreen: Bool) {
            guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]
            else { return }

            for info in raw {
                guard let id = info[kCGWindowNumber as String] as? CGWindowID,
                      !seen.contains(id),
                      let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                      pid != ownPID,
                      allowed.contains(pid),
                      // Layer 0 is the normal window layer. The Dock (20), the
                      // menu bar (24), Control Center (25) and the cursor all
                      // live elsewhere and would otherwise come through.
                      (info[kCGWindowLayer as String] as? Int) == 0
                else { continue }

                // A fully transparent window is a placeholder, not a window.
                if let alpha = info[kCGWindowAlpha as String] as? Double, alpha <= 0.01 { continue }

                guard let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                      let frame = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                      frame.width >= minimumSide, frame.height >= minimumSide
                else { continue }

                // The key is documented as optional and really is absent rather
                // than false, so a plain `as? Bool == false` would be wrong.
                let onScreen = (info[kCGWindowIsOnscreen as String] as? Bool) ?? false
                if offScreen && onScreen { continue }

                seen.insert(id)
                entries.append(WindowEntry(
                    id: id, pid: pid,
                    appName: info[kCGWindowOwnerName as String] as? String ?? "",
                    title: (info[kCGWindowName as String] as? String) ?? "",
                    frame: frame, isMinimized: offScreen))
            }
        }

        // On-screen first: this is the only option that returns windows in
        // front-to-back order, and that order is the switcher's whole premise.
        collect([.optionOnScreenOnly, .excludeDesktopElements], offScreen: false)
        guard includeMinimized else { return entries }

        // Then the off-screen ones. The window server's off-screen list is not
        // a list of minimised windows — it is everything not being drawn, which
        // for a browser is a pile of hidden helper windows. So each candidate
        // is confirmed with the app that owns it before it earns a row.
        let onScreenCount = entries.count
        collect([.optionAll, .excludeDesktopElements], offScreen: true)

        let offScreen = entries[onScreenCount...]
        var minimizedByPID: [pid_t: Set<CGWindowID>] = [:]
        for pid in Set(offScreen.map { $0.pid }) {
            minimizedByPID[pid] = AXWindows.minimizedIDs(pid: pid)
        }
        let confirmed = offScreen.filter { minimizedByPID[$0.pid]?.contains($0.id) == true }
        return Array(entries[..<onScreenCount]) + confirmed
    }

    /// Titles come back empty without Screen Recording permission, so the
    /// Accessibility API fills them in — it needs a different permission the app
    /// already asks for, and between the two every row gets a real name.
    static func fillMissingTitles(_ entries: [WindowEntry]) -> [WindowEntry] {
        let missing = entries.filter { $0.title.isEmpty }
        guard !missing.isEmpty else { return entries }

        // One AX application element per process, not per window.
        var titlesByPID: [pid_t: [CGWindowID: String]] = [:]
        for pid in Set(missing.map { $0.pid }) {
            titlesByPID[pid] = AXWindows.titles(pid: pid)
        }

        return entries.map { entry in
            guard entry.title.isEmpty,
                  let title = titlesByPID[entry.pid]?[entry.id], !title.isEmpty
            else { return entry }
            return WindowEntry(id: entry.id, pid: entry.pid, appName: entry.appName,
                               title: title, frame: entry.frame,
                               isMinimized: entry.isMinimized, icon: entry.icon)
        }
    }
}
