// swift-tools-version: 6.2
import PackageDescription

// Sonata's own targets build with warnings as errors (CI too); dependencies don't.
let strict: [SwiftSetting] = [.treatAllWarnings(as: .error)]

let package = Package(
    name: "Sonata",
    platforms: [.macOS(.v15)],  // kit-swift's floor
    products: [
        .executable(name: "Sonata", targets: ["Sonata"]),
    ],
    dependencies: [
        .package(url: "https://github.com/solana-foundation/kit-swift.git", branch: "main"),
    ],
    targets: [
        .target(name: "SonataCore", dependencies: [
            .product(name: "SolanaRPC", package: "kit-swift"),
        ], swiftSettings: strict),
        .executableTarget(name: "Sonata", dependencies: ["SonataCore"], swiftSettings: strict),
        .testTarget(name: "SonataCoreTests", dependencies: ["SonataCore"], swiftSettings: strict),
    ]
)
