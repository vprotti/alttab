import AppKit

/// The menu bar presence: a small window-stack glyph and a three-item menu.
/// AltTab has nothing to show at a glance, so there is no popover — the icon
/// exists so the app is findable and quittable, and so a missing permission
/// has somewhere to complain.
final class StatusItemController: NSObject {
    private let item = NSStatusItem.build()
    private var needsPermission = false

    var onOpenSettings: (() -> Void)?
    var onOpenPermissions: (() -> Void)?

    override init() {
        super.init()
        item.button?.image = StatusIcons.normal
        item.button?.imagePosition = .imageOnly
        item.menu = buildMenu()

        NotificationCenter.default.addObserver(
            self, selector: #selector(rebuild), name: .languageDidChange, object: nil)
    }

    func setNeedsPermission(_ needed: Bool) {
        guard needsPermission != needed else { return }
        needsPermission = needed
        // One template image, always: the system paints it white on a dark
        // menu bar and black on a light one. A non-template image drew literal
        // black and vanished. To flag the missing permission the same glyph is
        // simply tinted orange, which reads on either background.
        item.button?.contentTintColor = needed ? .systemOrange : nil
        item.button?.toolTip = needed ? L10n.t("perm.accessibilityWhy") : nil
        rebuild()
    }

    @objc private func rebuild() {
        item.menu = buildMenu()
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        if needsPermission {
            let warning = NSMenuItem(title: L10n.t("menu.permissionNeeded"),
                                     action: #selector(openPermissions), keyEquivalent: "")
            warning.target = self
            menu.addItem(warning)
            menu.addItem(.separator())
        }
        let settings = NSMenuItem(title: L10n.t("menu.settings"),
                                  action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: L10n.t("menu.quit"),
                              action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    @objc private func openSettings() { onOpenSettings?() }
    @objc private func openPermissions() { onOpenPermissions?() }
    @objc private func quit() { NSApp.terminate(nil) }
}

private extension NSStatusItem {
    static func build() -> NSStatusItem {
        NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    }
}

/// Drawn in code so the mark stays crisp on any display and follows the menu
/// bar's light and dark appearance without shipping two image files.
enum StatusIcons {
    private static let size = NSSize(width: 18, height: 18)

    /// Two overlapping window outlines — the switch, in one glance.
    ///
    /// A template image, always. The system inverts it for the menu bar's
    /// appearance, which is the only way to stay visible on both; a
    /// non-template image drew literal black and disappeared on a dark bar.
    /// The missing-permission state is signalled by tinting this same image,
    /// not by a second one.
    static let normal: NSImage = {
        let image = NSImage(size: size, flipped: false) { rect in
            draw(in: rect)
            return true
        }
        image.isTemplate = true
        return image
    }()

    /// The same mark at welcome-screen size, in colour rather than as a
    /// template, so the first thing the user sees is not a black smudge.
    static let large: NSImage = NSImage(size: NSSize(width: 72, height: 72),
                                        flipped: false) { rect in
        draw(in: rect, tint: .controlAccentColor)
        return true
    }

    private static func draw(in rect: NSRect, tint: NSColor = .black) {
        let s = min(rect.width, rect.height) / 18.0
        tint.setStroke()
        tint.setFill()

        // Back window, offset up and right.
        let back = NSBezierPath(roundedRect: NSRect(x: rect.minX + 6 * s, y: rect.minY + 7 * s,
                                                    width: 9 * s, height: 7 * s),
                                xRadius: 1.5 * s, yRadius: 1.5 * s)
        back.lineWidth = 1.3 * s
        back.stroke()

        // Front window, filled so it reads as the one in focus.
        let front = NSBezierPath(roundedRect: NSRect(x: rect.minX + 3 * s, y: rect.minY + 4 * s,
                                                     width: 10 * s, height: 8 * s),
                                 xRadius: 1.8 * s, yRadius: 1.8 * s)
        front.fill()
    }
}
