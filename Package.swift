// swift-tools-version:5.9
// Swift 5 language mode on purpose: the Mac layer uses classic GCD + delegate patterns that are
// simplest to reason about without Swift 6 strict-concurrency annotations.
import PackageDescription

let package = Package(
    name: "GesturePointer",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "GesturePointer", targets: ["GesturePointerApp"]),
        .library(name: "GestureCore", targets: ["GestureCore"]),
        .executable(name: "gesture-replay", targets: ["GestureReplay"]),
    ],
    targets: [
        // Foundation-only gesture brain. Builds and tests on Linux.
        .target(name: "GestureCore"),
        // macOS shell. Every file is wrapped in `#if canImport(AppKit)` so a Linux build of the
        // whole package succeeds with this target effectively empty.
        .executableTarget(name: "GesturePointerApp", dependencies: ["GestureCore"]),
        // Cross-platform replay tool: run a recording through GestureCore and print the result.
        .executableTarget(name: "GestureReplay", dependencies: ["GestureCore"]),
        .testTarget(name: "GestureCoreTests", dependencies: ["GestureCore"]),
    ]
)
