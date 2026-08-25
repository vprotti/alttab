import AppKit

/// The two permissions this app cannot work without, and the one it can.
///
/// Accessibility is required: without it the event tap never sees Option-Tab
/// and no window can be raised. Screen Recording is optional — it buys the
/// window previews and the window titles; without it the switcher still lists
/// and switches windows, showing app icons instead of pictures.
enum Permissions {

    /// Checks without prompting. Safe to call on every refresh.
    static var hasAccessibility: Bool {
        AXIsProcessTrusted()
    }

    /// Raises the system's own dialog, once. macOS only shows it if the app has
    /// never been answered for; afterwards the call is silent and the user has
    /// to go to System Settings.
    static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    /// Preflight never prompts; request does. Both are the documented way in.
    static var hasScreenRecording: Bool {
        CGPreflightScreenCaptureAccess()
    }

    @discardableResult
    static func requestScreenRecording() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    // MARK: - Sending the user to the right place

    static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    static func openScreenRecordingSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    private static func open(_ url: String) {
        guard let url = URL(string: url) else { return }
        NSWorkspace.shared.open(url)
    }
}
