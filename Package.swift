// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SmartChatApp",
    platforms: [
        .iOS(.v17)
    ],
    products: [
        .library(
            name: "SmartChatApp",
            targets: ["SmartChatApp"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/pointfreeco/swift-composable-architecture", from: "2.0.0")
    ],
    targets: [
        .target(
            name: "SmartChatApp",
            dependencies: [
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture")
            ]
        )
    ]
)
