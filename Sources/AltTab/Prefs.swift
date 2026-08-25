import Foundation

/// Single source of truth for every UserDefaults key the app uses.
enum Prefs {
    private static let d = UserDefaults.standard

    private enum Key {
        static let appLanguage = "appLanguage"
        static let launchAtLogin = "launchAtLogin"
        static let autoUpdate = "autoUpdate"
        static let updateAttempts = "updateAttempts"
        static let shortcut = "shortcut"
        static let includeMinimized = "includeMinimized"
        static let onboardingDone = "onboardingDone"
    }

    static func registerDefaults() {
        d.register(defaults: [
            Key.launchAtLogin: true,
            Key.autoUpdate: true,
            Key.includeMinimized: true,
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
        d.set([version: all[version]!], forKey: Key.updateAttempts)
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

    /// Whether the permission walkthrough has been completed once.
    static var onboardingDone: Bool {
        get { d.bool(forKey: Key.onboardingDone) }
        set { d.set(newValue, forKey: Key.onboardingDone) }
    }
}
