// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "agweb",
    platforms: [.macOS("15.4")],
    targets: [
        .target(name: "AgwebCore"),
        // Security keys over USB HID (Passkeys.swift); found through pkg-config.
        .systemLibrary(name: "CFido2", pkgConfig: "libfido2", providers: [.brew(["libfido2"])]),
        .executableTarget(name: "AgwebApp", dependencies: ["AgwebCore", "CFido2"]),
        .executableTarget(name: "agweb", dependencies: ["AgwebCore"]),
        .testTarget(name: "AgwebCoreTests", dependencies: ["AgwebCore"]),
    ]
)
