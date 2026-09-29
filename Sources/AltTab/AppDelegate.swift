import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var switcher: Switcher?
    private var hotkey: Hotkey?
    private var statusController: StatusItemController?
    private var settingsController: SettingsWindowController?
    private var welcomeController: WelcomeWindowController?
    private var permissionsController: PermissionsWindowController?
    /// Accessibility can be granted or revoked while the app runs, and the
    /// event tap has to follow.
    private var permissionTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Prefs.registerDefaults()

        if Prefs.appLanguage == nil {
            welcomeController = WelcomeWindowController { [weak self] in
                LoginItem.set(enabled: true)
                self?.welcomeController = nil
                self?.start()
            }
            welcomeController?.show()
        } else {
            start()
        }
    }

    private func start() {
        // The first registration can fail — running from the DMG, before the
        // app is in Applications — so it is retried until it has worked once.
        // Never after: from then on the switch in System Settings is the
        // user's, and re-registering would undo them turning it off.
        if Prefs.launchAtLogin && !Prefs.loginItemRegistered && !LoginItem.isEnabled {
            LoginItem.set(enabled: true)
        }

        // Started before the first ⌥Tab, so the order of use across desktops
        // is already known by the time anyone asks for it.
        WindowHistory.shared.start()

        let switcher = Switcher()
        let hotkey = Hotkey(shortcut: Prefs.shortcut)
        // The switcher needs to know which modifier is holding it open, so it
        // can close itself if the release is ever missed.
        hotkey.onOpen = { [weak switcher] in
            switcher?.open(modifier: Prefs.shortcut.modifier.appKitFlag)
        }
        hotkey.onStep = { [weak switcher] delta in switcher?.step(delta) }
        hotkey.onCommit = { [weak switcher] in switcher?.commit() }
        hotkey.onCancel = { [weak switcher] in switcher?.cancel() }

        let status = StatusItemController()
        status.onOpenSettings = { [weak self] in self?.showSettings() }
        status.onOpenPermissions = { [weak self] in self?.showPermissions() }

        self.switcher = switcher
        self.hotkey = hotkey
        self.statusController = status

        // A second launch — a double click while it is already running, or a
        // login item that fired twice — should surface the copy that is here
        // rather than look like nothing happened.
        SingleInstance.onSecondLaunch { [weak self] in
            NSApp.activate(ignoringOtherApps: true)
            self?.showSettings()
        }

        // Without Accessibility the tap cannot be created at all, so walk the
        // user through it before anything else. The app is useless until then
        // — also after an update, when macOS quietly forgets a permission it
        // tied to the previous binary, and the window is what explains that.
        if Permissions.hasAccessibility {
            startTap()
        } else {
            showPermissions()
        }
        watchPermissions()

        Updater.shouldPostpone = { [weak switcher] in switcher?.isOpen ?? false }
        Updater.start()
    }

    private func startTap() {
        guard let hotkey, !hotkey.isRunning else { return }
        if hotkey.start() {
            statusController?.setNeedsPermission(false)
        } else {
            statusController?.setNeedsPermission(true)
        }
    }

    /// Polls rather than observes: macOS posts no notification when a TCC
    /// switch is flipped, and the user flips it in another app entirely.
    private func watchPermissions() {
        permissionTimer?.invalidate()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            // The timer already fires on the main run loop, but the closure is
            // nonisolated as far as the compiler is concerned — hop explicitly
            // rather than leave everything it touches unchecked.
            Task { @MainActor [weak self] in
                guard let self else { return }
                if Permissions.hasAccessibility {
                    self.startTap()
                } else {
                    self.hotkey?.stop()
                    self.statusController?.setNeedsPermission(true)
                }
                self.permissionsController?.refresh()
            }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        permissionTimer = timer
    }

    func reloadShortcut() {
        hotkey?.update(shortcut: Prefs.shortcut)
    }

    private func showSettings() {
        if settingsController == nil {
            settingsController = SettingsWindowController(
                onShortcutChanged: { [weak self] in self?.reloadShortcut() },
                // While a new shortcut is being recorded the tap stands aside;
                // otherwise pressing the current one there would open the
                // switcher on top of the Settings window instead of recording.
                onRecordingChanged: { [weak self] recording in
                    self?.hotkey?.isSuspended = recording
                })
        }
        settingsController?.show()
    }

    private func showPermissions() {
        if permissionsController == nil {
            permissionsController = PermissionsWindowController { [weak self] in
                Prefs.onboardingDone = true
                self?.permissionsController = nil
                self?.startTap()
            }
        }
        permissionsController?.show()
    }
}
