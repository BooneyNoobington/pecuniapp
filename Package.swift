// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Pecuniapp",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "PecuniaSync", targets: ["PecuniaSync"]),
    ],
    targets: [
        .target(name: "PecuniaSync"),
        .testTarget(name: "PecuniaSyncTests", dependencies: ["PecuniaSync"]),
    ]
)
