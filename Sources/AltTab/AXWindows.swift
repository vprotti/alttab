import AppKit
import ApplicationServices

/// The bridge between the two ways macOS talks about a window.
///
/// CoreGraphics knows every window on screen and gives each a `CGWindowID`, but
/// offers no way to focus one. The Accessibility API can focus a window but
/// addresses it as an opaque `AXUIElement` with no public id. Nothing in the
/// public API connects the two, which is the central problem every window
/// switcher on this platform has to solve.
///
/// Two ways across, in order:
///
///  1. `_AXUIElementGetWindow`, which returns the `CGWindowID` for an element.
///     It is private, so it is looked up at runtime and simply absent if Apple
///     ever removes it — never linked against, never assumed.
///  2. Matching on position and title. Public, and right almost always; it can
///     only be confused by two windows of the same app sharing a title *and* a
///     frame, in which case either one is a reasonable answer anyway.
///
/// Accessibility only ever sees the desktop in front of you. Windows on the
/// others are the window server's business, in `SkyLight`.
enum AXWindows {

    // MARK: - The private id lookup, obtained safely

    private typealias GetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

    /// Resolved once. `nil` means this macOS no longer exports it and every
    /// caller silently falls back to matching.
    private static let getWindowID: GetWindowFn? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow")
        else { return nil }
        return unsafeBitCast(symbol, to: GetWindowFn.self)
    }()

    private static func windowID(of element: AXUIElement) -> CGWindowID? {
        guard let getWindowID else { return nil }
        var id: CGWindowID = 0
        return getWindowID(element, &id) == .success ? id : nil
    }

    // MARK: - Reading

    private static func attribute<T>(_ element: AXUIElement, _ name: String, as: T.Type) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success
        else { return nil }
        return value as? T
    }

    /// Every accessibility query is a synchronous message to another process,
    /// and by default it waits forever. One busy or wedged app was enough to
    /// block whoever asked — and when the asker was the main thread, the event
    /// tap stopped answering and the Mac's input froze with it.
    ///
    /// A quarter of a second is generous for a healthy app and short enough
    /// that an unhealthy one costs a missing title, not a frozen machine.
    private static let messagingTimeout: Float = 0.25

    private static func appElement(pid: pid_t) -> AXUIElement {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        return app
    }

    private static func windows(pid: pid_t) -> [AXUIElement] {
        let windows = attribute(appElement(pid: pid), kAXWindowsAttribute,
                                as: [AXUIElement].self) ?? []
        // The timeout is set per element, and the window elements the app just
        // handed back are new ones.
        for window in windows { AXUIElementSetMessagingTimeout(window, messagingTimeout) }
        return windows
    }

    /// What one process says about one of its windows.
    struct Info {
        let title: String?
        let isMinimized: Bool
        let subrole: String?

        /// A document or dialog window, as opposed to a floating helper, a
        /// popup bubble or something the app never meant anyone to switch to.
        /// A hidden app's windows, and minimised ones, report as dialogs.
        var isWindowLike: Bool {
            subrole == kAXStandardWindowSubrole || subrole == kAXDialogSubrole
        }
    }

    /// Everything one process said about its windows on this desktop.
    struct Snapshot {
        var byID: [CGWindowID: Info] = [:]
        /// Windows the id bridge could not name, kept with their frames so
        /// they can still be matched.
        var unnamed: [(frame: CGRect, info: Info)] = []

        func info(for id: CGWindowID, frame: CGRect, title: String) -> Info? {
            if let hit = byID[id] { return hit }
            guard !unnamed.isEmpty else { return nil }
            let near = unnamed.filter { Self.same($0.frame, frame) }
            if !title.isEmpty, let named = near.first(where: { $0.info.title == title }) {
                return named.info
            }
            return near.count == 1 ? near[0].info : nil
        }

        private static func same(_ a: CGRect, _ b: CGRect) -> Bool {
            abs(a.minX - b.minX) < 2 && abs(a.minY - b.minY) < 2
                && abs(a.width - b.width) < 2 && abs(a.height - b.height) < 2
        }
    }

    /// One snapshot per process, all asked at once. Asked one after another,
    /// a single slow app held up every app behind it, and the grid with them.
    static func snapshots(for pids: [pid_t]) -> [pid_t: Snapshot] {
        guard !pids.isEmpty else { return [:] }
        let store = SnapshotStore()
        DispatchQueue.concurrentPerform(iterations: pids.count) { index in
            store.set(snapshot(pid: pids[index]), for: pids[index])
        }
        return store.values
    }

    private final class SnapshotStore: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [pid_t: Snapshot] = [:]

        func set(_ snapshot: Snapshot, for pid: pid_t) {
            lock.lock()
            stored[pid] = snapshot
            lock.unlock()
        }

        var values: [pid_t: Snapshot] {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
    }

    /// Title, minimised state and kind of every window, in one round trip per
    /// window rather than one per attribute.
    static func snapshot(pid: pid_t) -> Snapshot {
        var result = Snapshot()
        let attributes = [kAXTitleAttribute, kAXMinimizedAttribute, kAXSubroleAttribute] as CFArray
        for window in windows(pid: pid) {
            var values: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(window, attributes, [], &values) == .success,
                  let array = values as? [Any], array.count == 3
            else { continue }
            // A value the app could not supply comes back as an AXValue error
            // placeholder, which fails every cast below exactly as intended.
            let info = Info(title: array[0] as? String,
                            isMinimized: (array[1] as? Bool) ?? false,
                            subrole: array[2] as? String)
            if let id = windowID(of: window) {
                result.byID[id] = info
            } else if let bounds = frame(of: window) {
                result.unnamed.append((frame: bounds, info: info))
            }
        }
        return result
    }

    /// The accessibility element for a given window, by id when the system
    /// still tells us, otherwise by where the window is and what it is called.
    private static func element(for entry: WindowEntry) -> AXUIElement? {
        let candidates = windows(pid: entry.pid)
        guard !candidates.isEmpty else { return nil }

        // The id cannot be confused. A window its app does not list under that
        // id is on another desktop, out of Accessibility's sight, and matching
        // on title or position would raise a different window of the same app.
        if getWindowID != nil {
            return candidates.first { windowID(of: $0) == entry.id }
        }

        // Fallback: same title and same origin wins; then title alone; then, if
        // the app has exactly one window, it can only be that one.
        let titled = candidates.filter {
            attribute($0, kAXTitleAttribute, as: String.self) == entry.title
        }
        if titled.count == 1 { return titled[0] }
        if let match = titled.first(where: { origin(of: $0) == entry.frame.origin }) { return match }
        if let match = candidates.first(where: { origin(of: $0) == entry.frame.origin }) { return match }
        return candidates.count == 1 ? candidates[0] : titled.first
    }

    private static func origin(of window: AXUIElement) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &value) == .success,
              let axValue = value, CFGetTypeID(axValue) == AXValueGetTypeID()
        else { return nil }
        var point = CGPoint.zero
        AXValueGetValue(axValue as! AXValue, .cgPoint, &point)
        return point
    }

    private static func size(of window: AXUIElement) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &value) == .success,
              let axValue = value, CFGetTypeID(axValue) == AXValueGetTypeID()
        else { return nil }
        var extent = CGSize.zero
        AXValueGetValue(axValue as! AXValue, .cgSize, &extent)
        return extent
    }

    private static func frame(of window: AXUIElement) -> CGRect? {
        guard let point = origin(of: window), let extent = size(of: window) else { return nil }
        return CGRect(origin: point, size: extent)
    }

    // MARK: - Acting

    /// Brings one window forward and gives it the keyboard.
    ///
    /// The window has to exist on screen first: its app is unhidden, and the
    /// window taken out of the Dock. Then the window server is asked to put
    /// this exact window in front, which is the one call that also reaches a
    /// window on another desktop or behind another tab. Accessibility raises
    /// it within its app on top of that. When the window server calls are
    /// missing, the app is activated the ordinary way.
    static func focus(_ entry: WindowEntry) {
        let app = entry.app
        if app?.isHidden == true { app?.unhide() }

        let window = element(for: entry)
        if let window { restore(window) }

        let fronted = SkyLight.focus(pid: entry.pid, windowID: entry.id)
        if let window { raise(window) }
        AXUIElementSetAttributeValue(appElement(pid: entry.pid),
                                     kAXFrontmostAttribute as CFString, true as CFTypeRef)

        if !fronted {
            let options: NSApplication.ActivationOptions = window == nil
                ? [.activateAllWindows, .activateIgnoringOtherApps]
                : [.activateIgnoringOtherApps]
            DispatchQueue.main.async { app?.activate(options: options) }
        }

        // A window on another desktop only becomes visible to Accessibility
        // once macOS has switched there. Raise it then, unless the user has
        // already moved on to something else.
        guard window == nil else { return }
        DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + 0.4) {
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == entry.pid,
                  let late = Self.element(for: entry)
            else { return }
            Self.restore(late)
            Self.raise(late)
        }
    }

    private static func restore(_ window: AXUIElement) {
        guard attribute(window, kAXMinimizedAttribute, as: Bool.self) == true else { return }
        AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, false as CFTypeRef)
    }

    private static func raise(_ window: AXUIElement) {
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, true as CFTypeRef)
        AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, true as CFTypeRef)
    }
}
