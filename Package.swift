// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Warden",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Warden", targets: ["Warden"]),
        .executable(name: "WardenBridge", targets: ["WardenBridge"]),
        .executable(name: "WardenPower", targets: ["WardenPower"]),
        .executable(name: "WardenWidgets", targets: ["WardenWidgets"])
    ],
    targets: [
        .target(name: "WardenCore"),
        .executableTarget(name: "Warden", dependencies: ["WardenCore"]),
        .executableTarget(name: "WardenBridge", dependencies: ["WardenCore"]),
        .executableTarget(name: "WardenPower", dependencies: ["WardenCore"]),
        // A WidgetKit extension: build-app.sh puts it in the app's PlugIns folder. Extensions start in the
        // system's extension stub, which then runs the widget bundle's @main.
        .executableTarget(name: "WardenWidgets", dependencies: ["WardenCore"],
                          swiftSettings: [.unsafeFlags(["-application-extension"])],
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-e", "-Xlinker", "_NSExtensionMain"])]),
        .testTarget(name: "WardenCoreTests", dependencies: ["WardenCore"])
    ]
)
