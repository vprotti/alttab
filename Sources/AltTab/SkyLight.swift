import AppKit

/// The window server's own view of desktops and windows, and its way of
/// bringing one exact window forward.
///
/// Accessibility only ever sees the desktop in front of you. That is why
/// windows on other desktops and full-screen apps never reached the grid, and
/// why one could not be focused even when it did. The window server sees all
/// of them.
///
/// None of this is public API. Every function is looked up by name at
/// runtime, exactly like `_AXUIElementGetWindow`, and every caller carries on
/// without it: if a future macOS drops one, the app goes back to seeing only
/// this desktop instead of breaking.
enum SkyLight {

    // MARK: - Resolving

    private static let framework = dlopen(
        "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)

    private static func resolve<T>(_ names: [String], as type: T.Type) -> T? {
        for name in names {
            if let handle = framework, let symbol = dlsym(handle, name) {
                return unsafeBitCast(symbol, to: type)
            }
            if let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) {
                return unsafeBitCast(symbol, to: type)
            }
        }
        return nil
    }

    private typealias ConnectionFn = @convention(c) () -> Int32
    private typealias CopyDisplaySpacesFn = @convention(c) (Int32) -> UnsafeMutableRawPointer?
    private typealias CopyWindowsFn = @convention(c) (
        Int32, UInt32, CFArray, UInt32,
        UnsafeMutablePointer<UInt64>, UnsafeMutablePointer<UInt64>) -> UnsafeMutableRawPointer?
    private typealias SetFrontProcessFn = @convention(c) (
        UnsafeMutableRawPointer, UInt32, UInt32) -> Int32
    private typealias PostEventRecordFn = @convention(c) (
        UnsafeMutableRawPointer, UnsafeMutableRawPointer) -> Int32
    private typealias ProcessForPIDFn = @convention(c) (pid_t, UnsafeMutableRawPointer) -> Int32

    private static let connection: Int32? =
        resolve(["CGSMainConnectionID", "SLSMainConnectionID"], as: ConnectionFn.self).map { $0() }
    private static let copyDisplaySpaces =
        resolve(["CGSCopyManagedDisplaySpaces", "SLSCopyManagedDisplaySpaces"],
                as: CopyDisplaySpacesFn.self)
    private static let copyWindows =
        resolve(["CGSCopyWindowsWithOptionsAndTags", "SLSCopyWindowsWithOptionsAndTags"],
                as: CopyWindowsFn.self)
    private static let setFrontProcess =
        resolve(["_SLPSSetFrontProcessWithOptions"], as: SetFrontProcessFn.self)
    private static let postEventRecord =
        resolve(["SLPSPostEventRecordTo"], as: PostEventRecordFn.self)
    private static let processForPID =
        resolve(["GetProcessForPID"], as: ProcessForPIDFn.self)

    // MARK: - Desktops

    /// Which windows the window server has placed on a desktop.
    struct Membership {
        /// Drawn on some desktop: the one in front of you, another one, or a
        /// full-screen app's own.
        let visible: Set<CGWindowID>
        /// Drawn on a desktop that some display is showing right now.
        let visibleHere: Set<CGWindowID>
        /// Still attached to a desktop but not drawn: minimised, or belonging
        /// to a hidden app. A closed window is attached to none.
        let parked: Set<CGWindowID>
    }

    static func membership() -> Membership? {
        guard let layout = desktops(),
              let visible = windows(on: layout.all, includingParked: false),
              let attached = windows(on: layout.all, includingParked: true)
        else { return nil }
        return Membership(visible: visible,
                          visibleHere: windows(on: layout.shown, includingParked: false) ?? [],
                          parked: attached.subtracting(visible))
    }

    private static func desktops() -> (all: [UInt64], shown: [UInt64])? {
        guard let connection, let copyDisplaySpaces,
              let raw = copyDisplaySpaces(connection)
        else { return nil }
        let displays = Unmanaged<CFArray>.fromOpaque(raw).takeRetainedValue()
            as? [[String: Any]] ?? []

        var all: [UInt64] = []
        var shown: [UInt64] = []
        for display in displays {
            for space in display["Spaces"] as? [[String: Any]] ?? [] {
                if let id = spaceID(space) { all.append(id) }
            }
            if let current = display["Current Space"] as? [String: Any],
               let id = spaceID(current) {
                shown.append(id)
            }
        }
        guard !all.isEmpty else { return nil }
        return (all: all, shown: shown)
    }

    private static func spaceID(_ space: [String: Any]) -> UInt64? {
        (space["id64"] as? NSNumber)?.uint64Value
            ?? (space["ManagedSpaceID"] as? NSNumber)?.uint64Value
    }

    /// The option bits as the window server reads them: 0x2 asks for the
    /// windows drawn on those desktops, 0x7 adds the minimised and hidden.
    private static func windows(on spaces: [UInt64], includingParked: Bool) -> Set<CGWindowID>? {
        guard let connection, let copyWindows, !spaces.isEmpty else { return nil }
        let list = spaces.map { NSNumber(value: $0) } as CFArray
        var setTags: UInt64 = 0
        var clearTags: UInt64 = 0
        guard let raw = copyWindows(connection, 0, list, includingParked ? 0x7 : 0x2,
                                    &setTags, &clearTags)
        else { return nil }
        let ids = Unmanaged<CFArray>.fromOpaque(raw).takeRetainedValue() as? [NSNumber] ?? []
        return Set(ids.map { CGWindowID($0.uint32Value) })
    }

    // MARK: - Focusing

    static var canFocus: Bool {
        setFrontProcess != nil && postEventRecord != nil && processForPID != nil
    }

    /// Makes one exact window the front window of the Mac, switching to its
    /// desktop when it lives on another one — which Accessibility cannot do,
    /// since it does not see that window at all.
    ///
    /// Two steps: the process comes forward with that window as the one to
    /// show, then the app receives the pair of events a click on the window
    /// would produce, so the window takes the keyboard as well.
    @discardableResult
    static func focus(pid: pid_t, windowID: CGWindowID) -> Bool {
        guard let setFrontProcess, let postEventRecord, let processForPID else { return false }

        var process: (UInt32, UInt32) = (0, 0)
        let found = withUnsafeMutableBytes(of: &process) { processForPID(pid, $0.baseAddress!) }
        guard found == 0 else { return false }

        let userGenerated: UInt32 = 0x200
        let fronted = withUnsafeMutableBytes(of: &process) {
            setFrontProcess($0.baseAddress!, windowID, userGenerated)
        }
        guard fronted == 0 else { return false }

        var event = [UInt8](repeating: 0, count: 0xF8)
        event[0x04] = 0xF8
        event[0x3A] = 0x10
        withUnsafeBytes(of: windowID.littleEndian) { id in
            for (offset, byte) in id.enumerated() { event[0x3C + offset] = byte }
        }
        for offset in 0x20 ..< 0x30 { event[offset] = 0xFF }
        for phase: UInt8 in [0x01, 0x02] {
            event[0x08] = phase
            _ = withUnsafeMutableBytes(of: &process) { psn in
                event.withUnsafeMutableBytes { postEventRecord(psn.baseAddress!, $0.baseAddress!) }
            }
        }
        return true
    }
}
