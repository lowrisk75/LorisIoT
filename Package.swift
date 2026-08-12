// swift-tools-version: 6.0
import PackageDescription

// LorisIoT — shared IoT framework for LorisLabs Apple apps (internal / all-rights-reserved).
// v1: dependency-free IoTCore. Provider satellites (IoTHomeAssistant, IoTShelly, …) are added as
// separate targets depending only on IoTCore. See ~/GitHub/iot-framework/IoTKit-DESIGN.md.
let package = Package(
    name: "LorisIoT",
    platforms: [.iOS(.v17), .macOS(.v14), .watchOS(.v10), .tvOS(.v17), .visionOS(.v1)],
    products: [
        .library(name: "IoTCore", targets: ["IoTCore"]),
    ],
    targets: [
        .target(
            name: "IoTCore",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("StrictConcurrency"),
            ]
        ),
        .testTarget(
            name: "IoTCoreTests",
            dependencies: ["IoTCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
