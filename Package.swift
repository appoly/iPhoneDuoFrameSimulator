// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DuoFrameSimulator",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "DuoFrameSimulator", targets: ["DuoFrameSimulator"])
    ],
    targets: [
        .target(name: "DuoFrameSimulator")
    ]
)
