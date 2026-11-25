// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "agweb",
    platforms: [.macOS("15.4")],
    targets: [
        .target(name: "AgwebCore"),
        // Security keys over USB HID (Passkeys.swift); found through pkg-config.
        .systemLibrary(name: "CFido2", pkgConfig: "libfido2", providers: [.brew(["libfido2"])]),
        // Weak, so the app starts without libfido2; SecurityKey.available checks first. dead_strip_dylibs drops the unused libcrypto.
        .executableTarget(name: "AgwebApp", dependencies: ["AgwebCore", "CFido2"], linkerSettings: [.unsafeFlags(["-Xlinker", "-weak-lfido2", "-Xlinker", "-dead_strip_dylibs"])]),
        .executableTarget(name: "agweb", dependencies: ["AgwebCore"]),
        .testTarget(name: "AgwebCoreTests", dependencies: ["AgwebCore"]),
    ]
)
