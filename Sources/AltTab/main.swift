import AppKit

let args = CommandLine.arguments

// Offscreen renderers for the images in docs/ (see SelfTest).
if let i = args.firstIndex(of: "--selftest-switcher"), i + 1 < args.count {
    _ = NSApplication.shared
    MainActor.assumeIsolated { SelfTest.renderSwitcher(to: args[i + 1]) }
    exit(0)
}
if args.contains("--selftest-tap") {
    _ = NSApplication.shared
    SelfTest.runTapCheck()
    exit(0)
}
if args.contains("--selftest-windows") {
    SelfTest.printWindows()
    exit(0)
}

if args.contains("--selftest-single") { SingleInstance.runSelfTest() }

// One copy at a time, and nothing on this Mac guarantees it on its own: a
// binary exec'd directly — by launchd, or by a LaunchAgent some other
// installer left behind pointing at this path — never passes through Launch
// Services and starts a second app right on top of the first.
guard SingleInstance.claim() else {
    SingleInstance.wakeRunningInstance()
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.run()
