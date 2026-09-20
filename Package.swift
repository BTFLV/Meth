// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Meth",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "Meth", targets: ["Meth"]),
        .executable(name: "MethWatchdog", targets: ["MethWatchdog"]),
        .library(name: "MethCore", targets: ["MethCore"])
    ],
    targets: [
        .target(
            name: "MethCore",
            path: "Sources/MethCore"
        ),
        .executableTarget(
            name: "Meth",
            dependencies: ["MethCore"],
            path: "Sources/Meth",
            exclude: ["Resources/Info.plist"]
        ),
        .executableTarget(
            name: "MethWatchdog",
            dependencies: ["MethCore"],
            path: "Sources/MethWatchdog"
        ),
        .testTarget(
            name: "MethTests",
            dependencies: ["MethCore"],
            path: "Tests/MethTests"
        )
    ]
)
