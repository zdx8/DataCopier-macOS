// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DataCopier",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "DataCopier", targets: ["DataCopier"])
    ],
    targets: [
        .executableTarget(
            name: "DataCopier",
            path: "Sources/DataCopier",
            swiftSettings: [
                .unsafeFlags(["-parse-as-library"])
            ]
        )
    ]
)
