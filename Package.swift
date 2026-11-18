// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Jarvis",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "JarvisCore", targets: ["JarvisCore"]),
        .executable(name: "jarvis-hook", targets: ["jarvis-hook"]),
        .executable(name: "JarvisApp", targets: ["JarvisApp"]),
    ],
    targets: [
        .target(name: "JarvisCore"),
        .executableTarget(name: "jarvis-hook", dependencies: ["JarvisCore"]),
        .executableTarget(name: "JarvisApp", dependencies: ["JarvisCore"]),
        .testTarget(
            name: "JarvisCoreTests",
            dependencies: ["JarvisCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
