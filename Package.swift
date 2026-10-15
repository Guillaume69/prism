// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Prism",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Prism",
            path: "Sources/Prism",
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
    ]
)
