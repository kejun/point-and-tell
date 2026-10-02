// swift-tools-version: 5.9
import PackageDescription

// Sparkle 2.10 raises its minimum OS to 12. Keep Big Sur support, and let
// Linux test the pure core without resolving a macOS-only binary artifact.
#if os(macOS)
let updatePackages: [Package.Dependency] = [
    .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6")
]
let appDependencies: [Target.Dependency] = [
    "PointAndTellCore", .product(name: "Sparkle", package: "Sparkle")
]
#else
let updatePackages: [Package.Dependency] = []
let appDependencies: [Target.Dependency] = ["PointAndTellCore"]
#endif

let package = Package(
    name: "PointAndTell",
    platforms: [.macOS(.v11)],
    products: [.executable(name: "PointAndTell", targets: ["PointAndTell"]),
               .library(name: "PointAndTellCore", targets: ["PointAndTellCore"])],
    dependencies: updatePackages,
    targets: [
        .target(name: "PointAndTellCore"),
        .executableTarget(name: "PointAndTell", dependencies: appDependencies,
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker",
                "@executable_path/../Frameworks"], .when(platforms: [.macOS]))]),
        .testTarget(name: "PointAndTellCoreTests", dependencies: ["PointAndTellCore"])
    ]
)
