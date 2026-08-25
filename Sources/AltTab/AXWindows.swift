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

    private static func windows(pid: pid_t) -> [AXUIElement] {
        let app = AXUIElementCreateApplication(pid)
        return attribute(app, kAXWindowsAttribute, as: [AXUIElement].self) ?? []
    }

    /// The windows this process considers genuinely minimised.
    ///
    /// Needed because the window server's off-screen list is not a list of
    /// minimised windows — it is everything not currently drawn, which for a
    /// browser means a pile of 1224×88 extension popups and hidden helpers.
    /// The app itself knows which of its windows a person actually minimised,
    /// so that is who gets asked.
    static func minimizedIDs(pid: pid_t) -> Set<CGWindowID> {
        var result: Set<CGWindowID> = []
        for window in windows(pid: pid) {
            guard attribute(window, kAXMinimizedAttribute, as: Bool.self) == true,
                  let id = windowID(of: window)
            else { continue }
            result.insert(id)
        }
        return result
    }

    /// Every window title this process will admit to, keyed by window id.
    /// Used to fill in titles CoreGraphics withheld.
    static func titles(pid: pid_t) -> [CGWindowID: String] {
        var result: [CGWindowID: String] = [:]
        for window in windows(pid: pid) {
            guard let id = windowID(of: window),
                  let title = attribute(window, kAXTitleAttribute, as: String.self)
            else { continue }
            result[id] = title
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
    /// The order matters and all three steps are needed: un-minimise so the
    /// window exists on screen at all, raise it above its app's other windows,
    /// then activate the app so the keyboard follows. Activating first would
    /// bring up whichever window that app had in front, not this one.
    @discardableResult
    static func focus(_ entry: WindowEntry) -> Bool {
        guard let window = element(for: entry) else {
            // No accessibility element — the best that is left is the app.
            entry.app?.activate(options: [.activateAllWindows])
            return false
        }

        if attribute(window, kAXMinimizedAttribute, as: Bool.self) == true {
            AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, false as CFTypeRef)
        }
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, true as CFTypeRef)
        AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, true as CFTypeRef)

        entry.app?.activate(options: [])
        return true
    }
}
