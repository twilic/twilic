// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Twilic",
    platforms: [
        .macOS(.v13),
        .iOS(.v15),
    ],
    products: [
        .library(name: "Twilic", targets: ["Twilic"]),
    ],
    targets: [
        .target(name: "Twilic", path: "Sources/Twilic"),
        .testTarget(
            name: "TwilicTests",
            dependencies: ["Twilic"],
            path: "Tests/TwilicTests"
        ),
    ]
)
