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
        if Prefs.launchAtLogin && !LoginItem.isEnabled {
            LoginItem.set(enabled: true)
        }

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

        // Without Accessibility the tap cannot be created at all, so walk the
        // user through it before anything else. The app is useless until then.
        if Permissions.hasAccessibility {
            startTap()
        } else if !Prefs.onboardingDone {
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
            guard let self else { return }
            let trusted = Permissions.hasAccessibility
            if trusted {
                self.startTap()
            } else {
                self.hotkey?.stop()
                self.statusController?.setNeedsPermission(true)
            }
            self.permissionsController?.refresh()
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
            settingsController = SettingsWindowController(onShortcutChanged: { [weak self] in
                self?.reloadShortcut()
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
