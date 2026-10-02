// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PointAndTell",
    platforms: [.macOS(.v11)],
    products: [.executable(name: "PointAndTell", targets: ["PointAndTell"]),
               .library(name: "PointAndTellCore", targets: ["PointAndTellCore"])],
    targets: [
        .target(name: "PointAndTellCore"),
        .executableTarget(name: "PointAndTell", dependencies: ["PointAndTellCore"]),
        .testTarget(name: "PointAndTellCoreTests", dependencies: ["PointAndTellCore"])
    ]
)
