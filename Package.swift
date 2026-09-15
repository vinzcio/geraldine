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
        .executableTarget(
            name: "Geraldine",
            dependencies: ["CThermal"],
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
        .testTarget(
            name: "GeraldineTests",
            dependencies: ["Geraldine"],
            path: "Tests/GeraldineTests"
        )
    ]
)
