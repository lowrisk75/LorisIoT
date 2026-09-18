// swift-tools-version: 6.0
import PackageDescription

// LorisIoT — shared IoT framework for LorisLabs Apple apps (internal / all-rights-reserved).
// v1: dependency-free IoTCore. Provider satellites (IoTHomeAssistant, IoTShelly, …) are added as
// separate targets depending only on IoTCore. See ~/GitHub/iot-framework/IoTKit-DESIGN.md.
let package = Package(
    name: "LorisIoT",
    defaultLocalization: "en",
    platforms: [.iOS(.v17), .macOS(.v14), .watchOS(.v10), .tvOS(.v17), .visionOS(.v1)],
    products: [
        .executable(name: "IoTBench", targets: ["IoTBench"]),
        .executable(name: "IoTDemo", targets: ["IoTDemo"]),
        .library(name: "IoTUI", targets: ["IoTUI"]),
        .library(name: "IoTCore", targets: ["IoTCore"]),
        .library(name: "IoTHomeAssistant", targets: ["IoTHomeAssistant"]),
        .library(name: "IoTShelly", targets: ["IoTShelly"]),
        .library(name: "IoTGovee", targets: ["IoTGovee"]),
        .library(name: "IoTMeross", targets: ["IoTMeross"]),
        .library(name: "IoTMQTT", targets: ["IoTMQTT"]),
        // Real broker transport (CocoaMQTT, research #18) — isolated so IoTMQTT stays dep-free.
        .library(name: "IoTMQTTCocoa", targets: ["IoTMQTTCocoa"]),
        .library(name: "IoTWebhook", targets: ["IoTWebhook"]),
        .library(name: "IoTHomeKit", targets: ["IoTHomeKit"]),
    ],
    dependencies: [
        // Locked by research #18 (battle-tested MQTT 5.0, Swift 6-clean). Wrapped — CocoaMQTT
        // types never cross the IoTMQTTCocoa boundary, so the lib stays swappable.
        .package(url: "https://github.com/emqx/CocoaMQTT", from: "2.4.0"),
    ],
    targets: [
        .target(name: "IoTGovee", dependencies: ["IoTCore"], swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "IoTGoveeTests", dependencies: ["IoTGovee"], swiftSettings: [.swiftLanguageMode(.v6)]),
        .target(name: "IoTMeross", dependencies: ["IoTCore"], swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "IoTMerossTests", dependencies: ["IoTMeross"], swiftSettings: [.swiftLanguageMode(.v6)]),
        .executableTarget(name: "IoTBench", dependencies: ["IoTCore", "IoTHomeAssistant"],
                          path: "Examples/IoTBench", swiftSettings: [.swiftLanguageMode(.v6)]),
        .executableTarget(name: "IoTDemo", dependencies: ["IoTUI", "IoTShelly", "IoTGovee", "IoTHomeAssistant", "IoTMQTTCocoa"],
                          path: "Examples/IoTDemo", swiftSettings: [.swiftLanguageMode(.v6)]),
        .target(name: "IoTUI", dependencies: ["IoTCore"],
                resources: [.process("Resources")], swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "IoTUITests", dependencies: ["IoTUI"], swiftSettings: [.swiftLanguageMode(.v6)]),
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
        // Transport-injectable mapping/provider — no broker lib here (unit-testable with mocks).
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
        // CocoaMQTT-backed MQTTTransport. Apps that don't use MQTT never link CocoaMQTT.
        .target(
            name: "IoTMQTTCocoa",
            dependencies: [
                "IoTMQTT",
                .product(name: "CocoaMQTT", package: "CocoaMQTT"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("StrictConcurrency"),
            ]
        ),
        .testTarget(
            name: "IoTMQTTCocoaTests",
            dependencies: ["IoTMQTTCocoa"],
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
        // HomeKit is device-gated (HMTimerTrigger fires on the home hub; not testable in the sim/host).
        .target(
            name: "IoTHomeKit",
            dependencies: ["IoTCore"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("StrictConcurrency"),
            ]
        ),
        .testTarget(
            name: "IoTHomeKitTests",
            dependencies: ["IoTHomeKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
