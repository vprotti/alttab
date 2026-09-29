import AppKit
import ScreenCaptureKit

/// Live pictures of each window, which is what makes the switcher usable when
/// six of the rows say "Google Chrome".
///
/// Two capture paths, because Apple changed this out from under everyone:
/// `SCScreenshotManager` on macOS 14 and later, and the deprecated
/// `CGWindowListCreateImage` on macOS 13. Both need Screen Recording
/// permission; without it the app shows big app icons instead and still works.
actor Thumbnails {
    static let shared = Thumbnails()

    /// A tile is at most about 160 points wide, so this covers a Retina tile
    /// with room to spare, and a full grid of pictures stays a few megabytes
    /// instead of a few hundred.
    private static let maxSide: CGFloat = 400

    private var cache: [CGWindowID: (image: NSImage, taken: Date)] = [:]
    /// Younger than this and a picture is reused as it is.
    private static let freshAge: TimeInterval = 1
    /// A window behind another tab, on another desktop or in the Dock often
    /// cannot be captured at all, or comes back as an empty frame. Its last
    /// good picture still tells it apart far better than an icon, this long.
    private static let maxAge: TimeInterval = 600

    /// Enumerating shareable content is the slow half of a capture — far
    /// slower than the capture itself — so it is done once per pass. Stored
    /// untyped: a stored property cannot carry an availability condition, and
    /// the type does not exist on macOS 13.
    private var content: Any?
    private var contentTaken = Date.distantPast
    private static let contentAge: TimeInterval = 2

    /// Every picture still worth showing, without capturing anything.
    func cachedImages(for ids: [CGWindowID]) -> [CGWindowID: NSImage] {
        let now = Date()
        var result: [CGWindowID: NSImage] = [:]
        for id in ids {
            guard let hit = cache[id], now.timeIntervalSince(hit.taken) < Self.maxAge else { continue }
            result[id] = hit.image
        }
        return result
    }

    /// Does the slow, shared part of a pass up front so the captures that
    /// follow only pay for themselves.
    func prepare() async {
        guard Permissions.hasScreenRecording else { return }
        if #available(macOS 14.0, *) {
            _ = await shareableContent()
        }
    }

    func image(for entry: WindowEntry) async -> NSImage? {
        if let hit = cache[entry.id], Date().timeIntervalSince(hit.taken) < Self.freshAge {
            return hit.image
        }
        guard Permissions.hasScreenRecording else { return nil }

        let captured: CGImage?
        if #available(macOS 14.0, *) {
            captured = await captureModern(entry)
        } else {
            captured = captureLegacy(entry)
        }
        if let captured, let image = Self.usable(captured) {
            cache[entry.id] = (image, Date())
            return image
        }
        if let hit = cache[entry.id], Date().timeIntervalSince(hit.taken) < Self.maxAge {
            return hit.image
        }
        return nil
    }

    /// Drops pictures of windows that no longer exist, so a long-running app
    /// does not accumulate one per window it ever saw.
    func prune(keeping ids: Set<CGWindowID>) {
        cache = cache.filter { ids.contains($0.key) }
    }

    // MARK: - macOS 14+

    @available(macOS 14.0, *)
    private func shareableContent() async -> SCShareableContent? {
        if let cached = content as? SCShareableContent,
           Date().timeIntervalSince(contentTaken) < Self.contentAge {
            return cached
        }
        guard let fresh = try? await SCShareableContent.excludingDesktopWindows(
            true, onScreenWindowsOnly: false)
        else { return nil }
        content = fresh
        contentTaken = Date()
        return fresh
    }

    @available(macOS 14.0, *)
    private func captureModern(_ entry: WindowEntry) async -> CGImage? {
        guard let content = await shareableContent(),
              let window = content.windows.first(where: { $0.windowID == entry.id })
        else { return nil }

        let frame = window.frame.isEmpty ? entry.frame : window.frame
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        let scale = min(1, Self.maxSide / max(1, max(frame.width, frame.height)))
        config.width = max(1, Int(frame.width * scale))
        config.height = max(1, Int(frame.height * scale))
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true

        return try? await SCScreenshotManager.captureImage(contentFilter: filter,
                                                           configuration: config)
    }

    // MARK: - macOS 13

    private func captureLegacy(_ entry: WindowEntry) -> CGImage? {
        // Deprecated since macOS 14 and returns nothing without permission, but
        // it is the only single-shot window capture that exists on 13. It comes
        // back at full size, which is why it is scaled down before it is kept.
        guard let image = CGWindowListCreateImage(
            .null, .optionIncludingWindow, entry.id,
            [.boundsIgnoreFraming, .nominalResolution])
        else { return nil }
        return Self.downscaled(image)
    }

    // MARK: - Checking what came back

    private static func usable(_ image: CGImage) -> NSImage? {
        guard image.width > 1, image.height > 1, !isBlank(image) else { return nil }
        return NSImage(cgImage: image, size: .zero)
    }

    /// A window the window server is not drawing — a tab behind another, one
    /// on a desktop it has not composited lately — can capture as a frame of
    /// pure black or pure nothing. Shown, that reads as a broken tile.
    ///
    /// Judged on an 8×8 reduction: any real window has at least a title bar
    /// or an edge that is neither transparent nor black.
    private static func isBlank(_ image: CGImage) -> Bool {
        let side = 8
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return false }

        var opaque = false
        var lit = false
        for index in stride(from: 0, to: pixels.count, by: 4) {
            if pixels[index + 3] > 2 { opaque = true }
            if pixels[index] > 2 || pixels[index + 1] > 2 || pixels[index + 2] > 2 { lit = true }
            if opaque && lit { return false }
        }
        return true
    }

    private static func downscaled(_ image: CGImage) -> CGImage {
        let longest = CGFloat(max(image.width, image.height))
        guard longest > maxSide else { return image }
        let scale = maxSide / longest
        let width = max(1, Int(CGFloat(image.width) * scale))
        let height = max(1, Int(CGFloat(image.height) * scale))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }
}
