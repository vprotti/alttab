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
        var isStandard: Bool {
            subrole == kAXStandardWindowSubrole || subrole == kAXDialogSubrole
        }
    }

    /// Everything the switcher wants to know about a process's windows, keyed
    /// by window id, in one round trip per window rather than one per
    /// attribute. The window server's off-screen list is not a list of
    /// minimised windows — it is everything not currently drawn, which for a
    /// browser means a pile of 1224×88 extension popups and hidden helpers —
    /// so the app itself is asked which of its windows are real.
    static func snapshot(pid: pid_t) -> [CGWindowID: Info] {
        var result: [CGWindowID: Info] = [:]
        let attributes = [kAXTitleAttribute, kAXMinimizedAttribute, kAXSubroleAttribute] as CFArray
        for window in windows(pid: pid) {
            guard let id = windowID(of: window) else { continue }
            var values: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(window, attributes, [], &values) == .success,
                  let array = values as? [Any], array.count == 3
            else { continue }
            // A value the app could not supply comes back as an AXValue error
            // placeholder, which fails every cast below exactly as intended.
            result[id] = Info(title: array[0] as? String,
                              isMinimized: (array[1] as? Bool) ?? false,
                              subrole: array[2] as? String)
        }
        return result
    }

    /// The accessibility element for a given window, by id when the system
    /// still tells us, otherwise by where the window is and what it is called.
    private static func element(for entry: WindowEntry) -> AXUIElement? {
        let candidates = windows(pid: entry.pid)
        guard !candidates.isEmpty else { return nil }

        if getWindowID != nil {
            if let match = candidates.first(where: { windowID(of: $0) == entry.id }) {
                return match
            }
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

    // MARK: - Acting

    /// Brings one window forward and gives it the keyboard.
    ///
    /// The order matters and all the steps are needed: un-minimise so the
    /// window exists on screen at all, raise it above its app's other windows,
    /// then bring the app forward so the keyboard follows. Activating first
    /// would bring up whichever window that app had in front, not this one.
    ///
    /// The app is brought forward two ways. Setting `AXFrontmost` works from
    /// a background process on every macOS this app runs on; the AppKit
    /// activation is also asked, because it is the one that unhides an app
    /// hidden with ⌘H and switches Spaces reliably.
    @discardableResult
    static func focus(_ entry: WindowEntry) -> Bool {
        guard let window = element(for: entry) else {
            // No accessibility element — the best that is left is the app.
            DispatchQueue.main.async {
                entry.app?.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            }
            return false
        }

        if attribute(window, kAXMinimizedAttribute, as: Bool.self) == true {
            AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, false as CFTypeRef)
        }
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, true as CFTypeRef)
        AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, true as CFTypeRef)
        AXUIElementSetAttributeValue(appElement(pid: entry.pid),
                                     kAXFrontmostAttribute as CFString, true as CFTypeRef)

        DispatchQueue.main.async {
            entry.app?.activate(options: [.activateIgnoringOtherApps])
        }
        return true
    }
}
