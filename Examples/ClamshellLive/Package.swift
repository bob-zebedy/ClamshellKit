// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ClamshellLive",
    platforms: [
        .macOS(.v12)
    ],
    products: [
        .executable(
            name: "ClamshellLive",
            targets: ["ClamshellLive"]
        )
    ],
    dependencies: [
        .package(path: "../..")
    ],
    targets: [
        .executableTarget(
            name: "ClamshellLive",
            dependencies: [
                .product(
                    name: "ClamshellKit",
                    package: "ClamshellKit"
                )
            ]
        )
    ]
)
