import AppKit

/// First-run walkthrough for the two system permissions.
///
/// It stays open and updates itself while the user is off in System Settings,
/// so the moment a switch is flipped the row turns green here and it is obvious
/// the app noticed.
final class PermissionsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let onFinish: () -> Void

    private var accessibilityRow: PermissionRow!
    private var screenRow: PermissionRow!
    private var doneButton: NSButton!
    private var staleNote: NSTextField!

    init(onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
        super.init()
    }

    func show() {
        if window == nil { build() }
        refresh()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    func refresh() {
        let trusted = Permissions.hasAccessibility
        accessibilityRow?.setGranted(trusted)
        screenRow?.setGranted(Permissions.hasScreenRecording)
        doneButton?.isEnabled = trusted
        // Only worth saying once the user has plainly already tried.
        staleNote?.isHidden = trusted || !Prefs.onboardingDone
    }

    private func build() {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 300),
                           styleMask: [.titled, .closable],
                           backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.title = "AltTab"

        let title = NSTextField(labelWithString: L10n.t("perm.title"))
        title.font = .systemFont(ofSize: 17, weight: .semibold)

        accessibilityRow = PermissionRow(
            name: L10n.t("perm.accessibility"),
            why: L10n.t("perm.accessibilityWhy"),
            action: {
                // The system prompt only ever appears once per app; after that
                // the Settings pane is the only way in.
                Permissions.requestAccessibility()
                Permissions.openAccessibilitySettings()
            })

        screenRow = PermissionRow(
            name: L10n.t("perm.screen"),
            why: L10n.t("perm.screenWhy"),
            action: {
                Permissions.requestScreenRecording()
                Permissions.openScreenRecordingSettings()
            })

        let note = NSTextField(wrappingLabelWithString: L10n.t("perm.restartNote"))
        note.font = .systemFont(ofSize: 11)
        note.textColor = .tertiaryLabelColor

        staleNote = NSTextField(wrappingLabelWithString: L10n.t("perm.stale"))
        staleNote.font = .systemFont(ofSize: 11)
        staleNote.textColor = .systemOrange
        staleNote.preferredMaxLayoutWidth = 412
        staleNote.isHidden = true

        // Relaunching guarantees a fresh read: a process is told once whether
        // it is trusted, and does not always hear about a later change.
        let relaunch = NSButton(title: L10n.t("perm.relaunch"), target: self,
                                action: #selector(relaunchApp))
        relaunch.bezelStyle = .rounded

        doneButton = NSButton(title: L10n.t("perm.done"), target: self,
                              action: #selector(finish))
        doneButton.bezelStyle = .rounded
        doneButton.keyEquivalent = "\r"

        let buttonRow = NSStackView(views: [relaunch, NSView(), doneButton])
        buttonRow.orientation = .horizontal

        let stack = NSStackView(views: [title, accessibilityRow, screenRow,
                                        note, staleNote, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 20, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.widthAnchor.constraint(equalToConstant: 460),
        ])
        win.contentView = content
        win.setContentSize(content.fittingSize)
        window = win
    }

    /// Relaunches from the same bundle, so the new process asks the system
    /// fresh whether it is trusted.
    @objc private func relaunchApp() {
        let url = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    @objc private func finish() {
        window?.close()
        windowWillClose(Notification(name: NSWindow.willCloseNotification))
    }

    func windowWillClose(_ notification: Notification) {
        // Back to a menu bar app with no Dock icon.
        NSApp.setActivationPolicy(.accessory)
        onFinish()
    }
}

/// One permission: name, why it is wanted, and a button that becomes a tick.
private final class PermissionRow: NSView {
    private let status = NSImageView()
    private let button = NSButton()
    private let action: () -> Void

    init(name: String, why: String, action: @escaping () -> Void) {
        self.action = action
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: name)
        title.font = .systemFont(ofSize: 13, weight: .semibold)

        let detail = NSTextField(wrappingLabelWithString: why)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.preferredMaxLayoutWidth = 300

        status.imageScaling = .scaleProportionallyDown
        status.translatesAutoresizingMaskIntoConstraints = false

        button.title = L10n.t("perm.grant")
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.target = self
        button.action = #selector(tapped)

        let text = NSStackView(views: [title, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3

        let row = NSStackView(views: [status, text, button])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false

        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            status.widthAnchor.constraint(equalToConstant: 18),
            status.heightAnchor.constraint(equalToConstant: 18),
            widthAnchor.constraint(equalToConstant: 412),
        ])
        setGranted(false)
    }

    required init?(coder: NSCoder) { fatalError() }

    func setGranted(_ granted: Bool) {
        let name = granted ? "checkmark.circle.fill" : "circle.dashed"
        status.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        status.contentTintColor = granted ? .systemGreen : .tertiaryLabelColor
        button.title = granted ? L10n.t("perm.granted") : L10n.t("perm.grant")
        button.isEnabled = !granted
    }

    @objc private func tapped() { action() }
}
