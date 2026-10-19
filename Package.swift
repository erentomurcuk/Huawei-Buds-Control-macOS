// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "HuaweiAudioControlMac",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "HuaweiAudioControlMac", targets: ["HuaweiAudioControlMac"])
    ],
    targets: [
        .executableTarget(
            name: "HuaweiAudioControlMac",
            linkerSettings: [
                .linkedFramework("IOBluetooth"),
                .linkedFramework("AppKit")
            ]
        )
    ]
)
