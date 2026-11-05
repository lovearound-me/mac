// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Needed",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.4")
    ],
    targets: [
        .executableTarget(
            name: "Needed",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/Needed",
            // build.sh puts Sparkle.framework in Contents/Frameworks.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        )
    ]
)
