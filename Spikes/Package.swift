// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PhotosSpike",
    platforms: [.macOS("27.0")],
    targets: [
        .target(name: "SpikeKit"),
        .target(name: "ObjCCatch"),
        .executableTarget(name: "PhotosSpike", dependencies: ["SpikeKit", "ObjCCatch"]),
        .testTarget(name: "SpikeKitTests", dependencies: ["SpikeKit"]),
    ]
)
