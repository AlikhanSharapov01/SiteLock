// swift-tools-version:5.9
import PackageDescription

// SiteLockCore is plain Foundation and also builds on Linux (CI/tests only).
// The daemon and the SwiftUI app use macOS-only APIs and are added on macOS.
var targets: [Target] = [
    .target(name: "SiteLockCore"),
    .testTarget(name: "SiteLockCoreTests", dependencies: ["SiteLockCore"]),
]
var products: [Product] = [
    .library(name: "SiteLockCore", targets: ["SiteLockCore"]),
]

#if os(macOS)
targets += [
    .executableTarget(name: "sitelockd", dependencies: ["SiteLockCore"]),
    .executableTarget(name: "SiteLock", dependencies: ["SiteLockCore"]),
]
products += [
    .executable(name: "sitelockd", targets: ["sitelockd"]),
    .executable(name: "SiteLock", targets: ["SiteLock"]),
]
#endif

let package = Package(
    name: "SiteLock",
    platforms: [.macOS(.v13)],
    products: products,
    targets: targets
)
