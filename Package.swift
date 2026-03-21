// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "SiliconValley",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "SiliconValley",
            path: "Sources",
            resources: [
                .copy("../Resources/default_config.json")
            ]
        )
    ]
)
