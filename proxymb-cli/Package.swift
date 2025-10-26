// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "proxymb-cli",
    platforms: [
        .macOS(.v12)
    ],
    products: [
        .executable(name: "proxymb", targets: ["proxymb"])
    ],
    targets: [
        .executableTarget(
            name: "proxymb",
            path: "Sources/proxymb",
            sources: ["main.swift"]
        )
    ]
)
