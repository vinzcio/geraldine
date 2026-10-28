// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Geraldine",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Self-updates. Pinned exactly: the updater verifies every release, so a
        // framework change is a reviewed source change, never a silent resolve.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")
    ],
    targets: [
        .target(
            name: "CThermal",
            path: "Sources/CThermal"
        ),
        .target(
            name: "GeraldineControl",
            path: "Sources/GeraldineControl"
        ),
        .executableTarget(
            name: "Geraldine",
            dependencies: [
                "CThermal",
                "GeraldineControl",
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/Geraldine",
            resources: [
                .process("Resources")
            ],
            linkerSettings: [
                // build.sh embeds Sparkle.framework in Contents/Frameworks.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("IOKit"),
                .linkedFramework("CoreWLAN"),
                .linkedFramework("CoreLocation"),
                .linkedFramework("Network"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Carbon"),
                .linkedFramework("Security"),
                .linkedLibrary("sqlite3")
            ]
        ),
        .executableTarget(
            name: "GeraldineCLI",
            dependencies: ["GeraldineControl"],
            path: "Sources/GeraldineCLI"
        ),
        .testTarget(
            name: "GeraldineTests",
            dependencies: ["Geraldine", "GeraldineControl"],
            path: "Tests/GeraldineTests"
        )
    ]
)
