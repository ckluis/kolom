// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "Kolom", platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Kolom", targets: ["Kolom"]), .executable(name: "kolomctl", targets: ["KolomCLI"]),
    ],
    targets: [
        .target(name: "KolomCore"), .executableTarget(name: "Kolom", dependencies: ["KolomCore"]),
        .executableTarget(name: "KolomCLI", dependencies: ["KolomCore"]),
        .executableTarget(name: "KolomCoreChecks", dependencies: ["KolomCore"], path: "Tests/KolomCoreTests"),
    ])
