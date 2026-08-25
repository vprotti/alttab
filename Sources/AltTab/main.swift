import AppKit

let args = CommandLine.arguments

// Offscreen renderers for the images in docs/ (see SelfTest).
if let i = args.firstIndex(of: "--selftest-switcher"), i + 1 < args.count {
    _ = NSApplication.shared
    MainActor.assumeIsolated { SelfTest.renderSwitcher(to: args[i + 1]) }
    exit(0)
}
if args.contains("--selftest-windows") {
    SelfTest.printWindows()
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.run()
