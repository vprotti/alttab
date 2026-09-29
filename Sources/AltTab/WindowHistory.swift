import AppKit

/// When each window was last the one in use, across every desktop.
///
/// The stacking order on screen answers that for this desktop and says
/// nothing about the others. This fills the gap from what the system
/// announces anyway — an app coming forward, a desktop change — plus every
/// switch made here, at the cost of one look at the window list each time.
final class WindowHistory: @unchecked Sendable {
    static let shared = WindowHistory()

    private let lock = NSLock()
    private var stamps: [CGWindowID: UInt64] = [:]
    private var clock: UInt64 = 0
    private let queue = DispatchQueue(label: "br.com.nasralla.alttab.history", qos: .utility)
    private var observers: [NSObjectProtocol] = []

    /// Plenty for a day of work, small enough never to matter.
    private static let capacity = 400

    func start() {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: nil
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.noteFrontWindow(of: app?.processIdentifier)
        })
        observers.append(center.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: nil
        ) { [weak self] _ in
            self?.noteFrontWindow(of: nil)
        })
    }

    func touch(_ id: CGWindowID) {
        lock.lock()
        defer { lock.unlock() }
        clock += 1
        stamps[id] = clock
        guard stamps.count > Self.capacity else { return }
        let keepAfter = clock - UInt64(Self.capacity / 2)
        stamps = stamps.filter { $0.value > keepAfter }
    }

    func lastUse(of ids: [CGWindowID]) -> [CGWindowID: UInt64] {
        lock.lock()
        defer { lock.unlock() }
        var result: [CGWindowID: UInt64] = [:]
        for id in ids {
            if let stamp = stamps[id] { result[id] = stamp }
        }
        return result
    }

    /// A moment's grace: an app announces itself before its window has
    /// finished coming to the front.
    private func noteFrontWindow(of pid: pid_t?) {
        queue.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let id = WindowList.frontWindow(of: pid) else { return }
            self?.touch(id)
        }
    }
}
