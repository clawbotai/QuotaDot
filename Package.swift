// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "QuotaDot",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "QuotaDot", targets: ["QuotaDot"])],
    targets: [
        .executableTarget(
            name: "QuotaDot",
            path: "Sources/QuotaDot",
            resources: [.process("Resources")]
        ),
        .testTarget(name: "QuotaDotTests", dependencies: ["QuotaDot"], path: "Tests/QuotaDotTests")
    ]
)
