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
        .library(name: "IoTHomeAssistant", targets: ["IoTHomeAssistant"]),
        .library(name: "IoTShelly", targets: ["IoTShelly"]),
        .library(name: "IoTMQTT", targets: ["IoTMQTT"]),
        .library(name: "IoTWebhook", targets: ["IoTWebhook"]),
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
        .target(
            name: "IoTHomeAssistant",
            dependencies: ["IoTCore"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("StrictConcurrency"),
            ]
        ),
        .testTarget(
            name: "IoTHomeAssistantTests",
            dependencies: ["IoTHomeAssistant"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "IoTShelly",
            dependencies: ["IoTCore"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("StrictConcurrency"),
            ]
        ),
        .testTarget(
            name: "IoTShellyTests",
            dependencies: ["IoTShelly"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // NOTE: MQTTNIO-backed transport is added behind this module later (isolated dep, per spec).
        .target(
            name: "IoTMQTT",
            dependencies: ["IoTCore"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("StrictConcurrency"),
            ]
        ),
        .testTarget(
            name: "IoTMQTTTests",
            dependencies: ["IoTMQTT"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "IoTWebhook",
            dependencies: ["IoTCore"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("StrictConcurrency"),
            ]
        ),
        .testTarget(
            name: "IoTWebhookTests",
            dependencies: ["IoTWebhook"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
