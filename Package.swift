// swift-tools-version: 6.0
import PackageDescription

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
        ]),
        .executableTarget(name: "Sonata", dependencies: ["SonataCore"]),
        .testTarget(name: "SonataCoreTests", dependencies: ["SonataCore"]),
    ]
)
