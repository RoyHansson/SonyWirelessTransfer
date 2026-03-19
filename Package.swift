// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SonyWirelessMacOS",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(
            name: "SonyWirelessMacOS",
            targets: ["SonyWirelessMacOS"]
        ),
    ],
    targets: [
        .executableTarget(
            name: "SonyWirelessMacOS"
        ),
    ]
)
