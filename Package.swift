// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "Movoa",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [.library(name: "Movoa", targets: ["Movoa"])],
    targets: [
        .target(name: "Movoa"),
        .testTarget(name: "MovoaTests", dependencies: ["Movoa"]),
    ]
)
