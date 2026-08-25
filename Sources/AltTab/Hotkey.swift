import AppKit
import Carbon.HIToolbox

/// The shortcut that opens the switcher, as the user configured it.
struct Shortcut: Equatable, Codable {
    /// Virtual key code of the key pressed *while* the modifier is held (Tab).
    var keyCode: UInt16
    /// The modifier that has to stay down. Releasing it is what commits.
    var modifier: Modifier

    enum Modifier: String, Codable, CaseIterable {
        case option, control, command

        var flag: CGEventFlags {
            switch self {
            case .option: return .maskAlternate
            case .control: return .maskControl
            case .command: return .maskCommand
            }
        }

        /// Both physical keys, because either one can be the one released.
        var keyCodes: [UInt16] {
            switch self {
            case .option: return [UInt16(kVK_Option), UInt16(kVK_RightOption)]
            case .control: return [UInt16(kVK_Control), UInt16(kVK_RightControl)]
            case .command: return [UInt16(kVK_Command), UInt16(kVK_RightCommand)]
            }
        }

        /// The same modifier as AppKit spells it, for polling the live state.
        var appKitFlag: NSEvent.ModifierFlags {
            switch self {
            case .option: return .option
            case .control: return .control
            case .command: return .command
            }
        }

        var symbol: String {
            switch self {
            case .option: return "⌥"
            case .control: return "⌃"
            case .command: return "⌘"
            }
        }
    }

    /// Option-Tab. Nothing in macOS claims it, and it is the muscle memory
    /// every person coming from Windows already has.
    static let `default` = Shortcut(keyCode: UInt16(kVK_Tab), modifier: .option)

    var display: String { "\(modifier.symbol)\(KeyNames.name(for: keyCode))" }
}

enum KeyNames {
    static func name(for keyCode: UInt16) -> String {
        switch Int(keyCode) {
        case kVK_Tab: return "⇥"
        case kVK_Space: return "Space"
        case kVK_ANSI_Grave: return "`"
        case kVK_Escape: return "⎋"
        default: break
        }
        // Ask the current keyboard layout what this key produces, so a French
        // or ABNT layout labels its own keys correctly.
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return "Key \(keyCode)" }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data

        var deadKeys: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        let status = data.withUnsafeBytes { buffer -> OSStatus in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self)
            else { return -1 }
            return UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDisplay), 0,
                                  UInt32(LMGetKbdType()), UInt32(kUCKeyTranslateNoDeadKeysBit),
                                  &deadKeys, chars.count, &length, &chars)
        }
        guard status == noErr, length > 0 else { return "Key \(keyCode)" }
        return String(utf16CodeUnits: chars, count: length).uppercased()
    }
}

/// Watches the keyboard for the switcher shortcut.
///
/// A Carbon hot key would be simpler, but it only ever reports the key going
/// *down* — and this shortcut is defined by the modifier coming *up*. So the
/// keyboard is observed with an event tap, which is also the only way to
/// swallow the Tab so it never reaches whatever app is in front.
///
/// The tap sits in the session, ahead of applications, and the callback does
/// almost nothing: the system disables a tap that takes too long, and a slow
/// callback here would stutter every keystroke on the Mac.
final class Hotkey {
    /// Called when the shortcut opens the switcher, and on every step after.
    var onOpen: (() -> Void)?
    var onStep: ((Int) -> Void)?      // +1 forward, -1 backward
    var onCommit: (() -> Void)?
    var onCancel: (() -> Void)?

    /// Touched from the tap thread and read from the main one.
    private let lock = NSLock()
    private var active = false
    private var shortcut: Shortcut
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var thread: Thread?
    private var runLoop: CFRunLoop?

    var isActive: Bool {
        lock.lock(); defer { lock.unlock() }
        return active
    }

    private func setActive(_ value: Bool) {
        lock.lock(); active = value; lock.unlock()
    }

    init(shortcut: Shortcut) {
        self.shortcut = shortcut
    }

    func update(shortcut: Shortcut) {
        self.shortcut = shortcut
        cancel()
    }

    // MARK: - Tap lifecycle

    /// The tap runs on a thread of its own, and this is not a detail.
    ///
    /// An active event tap sits in the path of every keystroke on the Mac: the
    /// window server hands the event over and waits for a verdict before
    /// delivering it to anyone. If the tap's run loop is busy, input stalls —
    /// system-wide, mouse included. Attached to the main run loop, any slow
    /// main-thread work (a hung app answering an accessibility query, laying
    /// out the panel) froze the whole machine's input until it finished.
    ///
    /// On its own thread the callback answers in microseconds no matter what
    /// the rest of the app is doing. All it ever does is decide whether to
    /// swallow the key and hand the real work to the main thread.
    @discardableResult
    func start() -> Bool {
        stop()
        let ready = DispatchSemaphore(value: 0)
        var created = false

        let thread = Thread { [weak self] in
            guard let self else { ready.signal(); return }
            // Published before the semaphore so stop() can never observe a nil
            // run loop for a thread that is already running.
            self.runLoop = CFRunLoopGetCurrent()
            created = self.installTap()
            ready.signal()
            guard created else { return }

            while !Thread.current.isCancelled {
                CFRunLoopRunInMode(.defaultMode, 1.0, false)
            }
            self.teardownTap()
        }
        thread.name = "br.com.nasralla.alttab.eventtap"
        // Above default so the tap is never starved by ordinary work.
        thread.qualityOfService = .userInteractive
        thread.start()

        ready.wait()
        if created { self.thread = thread } else { thread.cancel() }
        return created
    }

    private func installTap() -> Bool {
        let mask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,           // .defaultTap so events can be swallowed
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, context in
                let monitor = Unmanaged<Hotkey>.fromOpaque(context!).takeUnretainedValue()
                return monitor.handle(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return false }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        return true
    }

    private func teardownTap() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source, let runLoop {
            CFRunLoopRemoveSource(runLoop, source, .commonModes)
        }
        tap = nil
        source = nil
        runLoop = nil
    }

    func stop() {
        guard let thread else { return }
        thread.cancel()
        if let runLoop { CFRunLoopStop(runLoop) }
        self.thread = nil
        setActive(false)
    }

    var isRunning: Bool { thread != nil }

    // MARK: - The state machine

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // The system switches the tap off if a callback ever runs long, and
        // after certain user input. Turning it back on is our job.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        let flags = event.flags
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))

        if type == .flagsChanged {
            // The modifier came up: that is the commit.
            if isActive, shortcut.modifier.keyCodes.contains(keyCode),
               !flags.contains(shortcut.modifier.flag) {
                setActive(false)
                DispatchQueue.main.async { [weak self] in self?.onCommit?() }
            }
            return Unmanaged.passUnretained(event)
        }

        guard type == .keyDown else { return Unmanaged.passUnretained(event) }

        if isActive {
            switch Int(keyCode) {
            case kVK_Escape:
                setActive(false)
                DispatchQueue.main.async { [weak self] in self?.onCancel?() }
                return nil
            case Int(shortcut.keyCode):
                let step = flags.contains(.maskShift) ? -1 : 1
                DispatchQueue.main.async { [weak self] in self?.onStep?(step) }
                return nil
            case kVK_LeftArrow, kVK_UpArrow:
                DispatchQueue.main.async { [weak self] in self?.onStep?(-1) }
                return nil
            case kVK_RightArrow, kVK_DownArrow:
                DispatchQueue.main.async { [weak self] in self?.onStep?(1) }
                return nil
            case kVK_Return, kVK_ANSI_KeypadEnter:
                setActive(false)
                DispatchQueue.main.async { [weak self] in self?.onCommit?() }
                return nil
            default:
                // Any other key means the user moved on; get out of the way.
                setActive(false)
                DispatchQueue.main.async { [weak self] in self?.onCancel?() }
                return Unmanaged.passUnretained(event)
            }
        }

        // Not open yet: does this keystroke open it?
        guard keyCode == shortcut.keyCode, flags.contains(shortcut.modifier.flag) else {
            return Unmanaged.passUnretained(event)
        }
        setActive(true)
        let step = flags.contains(.maskShift) ? -1 : 1
        DispatchQueue.main.async { [weak self] in
            self?.onOpen?()
            if step == -1 { self?.onStep?(-1) }
        }
        return nil
    }

    func cancel() {
        guard isActive else { return }
        setActive(false)
        onCancel?()
    }
}
