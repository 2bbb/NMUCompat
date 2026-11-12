// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NMUCompat",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "ESPKit", targets: ["ESPKit"]),
        .executable(name: "nmucompat", targets: ["nmucompat"]),
    ],
    targets: [
        .target(name: "ESPKit"),
        .executableTarget(name: "nmucompat", dependencies: ["ESPKit"]),
        .testTarget(name: "ESPKitTests", dependencies: ["ESPKit"]),
    ]
)
