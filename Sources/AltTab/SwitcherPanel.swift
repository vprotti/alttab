import AppKit

/// The overlay: a grid of window previews with one of them selected.
///
/// It must never take focus. If it did, the app you are switching *away* from
/// would deactivate, every window would reshuffle, and releasing Option would
/// land somewhere unpredictable. So it is a non-activating panel that cannot
/// become key, floating above everything including full-screen apps.
final class SwitcherPanel: NSPanel {
    private let content = SwitcherContentView()

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 640, height: 220),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)

        isFloatingPanel = true
        level = .popUpMenu                 // above normal windows and the Dock
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary,
                              .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        ignoresMouseEvents = false
        isMovable = false
        // Never appear in a screenshot of "all windows" or in Mission Control.
        sharingType = .none

        contentView = content
    }

    /// A panel that can become key would steal focus the moment it appeared.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    // MARK: - Showing

    func show(entries: [WindowEntry], selected: Int, on screen: NSScreen?) {
        let target = screen ?? NSScreen.main ?? NSScreen.screens.first
        guard let visible = target?.visibleFrame else { return }

        // The grid needs to know what it has to fit inside before it can decide
        // how many columns to use.
        content.update(entries: entries, selected: selected, maxWidth: visible.width)
        let size = content.fittingSize
        setContentSize(size)
        setFrameOrigin(NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2))
        orderFrontRegardless()
    }

    func select(_ index: Int) {
        content.select(index)
    }

    func hide() {
        orderOut(nil)
    }

    /// Fills in a preview as soon as it has been captured, without rebuilding
    /// the row — the user may already be several steps along by then.
    func apply(image: NSImage, for id: CGWindowID) {
        content.apply(image: image, for: id)
    }

    var onClick: ((Int) -> Void)? {
        get { content.onClick }
        set { content.onClick = newValue }
    }
}

/// The panel's contents: a blurred slab holding a grid of window tiles.
///
/// The tiles wrap onto as many rows as they need. A single row was fine with
/// four windows and unusable with fourteen — it ran off both edges of the
/// screen and squeezed every title down to nothing.
private final class SwitcherContentView: NSVisualEffectView {
    /// Never wider than this share of the screen, however many windows exist.
    private static let maxWidthFraction: CGFloat = 0.86
    /// Beyond this the tiles get too small to tell apart at a glance.
    private static let maxColumns = 6

    private let rows = NSStackView()
    private let caption = NSTextField(labelWithString: "")
    private var tiles: [SwitcherTileView] = []
    var onClick: ((Int) -> Void)?

    init() {
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 20
        layer?.masksToBounds = true

        rows.orientation = .vertical
        rows.alignment = .centerX
        rows.spacing = 14
        rows.translatesAutoresizingMaskIntoConstraints = false

        // The selected window's whole title, which no tile has room for.
        caption.font = .systemFont(ofSize: 13, weight: .medium)
        caption.alignment = .center
        caption.lineBreakMode = .byTruncatingMiddle
        caption.translatesAutoresizingMaskIntoConstraints = false
        caption.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        addSubview(rows)
        addSubview(caption)
        NSLayoutConstraint.activate([
            rows.topAnchor.constraint(equalTo: topAnchor, constant: 22),
            rows.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 22),
            rows.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -22),
            caption.topAnchor.constraint(equalTo: rows.bottomAnchor, constant: 14),
            caption.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -18),
            caption.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 22),
            caption.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -22),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(entries: [WindowEntry], selected: Int, maxWidth: CGFloat) {
        rows.arrangedSubviews.forEach { $0.removeFromSuperview() }
        tiles = []
        guard !entries.isEmpty else { return }

        let columns = Self.columns(for: entries.count,
                                   maxWidth: maxWidth * Self.maxWidthFraction)
        var index = 0
        while index < entries.count {
            let slice = entries[index ..< min(index + columns, entries.count)]
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 14
            row.alignment = .top

            for (offset, entry) in slice.enumerated() {
                let position = index + offset
                let tile = SwitcherTileView(entry: entry)
                tile.onClick = { [weak self] in self?.onClick?(position) }
                row.addArrangedSubview(tile)
                tiles.append(tile)
            }
            rows.addArrangedSubview(row)
            index += columns
        }
        select(selected)
    }

    /// The fewest rows the tiles fit in, then spread evenly across them.
    ///
    /// Fewest rows because screens are wide and eyes scan sideways: seven
    /// windows want four and three, not three rows of three. Spreading evenly
    /// afterwards avoids a full row followed by a lonely leftover.
    private static func columns(for count: Int, maxWidth: CGFloat) -> Int {
        let perTile = SwitcherTileView.tileWidth + 14
        let fits = max(1, Int((maxWidth - 44) / perTile))
        let perRow = min(maxColumns, fits)
        let rows = max(1, Int(ceil(Double(count) / Double(perRow))))
        return max(1, Int(ceil(Double(count) / Double(rows))))
    }

    func select(_ index: Int) {
        for (i, tile) in tiles.enumerated() { tile.isSelected = (i == index) }
        caption.stringValue = tiles.indices.contains(index) ? tiles[index].fullTitle : ""
    }

    func apply(image: NSImage, for id: CGWindowID) {
        tiles.first { $0.windowID == id }?.setPreview(image)
    }
}

/// One window: a preview at a fixed size, its app icon, and its title.
private final class SwitcherTileView: NSView {
    static let tileWidth: CGFloat = 176
    static let previewHeight: CGFloat = 108

    let windowID: CGWindowID
    let fullTitle: String
    var onClick: (() -> Void)?

    private let preview = PreviewView()
    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "")

    var isSelected = false {
        didSet { needsDisplay = true }
    }

    init(entry: WindowEntry) {
        windowID = entry.id
        fullTitle = entry.displayTitle
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        // Until a capture arrives the app icon stands in, drawn at a fixed size
        // rather than at whatever its natural resolution happens to be — that
        // is what made some tiles show a postage stamp and others a full frame.
        preview.setIcon(entry.icon)
        preview.alphaValue = entry.isMinimized ? 0.5 : 1
        preview.translatesAutoresizingMaskIntoConstraints = false

        iconView.image = entry.icon
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        iconView.setContentCompressionResistancePriority(.required, for: .horizontal)

        label.stringValue = entry.displayTitle
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.alignment = .left
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        addSubview(preview)
        addSubview(iconView)
        addSubview(label)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.tileWidth),

            preview.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            preview.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            preview.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            preview.heightAnchor.constraint(equalToConstant: Self.previewHeight),

            iconView.topAnchor.constraint(equalTo: preview.bottomAnchor, constant: 8),
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),
            iconView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),

            // Pinned to both edges so the title always has the row to itself
            // and can truncate instead of being squeezed out of existence.
            label.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: iconView.centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func setPreview(_ image: NSImage) {
        preview.setCapture(image)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isSelected else { return }
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1),
                                xRadius: 12, yRadius: 12)
        NSColor.controlAccentColor.withAlphaComponent(0.30).setFill()
        path.fill()
        NSColor.controlAccentColor.setStroke()
        path.lineWidth = 2
        path.stroke()
    }

    override func mouseUp(with event: NSEvent) {
        onClick?()
    }
}

/// Draws a window preview at one consistent size.
///
/// An NSImageView cannot do this: it scales to the image, so a 32-point app
/// icon and a 3000-pixel screenshot end up wildly different on screen. Here the
/// box is fixed and the picture is fitted into it — captures fill it, icons sit
/// centred at a deliberate size — so every tile reads the same.
private final class PreviewView: NSView {
    private var image: NSImage?
    private var isIcon = true

    /// How much of the box an icon takes when there is no capture yet.
    private static let iconSide: CGFloat = 56

    func setIcon(_ image: NSImage?) {
        self.image = image
        isIcon = true
        needsDisplay = true
    }

    func setCapture(_ image: NSImage) {
        self.image = image
        isIcon = false
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let box = NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8)
        NSColor.black.withAlphaComponent(0.22).setFill()
        box.fill()

        guard let image, image.size.width > 0, image.size.height > 0 else { return }

        let target: NSRect
        if isIcon {
            let side = min(Self.iconSide, min(bounds.width, bounds.height) - 8)
            target = NSRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2,
                            width: side, height: side)
        } else {
            // Fit the whole window inside the box: cropping a screenshot would
            // hide the very part that tells two windows apart.
            let scale = min(bounds.width / image.size.width,
                            bounds.height / image.size.height)
            let size = NSSize(width: image.size.width * scale,
                              height: image.size.height * scale)
            target = NSRect(x: bounds.midX - size.width / 2,
                            y: bounds.midY - size.height / 2,
                            width: size.width, height: size.height)
        }

        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1)
    }
}
