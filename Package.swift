// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Pinna2HRTF",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "Pinna2HRTF", targets: ["Pinna2HRTF"])
    ],
    targets: [
        .executableTarget(
            name: "Pinna2HRTF",
            resources: [
                .copy("Resources")
            ]
        )
    ]
)
