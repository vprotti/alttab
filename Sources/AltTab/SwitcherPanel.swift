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
        animationBehavior = .none
        // Never appear in a screenshot of "all windows" or in Mission Control.
        sharingType = .none
        // The slab is always dark, so what is written on it must be drawn for
        // dark too. Left to follow the system, light mode painted dark-grey
        // titles onto a dark HUD and they vanished.
        appearance = NSAppearance(named: .darkAqua)

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
        // how many columns to use and how big a tile can be.
        content.update(entries: entries, selected: selected,
                       maxWidth: visible.width, maxHeight: visible.height)
        var size = content.fittingSize
        size.width = min(size.width, visible.width)
        size.height = min(size.height, visible.height)
        setContentSize(size)
        setFrameOrigin(NSPoint(
            x: (visible.midX - size.width / 2).rounded(),
            y: (visible.midY - size.height / 2).rounded()))
        // The shadow is cached per size; without this a smaller grid kept the
        // ghost of the previous, larger one around its edges.
        invalidateShadow()

        guard !isVisible else { return }
        // Just long enough to read as arriving rather than blinking on.
        // Hiding is instant: the window the user picked must not wait.
        alphaValue = 0
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.09
            self.animator().alphaValue = 1
        }
    }

    func select(_ index: Int) {
        content.select(index)
    }

    func hide() {
        orderOut(nil)
        alphaValue = 1
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
/// screen and squeezed every title down to nothing. Past what fits at full
/// size, the tiles shrink a step at a time so the grid stays on the screen.
private final class SwitcherContentView: NSVisualEffectView {
    /// Never wider or taller than this share of the screen, however many
    /// windows exist.
    private static let maxFraction: CGFloat = 0.86
    private static let inset: CGFloat = 22
    private static let gap: CGFloat = 14
    private static let cornerRadius: CGFloat = 22
    /// The caption row below the grid: its spacing above, its height, the
    /// bottom inset. Part of what has to fit vertically.
    private static let captionBlock: CGFloat = 14 + 18 + 18

    /// Each step down in size buys wider rows: at full size six tiles across
    /// is the most the eye takes in; at two thirds it can read nine. The last
    /// steps exist for the day every desktop and every tab adds up to forty
    /// windows on a laptop screen.
    private static let sizes: [(scale: CGFloat, maxColumns: Int)] = [
        (1.0, 6), (0.88, 7), (0.76, 8), (0.64, 9), (0.52, 10), (0.44, 12),
    ]

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
        layer?.cornerRadius = Self.cornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        // A hairline lip so the slab reads as an object on a dark wallpaper,
        // where an unedged blur just smears into the background.
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.10).cgColor
        maskImage = Self.roundedMask(radius: Self.cornerRadius)

        rows.orientation = .vertical
        rows.alignment = .centerX
        rows.spacing = Self.gap
        rows.translatesAutoresizingMaskIntoConstraints = false

        // The selected window's whole title, which no tile has room for.
        caption.alignment = .center
        caption.lineBreakMode = .byTruncatingMiddle
        caption.maximumNumberOfLines = 1
        caption.translatesAutoresizingMaskIntoConstraints = false
        caption.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        caption.setContentHuggingPriority(.defaultLow, for: .horizontal)

        addSubview(rows)
        addSubview(caption)
        NSLayoutConstraint.activate([
            rows.topAnchor.constraint(equalTo: topAnchor, constant: Self.inset),
            rows.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.inset),
            rows.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.inset),
            caption.topAnchor.constraint(equalTo: rows.bottomAnchor, constant: 14),
            caption.heightAnchor.constraint(equalToConstant: 18),
            caption.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -18),
            caption.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.inset),
            caption.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.inset),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The documented way to round a visual effect view: a stretchable mask.
    /// The layer's corner radius alone clips the subviews but, on some
    /// releases, not the blur itself.
    private static func roundedMask(radius: CGFloat) -> NSImage {
        let side = radius * 2 + 1
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    func update(entries: [WindowEntry], selected: Int, maxWidth: CGFloat, maxHeight: CGFloat) {
        rows.arrangedSubviews.forEach { $0.removeFromSuperview() }
        tiles = []
        guard !entries.isEmpty else { return }

        let layout = Self.arrangement(for: entries.count, maxWidth: maxWidth, maxHeight: maxHeight)
        var index = 0
        while index < entries.count {
            let end = min(index + layout.columns, entries.count)
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = Self.gap
            row.alignment = .top

            for position in index ..< end {
                let tile = SwitcherTileView(entry: entries[position], scale: layout.scale)
                tile.onClick = { [weak self] in self?.onClick?(position) }
                row.addArrangedSubview(tile)
                tiles.append(tile)
            }
            rows.addArrangedSubview(row)
            index = end
        }
        select(selected)
    }

    /// The largest tiles that fit, in the fewest rows, spread evenly.
    ///
    /// Fewest rows because screens are wide and eyes scan sideways: seven
    /// windows want four and three, not three rows of three. Spreading evenly
    /// afterwards avoids a full row followed by a lonely leftover. When even
    /// that overflows the screen the tiles step down a size and try again.
    private static func arrangement(for count: Int, maxWidth: CGFloat,
                                    maxHeight: CGFloat) -> (scale: CGFloat, columns: Int) {
        let width = maxWidth * maxFraction - inset * 2
        let height = maxHeight * maxFraction - inset - captionBlock
        var chosen: (scale: CGFloat, columns: Int) = (sizes[0].scale, 1)

        for size in sizes {
            let tileWidth = SwitcherTileView.width(scale: size.scale)
            let tileHeight = SwitcherTileView.height(scale: size.scale)
            let fits = max(1, Int((width + gap) / (tileWidth + gap)))
            let perRow = min(size.maxColumns, fits)
            let rowCount = max(1, Int(ceil(Double(count) / Double(perRow))))
            let columns = max(1, Int(ceil(Double(count) / Double(rowCount))))
            chosen = (size.scale, columns)
            let total = CGFloat(rowCount) * tileHeight + CGFloat(rowCount - 1) * gap
            if total <= height { break }
        }
        return chosen
    }

    func select(_ index: Int) {
        for (i, tile) in tiles.enumerated() { tile.isSelected = (i == index) }
        guard tiles.indices.contains(index) else {
            caption.attributedStringValue = NSAttributedString(string: "")
            return
        }
        caption.attributedStringValue = Self.captionText(title: tiles[index].title,
                                                         app: tiles[index].appName)
    }

    /// "Title  ·  App": the title carries the weight, the app name is there
    /// for the two-Chromes case where the icon alone does not settle it.
    private static func captionText(title: String, app: String) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingMiddle

        let text = NSMutableAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
        ])
        if !app.isEmpty, app != title {
            text.append(NSAttributedString(string: "  ·  " + app, attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .regular),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: paragraph,
            ]))
        }
        return text
    }

    func apply(image: NSImage, for id: CGWindowID) {
        tiles.first { $0.windowID == id }?.setPreview(image)
    }
}

/// One window: a preview at a fixed size, its app icon, and its title.
private final class SwitcherTileView: NSView {
    private static let baseWidth: CGFloat = 176
    private static let basePreviewHeight: CGFloat = 108
    private static let padding: CGFloat = 10
    private static let iconSide: CGFloat = 16

    static func width(scale: CGFloat) -> CGFloat { (baseWidth * scale).rounded() }
    static func previewHeight(scale: CGFloat) -> CGFloat { (basePreviewHeight * scale).rounded() }
    static func height(scale: CGFloat) -> CGFloat {
        previewHeight(scale: scale) + padding + 8 + iconSide + padding
    }

    let windowID: CGWindowID
    let title: String
    let appName: String
    var onClick: (() -> Void)?

    private let preview = PreviewView()
    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private var tracking: NSTrackingArea?

    var isSelected = false {
        didSet {
            guard isSelected != oldValue else { return }
            label.textColor = isSelected ? .labelColor : .secondaryLabelColor
            needsDisplay = true
        }
    }

    private var isHovered = false {
        didSet { if isHovered != oldValue { needsDisplay = true } }
    }

    init(entry: WindowEntry, scale: CGFloat) {
        windowID = entry.id
        title = entry.displayTitle
        appName = entry.appName
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        // Until a capture arrives the app icon stands in, drawn at a fixed size
        // rather than at whatever its natural resolution happens to be — that
        // is what made some tiles show a postage stamp and others a full frame.
        preview.setIcon(entry.icon)
        preview.kind = entry.kind
        preview.translatesAutoresizingMaskIntoConstraints = false

        iconView.image = entry.icon
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        iconView.setContentCompressionResistancePriority(.required, for: .horizontal)

        label.stringValue = entry.displayTitle
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.alignment = .left
        label.toolTip = entry.displayTitle
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let pad = Self.padding
        addSubview(preview)
        addSubview(iconView)
        addSubview(label)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.width(scale: scale)),

            preview.topAnchor.constraint(equalTo: topAnchor, constant: pad),
            preview.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
            preview.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad),
            preview.heightAnchor.constraint(equalToConstant: Self.previewHeight(scale: scale)),

            iconView.topAnchor.constraint(equalTo: preview.bottomAnchor, constant: 8),
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
            iconView.widthAnchor.constraint(equalToConstant: Self.iconSide),
            iconView.heightAnchor.constraint(equalToConstant: Self.iconSide),
            iconView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -pad),

            // Pinned to both edges so the title always has the row to itself
            // and can truncate instead of being squeezed out of existence.
            label.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad),
            label.centerYAnchor.constraint(equalTo: iconView.centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func setPreview(_ image: NSImage) {
        preview.setCapture(image)
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1),
                                xRadius: 14, yRadius: 14)
        if isSelected {
            NSColor.controlAccentColor.withAlphaComponent(0.28).setFill()
            path.fill()
            NSColor.controlAccentColor.setStroke()
            path.lineWidth = 2
            path.stroke()
        } else if isHovered {
            NSColor.white.withAlphaComponent(0.07).setFill()
            path.fill()
        }
    }

    // MARK: - Mouse

    /// The panel is never key, and a view in a non-key window drops its first
    /// click unless it says otherwise. Every click here is the first one.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick?()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
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

    /// A minimised window, or one whose app is hidden, is drawn dimmed with a
    /// small mark in the corner, so it is plainly not on screen right now.
    var kind: WindowEntry.Kind = .onScreen {
        didSet { needsDisplay = true }
    }

    private var isParked: Bool { kind == .minimized || kind == .hidden }

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
        let box = NSBezierPath(roundedRect: bounds, xRadius: 9, yRadius: 9)
        NSColor.black.withAlphaComponent(0.26).setFill()
        box.fill()

        if let image, image.size.width > 0, image.size.height > 0 {
            NSGraphicsContext.current?.imageInterpolation = .high
            let fraction: CGFloat = isParked ? 0.55 : 1
            if isIcon {
                let side = min(Self.iconSide, min(bounds.width, bounds.height) - 8)
                let target = NSRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2,
                                    width: side, height: side)
                image.draw(in: target, from: .zero, operation: .sourceOver, fraction: fraction)
            } else {
                // Fit the whole window inside the box: cropping a screenshot
                // would hide the very part that tells two windows apart.
                let scale = min(bounds.width / image.size.width,
                                bounds.height / image.size.height)
                let size = NSSize(width: (image.size.width * scale).rounded(),
                                  height: (image.size.height * scale).rounded())
                let target = NSRect(x: (bounds.midX - size.width / 2).rounded(),
                                    y: (bounds.midY - size.height / 2).rounded(),
                                    width: size.width, height: size.height)
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(roundedRect: target, xRadius: 5, yRadius: 5).addClip()
                image.draw(in: target, from: .zero, operation: .sourceOver, fraction: fraction)
                NSGraphicsContext.restoreGraphicsState()
            }
        }

        // An inner hairline so a capture with a white page does not bleed
        // into a white tile edge, and an empty box still reads as a frame.
        NSColor.white.withAlphaComponent(0.08).setStroke()
        let edge = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                xRadius: 8.5, yRadius: 8.5)
        edge.lineWidth = 1
        edge.stroke()

        switch kind {
        case .minimized: drawBadge("minus")
        case .hidden: drawBadge("eye.slash")
        default: break
        }
    }

    /// A small dark disc in the corner saying why the window is dimmed: a
    /// dash for the Dock, a crossed eye for a hidden app.
    private func drawBadge(_ symbol: String) {
        let radius: CGFloat = 8
        let center = NSPoint(x: bounds.maxX - radius - 6, y: bounds.minY + radius + 6)
        let disc = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius,
                                               width: radius * 2, height: radius * 2))
        NSColor(white: 0.12, alpha: 0.92).setFill()
        disc.fill()
        NSColor.white.withAlphaComponent(0.18).setStroke()
        disc.lineWidth = 1
        disc.stroke()

        let configuration = NSImage.SymbolConfiguration(pointSize: 8, weight: .bold)
            .applying(NSImage.SymbolConfiguration(
                paletteColors: [NSColor.white.withAlphaComponent(0.9)]))
        guard let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        else { return }
        let size = glyph.size
        glyph.draw(in: NSRect(x: (center.x - size.width / 2).rounded(),
                              y: (center.y - size.height / 2).rounded(),
                              width: size.width, height: size.height))
    }
}
