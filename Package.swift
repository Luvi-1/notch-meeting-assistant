// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NotchMeetingAssistant",
    platforms: [.macOS("15.0")],
    products: [.executable(name: "NotchMeetingAssistant", targets: ["NotchMeetingAssistant"])],
    targets: [
        .target(name: "NotchCore"),
        .executableTarget(name: "NotchMeetingAssistant", dependencies: ["NotchCore"]),
        .testTarget(name: "NotchCoreTests", dependencies: ["NotchCore"])
    ],
    swiftLanguageVersions: [.v5]
)
