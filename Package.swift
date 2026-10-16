// swift-tools-version: 5.9
import PackageDescription

// Run core regression tests without launching the menu-bar app or touching
// the user's SSH sessions and system proxy settings.
let package = Package(
    name: "ProxyMbCore",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "ProxyMbCore",
            path: "ProxyMb",
            exclude: ["ContentView.swift", "ProxyMbApp.swift", "SSHViewModel.swift",
                      "Assets.xcassets", "ProxyMb.entitlements"]
        ),
        .testTarget(name: "ProxyMbCoreTests", dependencies: ["ProxyMbCore"], path: "ProxyMbTests")
    ]
)
