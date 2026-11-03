// swift-tools-version: 6.2
import PackageDescription

// Every target builds with warnings as errors, here and in CI.
let strict: [SwiftSetting] = [.treatAllWarnings(as: .error)]

let package = Package(
    name: "Sonata",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Sonata", targets: ["Sonata"]),
    ],
    targets: [
        .target(name: "SonataCore", swiftSettings: strict),
        .executableTarget(name: "Sonata", dependencies: ["SonataCore"], swiftSettings: strict),
        .testTarget(name: "SonataCoreTests", dependencies: ["SonataCore"], swiftSettings: strict),
    ]
)
