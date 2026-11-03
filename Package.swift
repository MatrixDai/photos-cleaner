// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PhotosCleaner",
    platforms: [.macOS("27.0")],
    products: [.executable(name: "PhotosCleaner", targets: ["PhotosCleaner"])],
    targets: [
        .target(name: "CleanerCore"),
        .executableTarget(name: "PhotosCleaner", dependencies: ["CleanerCore"]),
        .testTarget(name: "CleanerCoreTests", dependencies: ["CleanerCore"], resources: [.copy("Fixtures")]),
    ]
)
