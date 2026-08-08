// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ClamshellKit",
    platforms: [
        .macOS(.v12)
    ],
    products: [
        .library(
            name: "ClamshellKit",
            targets: ["ClamshellKit"]
        )
    ],
    targets: [
        .target(
            name: "ClamshellKit",
            linkerSettings: [
                .linkedFramework("IOKit")
            ]
        ),
        .testTarget(
            name: "ClamshellKitTests",
            dependencies: ["ClamshellKit"]
        )
    ]
)
