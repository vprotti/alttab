import AppKit

/// One switchable window.
///
/// The unit here is the *window*, never the app. Two Chrome profiles are two
/// entries, a second Finder window is its own entry, a Finder tab behind
/// another is its own entry, and an app with no windows does not appear at
/// all — which is the whole point of this app and the thing macOS's own
/// Command-Tab refuses to do.
struct WindowEntry {
    typealias Kind = WindowKind

    /// The window server's id. Unique while the window exists.
    let id: CGWindowID
    let pid: pid_t
    /// "Google Chrome" — the process's name, for the subtitle.
    let appName: String
    /// The window's own title. Empty when the title is not readable.
    let title: String
    /// Screen coordinates, top-left origin (CoreGraphics convention).
    let frame: CGRect
    let kind: Kind
    /// Resolved once. Looking this up per tile, per keystroke, meant asking
    /// the workspace for the same icon a dozen times a second.
    let icon: NSImage?

    init(id: CGWindowID, pid: pid_t, appName: String, title: String,
         frame: CGRect, kind: Kind = .onScreen, icon: NSImage? = nil) {
        self.id = id
        self.pid = pid
        self.appName = appName
        self.title = title
        self.frame = frame
        self.kind = kind
        self.icon = icon ?? NSRunningApplication(processIdentifier: pid)?.icon
    }

    var isMinimized: Bool { kind == .minimized }

    /// What the row reads: the window's title, falling back to the app name so
    /// a row is never blank.
    var displayTitle: String { title.isEmpty ? appName : title }

    var app: NSRunningApplication? {
        NSRunningApplication(processIdentifier: pid)
    }
}

enum WindowList {
    struct Listing {
        var entries: [WindowEntry]
        /// Whether the first entry is the window you are in, so a single
        /// ⌥Tab should go past it. False on an empty desktop, or while the
        /// app in front has no window of its own.
        var firstIsCurrent: Bool
    }

    /// A window that was looked at and left out, and why. Only the self-test
    /// prints these; they are what to send when a window goes missing.
    struct Rejection {
        let appName: String
        let title: String
        let frame: CGRect
        let reason: String
    }

    /// Anything smaller than this is a tooltip, a shadow or a status popover,
    /// not something a person means to switch to. Measured against the real
    /// noise: helper windows come through at 64×64, 18×18 and 14×14.
    private static let minimumSide: CGFloat = 80

    /// Off screen, with only the window server's word that it exists, a
    /// window has to be a real window's size. Full-screen toolbars and
    /// extension popups come through at 88 points tall.
    private static let unconfirmedMinimumSide: CGFloat = 120

    /// More than this and the grid would run off any screen; nobody cycles
    /// through sixty windows with a modifier held down anyway.
    private static let maxEntries = 60

    private struct Owner {
        let isRegular: Bool
        let isHidden: Bool
    }

    private struct Candidate {
        let id: CGWindowID
        let pid: pid_t
        let appName: String
        let title: String
        let frame: CGRect
        let onScreen: Bool
    }

    /// Where a window sits, rounded, per app: tabs of one window share it.
    private struct Slot: Hashable {
        let pid: pid_t
        let x: Int
        let y: Int
        let width: Int
        let height: Int

        init(pid: pid_t, frame: CGRect) {
            self.pid = pid
            x = Int(frame.minX.rounded())
            y = Int(frame.minY.rounded())
            width = Int(frame.width.rounded())
            height = Int(frame.height.rounded())
        }
    }

    /// Which processes may own a switchable window.
    ///
    /// An app with a Dock icon (`.regular`) is taken at its word. A menu bar
    /// utility (`.accessory`) can own real windows too — its settings, an
    /// editor — but mostly draws popovers and HUDs, so each of its windows has
    /// to be confirmed by the app. XPC services are left out: they draw the
    /// open and save panels of sandboxed apps, which belong to the app that
    /// asked, not to a row of their own.
    private static func eligibleOwners(excluding ownPID: pid_t) -> [pid_t: Owner] {
        var result: [pid_t: Owner] = [:]
        for app in NSWorkspace.shared.runningApplications where app.processIdentifier != ownPID {
            switch app.activationPolicy {
            case .regular:
                result[app.processIdentifier] = Owner(isRegular: true, isHidden: app.isHidden)
            case .accessory:
                if app.bundleURL?.pathExtension == "xpc" { continue }
                result[app.processIdentifier] = Owner(isRegular: false, isHidden: app.isHidden)
            default:
                continue
            }
        }
        return result
    }

    private static func candidates(_ options: CGWindowListOption, owners: [pid_t: Owner],
                                   onScreen: Bool, skipping skip: Set<CGWindowID>) -> [Candidate] {
        guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]
        else { return [] }

        var result: [Candidate] = []
        var seen = skip
        for info in raw {
            guard let id = info[kCGWindowNumber as String] as? CGWindowID,
                  !seen.contains(id),
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  owners[pid] != nil,
                  // Layer 0 is the normal window layer. The Dock (20), the
                  // menu bar (24), Control Center (25) and the cursor all
                  // live elsewhere and would otherwise come through.
                  (info[kCGWindowLayer as String] as? Int) == 0
            else { continue }

            // A fully transparent window is a placeholder, not a window.
            if let alpha = info[kCGWindowAlpha as String] as? Double, alpha <= 0.01 { continue }

            guard let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  frame.width >= minimumSide, frame.height >= minimumSide
            else { continue }

            // The key is documented as optional and really is absent rather
            // than false, so a plain `as? Bool == false` would be wrong.
            let drawn = (info[kCGWindowIsOnscreen as String] as? Bool) ?? false
            if !onScreen && drawn { continue }

            seen.insert(id)
            result.append(Candidate(
                id: id, pid: pid,
                appName: info[kCGWindowOwnerName as String] as? String ?? "",
                title: info[kCGWindowName as String] as? String ?? "",
                frame: frame, onScreen: onScreen))
        }
        return result
    }

    /// Every window worth switching to, most recently used first.
    static func current(includeMinimized: Bool = true, includeOtherSpaces: Bool = true,
                        frontPID: pid_t? = nil) -> Listing {
        scan(includeMinimized: includeMinimized, includeOtherSpaces: includeOtherSpaces,
             frontPID: frontPID).listing
    }

    /// Three sources, each covering what the others cannot see:
    ///
    ///  - the window server's window list, for every window that exists and
    ///    the stacking order of the ones on screen;
    ///  - Accessibility, for what each app says about its windows on this
    ///    desktop — its tabs, what is minimised, the titles the list withholds
    ///    without Screen Recording;
    ///  - the window server's desktops, for everything Accessibility cannot
    ///    see: other desktops, full-screen apps, minimised windows elsewhere.
    ///
    /// `WindowRules` weighs the three for each window.
    static func scan(includeMinimized: Bool, includeOtherSpaces: Bool,
                     frontPID: pid_t?) -> (listing: Listing, rejected: [Rejection]) {
        let owners = eligibleOwners(excluding: ProcessInfo.processInfo.processIdentifier)

        // On-screen first: this is the only option that returns windows in
        // front-to-back order, and that order is the switcher's whole premise.
        let onScreen = candidates([.optionOnScreenOnly, .excludeDesktopElements], owners: owners,
                                  onScreen: true, skipping: [])
        let onScreenIDs = Set(onScreen.map { $0.id })
        let offScreen = candidates([.optionAll, .excludeDesktopElements], owners: owners,
                                   onScreen: false, skipping: onScreenIDs)

        // The desktops are trusted only while they agree with what is plainly
        // on screen; a future macOS that changes their meaning gets ignored.
        var membership = SkyLight.membership()
        if let known = membership, !onScreen.isEmpty, known.visible.isDisjoint(with: onScreenIDs) {
            membership = nil
        }

        // One accessibility round per process that needs one: every app with
        // a window off screen, a title withheld, or a window to vouch for.
        var asked = Set(offScreen.map { $0.pid })
        for candidate in onScreen
        where candidate.title.isEmpty || owners[candidate.pid]?.isRegular == false {
            asked.insert(candidate.pid)
        }
        let snapshots = AXWindows.snapshots(for: Array(asked))
        let visibleSlots = Set(onScreen.map { Slot(pid: $0.pid, frame: $0.frame) })

        var icons: [pid_t: NSImage] = [:]
        func icon(for pid: pid_t) -> NSImage? {
            if let cached = icons[pid] { return cached }
            let image = NSRunningApplication(processIdentifier: pid)?.icon
            icons[pid] = image
            return image
        }

        var here: [WindowEntry] = []
        var elsewhere: [(entry: WindowEntry, order: Int)] = []
        var rejected: [Rejection] = []

        for (order, candidate) in (onScreen + offScreen).enumerated() {
            guard let owner = owners[candidate.pid] else { continue }
            let info = snapshots[candidate.pid]?.info(for: candidate.id, frame: candidate.frame,
                                                      title: candidate.title)
            let title = candidate.title.isEmpty ? (info?.title ?? "") : candidate.title

            let evidence = WindowRules.Evidence(
                onScreen: candidate.onScreen,
                ownerIsRegular: owner.isRegular,
                ownerIsHidden: owner.isHidden,
                titled: !title.isEmpty,
                sizable: min(candidate.frame.width, candidate.frame.height) >= unconfirmedMinimumSide,
                sharesFrameWithVisibleWindow: visibleSlots.contains(
                    Slot(pid: candidate.pid, frame: candidate.frame)),
                reported: info.map {
                    WindowRules.Reported(isMinimized: $0.isMinimized,
                                         isWindowLike: $0.isWindowLike, subrole: $0.subrole)
                },
                placement: membership.map { placement(of: candidate.id, in: $0) })

            switch WindowRules.judge(evidence, includeMinimized: includeMinimized,
                                     includeOtherSpaces: includeOtherSpaces) {
            case .include(let kind):
                let entry = WindowEntry(id: candidate.id, pid: candidate.pid,
                                        appName: candidate.appName, title: title,
                                        frame: candidate.frame, kind: kind,
                                        icon: icon(for: candidate.pid))
                if kind == .onScreen {
                    here.append(entry)
                } else {
                    elsewhere.append((entry: entry, order: order))
                }
            case .reject(let reason):
                rejected.append(Rejection(appName: candidate.appName, title: title,
                                          frame: candidate.frame, reason: reason))
            }
        }

        let byID = Dictionary((here + elsewhere.map { $0.entry }).map { ($0.id, $0) },
                              uniquingKeysWith: { first, _ in first })
        let lastUse = WindowHistory.shared.lastUse(of: Array(byID.keys))
        let ordered = WindowRules.arrange(
            here: here.map { $0.id },
            elsewhere: elsewhere.map { (id: $0.entry.id, kind: $0.entry.kind, order: $0.order) },
            lastUse: lastUse)
        let entries = Array(ordered.compactMap { byID[$0] }.prefix(maxEntries))

        let firstIsCurrent = entries.first.map {
            $0.kind == .onScreen && (frontPID == nil || $0.pid == frontPID)
        } ?? false
        return (Listing(entries: entries, firstIsCurrent: firstIsCurrent), rejected)
    }

    private static func placement(of id: CGWindowID,
                                  in membership: SkyLight.Membership) -> WindowRules.Placement {
        if membership.visibleHere.contains(id) { return .drawnHere }
        if membership.visible.contains(id) { return .drawnElsewhere }
        if membership.parked.contains(id) { return .parked }
        return .nowhere
    }

    /// The front-most window on screen, of one app or of any, without asking
    /// any app anything: cheap enough to run on every app switch.
    static func frontWindow(of pid: pid_t?) -> CGWindowID? {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        guard let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                   kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        for info in raw {
            guard let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let owner = info[kCGWindowOwnerPID as String] as? pid_t,
                  owner != ownPID, pid == nil || owner == pid,
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  frame.width >= minimumSide, frame.height >= minimumSide
            else { continue }
            if let alpha = info[kCGWindowAlpha as String] as? Double, alpha <= 0.01 { continue }
            return id
        }
        return nil
    }
}
