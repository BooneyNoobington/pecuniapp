// swift-tools-version: 6.2
import PackageDescription

// GRDB is only used on Apple platforms. The sync core itself has no dependencies, so it also
// builds on Linux, where the long simulations can run.
let grdb = Target.Dependency.product(
    name: "GRDB", package: "GRDB.swift", condition: .when(platforms: [.macOS, .iOS]))

let package = Package(
    name: "Pecuniapp",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "PecuniaSync", targets: ["PecuniaSync"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.12.0"),
    ],
    targets: [
        .target(name: "PecuniaSync", dependencies: [grdb]),
        .testTarget(name: "PecuniaSyncTests", dependencies: ["PecuniaSync", grdb]),
    ]
)
