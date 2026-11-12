// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NMUCompat",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "ESPKit", targets: ["ESPKit"]),
        .executable(name: "nmucompat", targets: ["nmucompat"]),
        .executable(name: "NMUCompatApp", targets: ["NMUCompatApp"]),
    ],
    targets: [
        .target(name: "ESPKit"),
        .executableTarget(name: "nmucompat", dependencies: ["ESPKit"]),
        .executableTarget(name: "NMUCompatApp", dependencies: ["ESPKit"]),
        .testTarget(name: "ESPKitTests", dependencies: ["ESPKit"]),
    ]
)
