// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "CPaste",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "CPasteCore", targets: ["CPasteCore"]),
        .executable(name: "CPaste", targets: ["CPaste"]),
        .executable(name: "CPasteCoreChecks", targets: ["CPasteCoreChecks"])
    ],
    targets: [
        .target(name: "CPasteCore"),
        .executableTarget(
            name: "CPaste",
            dependencies: ["CPasteCore"]
        ),
        .executableTarget(
            name: "CPasteCoreChecks",
            dependencies: ["CPasteCore"]
        )
    ]
)
