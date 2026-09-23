// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "DoubaoVoiceHelper",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "DoubaoVoiceHelperCore",
            targets: ["DoubaoVoiceHelperCore"]
        ),
        .executable(
            name: "DoubaoVoiceHelper",
            targets: ["DoubaoVoiceHelper"]
        ),
        .executable(
            name: "DoubaoVoiceHelperCoreTests",
            targets: ["DoubaoVoiceHelperCoreTests"]
        ),
    ],
    targets: [
        .target(
            name: "DoubaoVoiceHelperCore",
            path: "Sources/DoubaoVoiceHelperCore"
        ),
        .executableTarget(
            name: "DoubaoVoiceHelper",
            dependencies: ["DoubaoVoiceHelperCore"],
            path: "Sources/DoubaoVoiceHelper"
        ),
        .executableTarget(
            name: "DoubaoVoiceHelperCoreTests",
            dependencies: ["DoubaoVoiceHelperCore"],
            path: "Tests/DoubaoVoiceHelperCoreTests"
        ),
    ]
)
