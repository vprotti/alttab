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
    private static let maxSide: CGFloat = 512

    private var cache: [CGWindowID: (image: NSImage, taken: Date)] = [:]
    /// Younger than this and a picture is simply reused; older, it is shown
    /// while a fresh one is taken; past `maxAge` it is not shown at all.
    private static let freshAge: TimeInterval = 1
    private static let maxAge: TimeInterval = 30

    /// Enumerating shareable content is the slow half of a capture — far
    /// slower than the capture itself — and it was being done once per window.
    /// Now once per pass. Stored untyped: a stored property cannot carry an
    /// availability condition, and the type does not exist on macOS 13.
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

        let image: NSImage?
        if #available(macOS 14.0, *) {
            image = await captureModern(entry)
        } else {
            image = captureLegacy(entry)
        }
        if let image {
            cache[entry.id] = (image, Date())
            return image
        }
        // A capture can fail for a window that just went away or changed
        // Space; the last good picture is better than a blank tile.
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
    private func captureModern(_ entry: WindowEntry) async -> NSImage? {
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
