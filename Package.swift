// swift-tools-version:5.9
import PackageDescription

// NOTE: keep this package free of `resources:` declarations. The .app bundle is
// assembled by hand in scripts/build.sh, so Bundle.module lookups would crash at
// launch — all strings live in code (L10n.swift) and the icons are drawn at
// runtime. The only bundled resource, AltTab.icns, is referenced by Info.plist.
let package = Package(
    name: "AltTab",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "AltTab"),
        .executableTarget(name: "assetgen"),
    ]
)
