import Foundation

/// Single source of truth for every UserDefaults key the app uses.
enum Prefs {
    private static let d = UserDefaults.standard

    private enum Key {
        static let appLanguage = "appLanguage"
        static let launchAtLogin = "launchAtLogin"
        static let loginItemRegistered = "loginItemRegistered"
        static let autoUpdate = "autoUpdate"
        static let updateAttempts = "updateAttempts"
        static let shortcut = "shortcut"
        static let includeMinimized = "includeMinimized"
        static let includeOtherSpaces = "includeOtherSpaces"
        static let onboardingDone = "onboardingDone"
    }

    static func registerDefaults() {
        d.register(defaults: [
            Key.launchAtLogin: true,
            Key.autoUpdate: true,
            Key.includeMinimized: true,
            Key.includeOtherSpaces: true,
        ])
    }

    /// "en" | "pt-BR"; nil means first launch hasn't completed yet.
    static var appLanguage: String? {
        get { d.string(forKey: Key.appLanguage) }
        set { d.set(newValue, forKey: Key.appLanguage) }
    }

    static var launchAtLogin: Bool {
        get { d.bool(forKey: Key.launchAtLogin) }
        set { d.set(newValue, forKey: Key.launchAtLogin) }
    }

    /// True once the login item has been registered successfully at least
    /// once. After that the system's own switch is the truth: a person who
    /// turns it off in System Settings must not find it back on at next launch.
    static var loginItemRegistered: Bool {
        get { d.bool(forKey: Key.loginItemRegistered) }
        set { d.set(newValue, forKey: Key.loginItemRegistered) }
    }

    /// Keep the app current automatically. On by default — a menu bar utility
    /// nobody thinks about should not quietly rot.
    static var autoUpdate: Bool {
        get { d.bool(forKey: Key.autoUpdate) }
        set { d.set(newValue, forKey: Key.autoUpdate) }
    }

    static func updateAttempts(for version: String) -> Int {
        (d.dictionary(forKey: Key.updateAttempts)?[version] as? Int) ?? 0
    }

    static func noteUpdateAttempt(_ version: String) {
        var all = d.dictionary(forKey: Key.updateAttempts) as? [String: Int] ?? [:]
        all[version] = (all[version] ?? 0) + 1
        d.set(all, forKey: Key.updateAttempts)
    }

    /// The key combination that opens the switcher. Option-Tab out of the box.
    static var shortcut: Shortcut {
        get {
            guard let data = d.data(forKey: Key.shortcut),
                  let value = try? JSONDecoder().decode(Shortcut.self, from: data)
            else { return .default }
            return value
        }
        set { d.set(try? JSONEncoder().encode(newValue), forKey: Key.shortcut) }
    }

    /// Minimised windows are still windows you may want back.
    static var includeMinimized: Bool {
        get { d.bool(forKey: Key.includeMinimized) }
        set { d.set(newValue, forKey: Key.includeMinimized) }
    }

    /// Windows on other desktops, and those of apps hidden with ⌘H. They are
    /// not on screen, but they are the ones hardest to get back to otherwise.
    static var includeOtherSpaces: Bool {
        get { d.bool(forKey: Key.includeOtherSpaces) }
        set { d.set(newValue, forKey: Key.includeOtherSpaces) }
    }

    /// Whether the permission walkthrough has been completed once.
    static var onboardingDone: Bool {
        get { d.bool(forKey: Key.onboardingDone) }
        set { d.set(newValue, forKey: Key.onboardingDone) }
    }
}
