// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Geraldine",
    platforms: [.macOS(.v14)],
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
            dependencies: ["CThermal", "GeraldineControl"],
            path: "Sources/Geraldine",
            resources: [
                .process("Resources")
            ],
            linkerSettings: [
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
