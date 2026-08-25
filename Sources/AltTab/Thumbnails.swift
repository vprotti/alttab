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

    /// Thumbnails are only ever drawn small, so capture small: a full-resolution
    /// grab of a 6K display costs far more than the picture is worth.
    private static let maxSide: CGFloat = 480

    private var cache: [CGWindowID: (image: NSImage, taken: Date)] = [:]
    /// A window's contents change; a picture older than this is not worth showing.
    private static let maxAge: TimeInterval = 20

    /// Cached picture if it is recent enough, without capturing anything.
    func cached(_ id: CGWindowID) -> NSImage? {
        guard let hit = cache[id], Date().timeIntervalSince(hit.taken) < Self.maxAge
        else { return nil }
        return hit.image
    }

    func image(for entry: WindowEntry) async -> NSImage? {
        if let hit = cached(entry.id) { return hit }
        guard Permissions.hasScreenRecording else { return nil }

        let image: NSImage?
        if #available(macOS 14.0, *) {
            image = await captureModern(entry)
        } else {
            image = captureLegacy(entry)
        }
        if let image { cache[entry.id] = (image, Date()) }
        return image
    }

    /// Drops pictures of windows that no longer exist, so a long-running app
    /// does not accumulate one per window it ever saw.
    func prune(keeping ids: Set<CGWindowID>) {
        cache = cache.filter { ids.contains($0.key) }
    }

    // MARK: - macOS 14+

    @available(macOS 14.0, *)
    private func captureModern(_ entry: WindowEntry) async -> NSImage? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(
            true, onScreenWindowsOnly: false),
            let window = content.windows.first(where: { $0.windowID == entry.id })
        else { return nil }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        let scale = min(1, Self.maxSide / max(entry.frame.width, entry.frame.height))
        config.width = max(1, Int(entry.frame.width * scale))
        config.height = max(1, Int(entry.frame.height * scale))
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true

        guard let cgImage = try? await SCScreenshotManager.captureImage(
            contentFilter: filter, configuration: config)
        else { return nil }
        return NSImage(cgImage: cgImage, size: .zero)
    }

    // MARK: - macOS 13

    private func captureLegacy(_ entry: WindowEntry) -> NSImage? {
        // Deprecated since macOS 14 and returns nothing without permission, but
        // it is the only single-shot window capture that exists on 13.
        guard let cgImage = CGWindowListCreateImage(
            .null, .optionIncludingWindow, entry.id,
            [.boundsIgnoreFraming, .nominalResolution]),
            cgImage.width > 1, cgImage.height > 1
        else { return nil }
        return NSImage(cgImage: cgImage, size: .zero)
    }
}
