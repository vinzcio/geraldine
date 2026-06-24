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
            linkerSettings: [
                .linkedFramework("CoreFoundation"),
                .linkedFramework("IOKit"),
                .linkedFramework("CoreWLAN"),
                .linkedFramework("CoreLocation"),
                .linkedFramework("Network"),
                .linkedFramework("ApplicationServices")
            ]
        )
    ]
)
