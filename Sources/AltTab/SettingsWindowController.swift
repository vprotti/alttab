import AppKit
import Carbon.HIToolbox

/// Minimal programmatic settings window. Every change applies immediately
/// (macOS convention — no OK/Cancel).
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let onShortcutChanged: () -> Void
    private let onRecordingChanged: (Bool) -> Void

    private var appNameLabel: NSTextField!
    private var versionLabel: NSTextField!
    private var taglineLabel: NSTextField!
    private var shortcutButton: ShortcutRecorder!
    private var minimizedSwitch: NSSwitch!
    private var minimizedLabel: NSTextField!
    private var otherSpacesSwitch: NSSwitch!
    private var otherSpacesLabel: NSTextField!
    private var otherSpacesHint: NSTextField!
    private var loginSwitch: NSSwitch!
    private var loginLabel: NSTextField!
    private var loginHint: NSTextField!
    private var loginHintRow: NSGridRow?
    private var updateSwitch: NSSwitch!
    private var updateLabel: NSTextField!
    private var updateHint: NSTextField!
    private var shortcutLabel: NSTextField!
    private var shortcutHint: NSTextField!
    private var languageLabel: NSTextField!
    private var languagePopup: NSPopUpButton!
    private var permissionsLabel: NSTextField!
    private var permissionsButton: NSButton!
    private var privacyTitle: NSTextField!
    private var privacyBody: NSTextField!

    init(onShortcutChanged: @escaping () -> Void,
         onRecordingChanged: @escaping (Bool) -> Void) {
        self.onShortcutChanged = onShortcutChanged
        self.onRecordingChanged = onRecordingChanged
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(relabel), name: .languageDidChange, object: nil)
    }

    func show() {
        if window == nil { build() }
        syncFromState()
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    private func build() {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 320),
                           styleMask: [.titled, .closable],
                           backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.delegate = self

        // The mark, the name and the version, so the window says what it is
        // before the first control.
        let mark = NSImageView()
        mark.image = StatusIcons.large
        mark.imageScaling = .scaleProportionallyUpOrDown
        mark.translatesAutoresizingMaskIntoConstraints = false

        appNameLabel = NSTextField(labelWithString: "AltTab")
        appNameLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        versionLabel = Self.label()
        versionLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        versionLabel.textColor = .secondaryLabelColor
        taglineLabel = Self.label()
        taglineLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        taglineLabel.textColor = .secondaryLabelColor

        let headerText = NSStackView(views: [appNameLabel, versionLabel, taglineLabel])
        headerText.orientation = .vertical
        headerText.alignment = .leading
        headerText.spacing = 2
        headerText.setCustomSpacing(6, after: versionLabel)

        let header = NSStackView(views: [mark, headerText])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 14

        shortcutLabel = Self.label()
        shortcutButton = ShortcutRecorder()
        shortcutButton.onCapture = { [weak self] shortcut in
            Prefs.shortcut = shortcut
            self?.onShortcutChanged()
        }
        shortcutButton.onRecordingChanged = { [weak self] recording in
            self?.onRecordingChanged(recording)
        }

        shortcutHint = Self.hint()
        minimizedLabel = Self.label()
        minimizedSwitch = NSSwitch()
        minimizedSwitch.target = self
        minimizedSwitch.action = #selector(minimizedChanged)

        otherSpacesLabel = Self.label()
        otherSpacesSwitch = NSSwitch()
        otherSpacesSwitch.target = self
        otherSpacesSwitch.action = #selector(otherSpacesChanged)
        otherSpacesHint = Self.hint()

        loginLabel = Self.label()
        loginSwitch = NSSwitch()
        loginSwitch.target = self
        loginSwitch.action = #selector(loginChanged)
        loginHint = Self.hint()

        updateLabel = Self.label()
        updateSwitch = NSSwitch()
        updateSwitch.target = self
        updateSwitch.action = #selector(autoUpdateChanged)
        updateHint = Self.hint()

        languageLabel = Self.label()
        languagePopup = NSPopUpButton()
        languagePopup.addItems(withTitles: ["Português (Brasil)", "English"])
        languagePopup.target = self
        languagePopup.action = #selector(languageChanged)

        permissionsLabel = Self.label()
        permissionsButton = NSButton(title: "", target: self, action: #selector(openPermissions))
        permissionsButton.bezelStyle = .rounded
        permissionsButton.controlSize = .small

        privacyTitle = Self.label()
        privacyTitle.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        privacyBody = Self.hint()

        let grid = NSGridView(views: [
            [shortcutLabel, shortcutButton],
            [shortcutHint, NSGridCell.emptyContentView],
            [minimizedLabel, minimizedSwitch],
            [otherSpacesLabel, otherSpacesSwitch],
            [otherSpacesHint, NSGridCell.emptyContentView],
            [loginLabel, loginSwitch],
            [loginHint, NSGridCell.emptyContentView],
            [updateLabel, updateSwitch],
            [updateHint, NSGridCell.emptyContentView],
            [languageLabel, languagePopup],
            [permissionsLabel, permissionsButton],
            [privacyTitle, NSGridCell.emptyContentView],
            [privacyBody, NSGridCell.emptyContentView],
        ])
        grid.rowSpacing = 12
        grid.columnSpacing = 16
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .leading
        grid.rowAlignment = .firstBaseline

        for wide in [shortcutHint!, otherSpacesHint!, loginHint!, updateHint!, privacyTitle!, privacyBody!] {
            grid.cell(for: wide)?.row?.mergeCells(in: NSRange(location: 0, length: 2))
            grid.cell(for: wide)?.xPlacement = .leading
        }
        // Hiding the view alone would not collapse the grid row — hide the row.
        loginHintRow = grid.cell(for: loginHint)?.row
        loginHintRow?.isHidden = true

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        let column = NSStackView(views: [header, separator, grid])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 18
        column.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 24, right: 24)
        column.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(column)
        NSLayoutConstraint.activate([
            mark.widthAnchor.constraint(equalToConstant: 48),
            mark.heightAnchor.constraint(equalToConstant: 48),
            separator.widthAnchor.constraint(equalTo: grid.widthAnchor),
            column.topAnchor.constraint(equalTo: content.topAnchor),
            column.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            column.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        ])
        win.contentView = content
        window = win
        relabel()
    }

    private static func label() -> NSTextField { NSTextField(labelWithString: "") }

    private static func hint() -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: "")
        field.textColor = .secondaryLabelColor
        field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        field.preferredMaxLayoutWidth = 340
        return field
    }

    @objc private func relabel() {
        versionLabel.stringValue = "\(L10n.t("settings.version")) \(Updater.currentVersion)"
        taglineLabel.stringValue = L10n.t("welcome.hint")
        shortcutLabel.stringValue = L10n.t("settings.shortcut")
        shortcutHint.stringValue = L10n.t("settings.shortcutHint")
        minimizedLabel.stringValue = L10n.t("settings.includeMinimized")
        otherSpacesLabel.stringValue = L10n.t("settings.includeOtherSpaces")
        otherSpacesHint.stringValue = L10n.t("settings.otherSpacesHint")
        loginLabel.stringValue = L10n.t("settings.launchAtLogin")
        loginHint.stringValue = L10n.t("settings.loginHint")
        updateLabel.stringValue = L10n.t("settings.autoUpdate")
        updateHint.stringValue = L10n.t("settings.autoUpdateHint")
        languageLabel.stringValue = L10n.t("settings.language")
        permissionsLabel.stringValue = L10n.t("settings.permissions")
        permissionsButton.title = L10n.t("perm.open")
        privacyTitle.stringValue = L10n.t("settings.privacy")
        privacyBody.stringValue = L10n.t("settings.privacyBody")
        shortcutButton.refreshTitle()
        window?.title = L10n.t("settings.title")
        resizeToFit()
    }

    /// The strings change length with the language and the login hint comes
    /// and goes; the window follows, keeping its top edge where it is.
    private func resizeToFit() {
        guard let window, let content = window.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let size = content.fittingSize
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        frame.origin.x = window.frame.origin.x
        frame.origin.y = window.frame.maxY - frame.height
        window.setFrame(frame, display: true)
    }

    private func syncFromState() {
        loginHintRow?.isHidden = true
        shortcutButton.shortcut = Prefs.shortcut
        minimizedSwitch.state = Prefs.includeMinimized ? .on : .off
        otherSpacesSwitch.state = Prefs.includeOtherSpaces ? .on : .off
        loginSwitch.state = LoginItem.isEnabled ? .on : .off
        updateSwitch.state = Prefs.autoUpdate ? .on : .off
        languagePopup.selectItem(at: L10n.current == .ptBR ? 0 : 1)
        resizeToFit()
    }

    @objc private func minimizedChanged() {
        Prefs.includeMinimized = minimizedSwitch.state == .on
    }

    @objc private func otherSpacesChanged() {
        Prefs.includeOtherSpaces = otherSpacesSwitch.state == .on
    }

    @objc private func loginChanged() {
        let wanted = loginSwitch.state == .on
        let ok = LoginItem.set(enabled: wanted)
        if !ok && wanted { loginSwitch.state = .off }
        loginHintRow?.isHidden = !(!ok && wanted)
        resizeToFit()
    }

    @objc private func autoUpdateChanged() {
        Prefs.autoUpdate = updateSwitch.state == .on
        if Prefs.autoUpdate { Task { await Updater.checkAndInstall() } }
    }

    @objc private func languageChanged() {
        L10n.current = languagePopup.indexOfSelectedItem == 0 ? .ptBR : .en
    }

    @objc private func openPermissions() {
        Permissions.openAccessibilitySettings()
    }

    // MARK: - NSWindowDelegate

    /// A recording left half-way when the window loses the keyboard would
    /// keep the switcher's shortcut suspended with nothing on screen to say so.
    func windowDidResignKey(_ notification: Notification) {
        shortcutButton?.stopRecording()
    }

    func windowWillClose(_ notification: Notification) {
        shortcutButton?.stopRecording()
    }
}

/// Click, then press the combination you want. Records the modifier that has to
/// stay held plus the key that cycles.
final class ShortcutRecorder: NSButton {
    var onCapture: ((Shortcut) -> Void)?
    /// True while waiting for a key; the global shortcut is paused meanwhile.
    var onRecordingChanged: ((Bool) -> Void)?
    var shortcut: Shortcut = .default {
        didSet { refreshTitle() }
    }
    private var recording = false {
        didSet {
            refreshTitle()
            if recording != oldValue { onRecordingChanged?(recording) }
        }
    }

    init() {
        super.init(frame: .zero)
        bezelStyle = .rounded
        target = self
        action = #selector(startRecording)
        refreshTitle()
    }

    required init?(coder: NSCoder) { fatalError() }

    func refreshTitle() {
        title = recording ? L10n.t("settings.recording") : shortcut.display
    }

    func stopRecording() {
        recording = false
    }

    @objc private func startRecording() {
        recording = true
        window?.makeFirstResponder(self)
    }

    override var acceptsFirstResponder: Bool { true }

    override func resignFirstResponder() -> Bool {
        recording = false
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard recording else { super.keyDown(with: event); return }

        if event.keyCode == UInt16(kVK_Escape) {
            recording = false
            return
        }

        // The modifier is what makes hold-and-cycle possible, so one is
        // required; a bare key would fire with nothing to release.
        let flags = event.modifierFlags
        let modifier: Shortcut.Modifier?
        if flags.contains(.option) { modifier = .option }
        else if flags.contains(.control) { modifier = .control }
        else if flags.contains(.command) { modifier = .command }
        else { modifier = nil }

        guard let modifier else { NSSound.beep(); return }

        recording = false
        shortcut = Shortcut(keyCode: event.keyCode, modifier: modifier)
        onCapture?(shortcut)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // While recording, swallow combinations AppKit would otherwise treat as
        // menu shortcuts (⌘Q and friends) so they can be assigned.
        guard recording else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event)
        return true
    }
}
