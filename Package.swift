// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SurfaceCoordinatorKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
        .visionOS(.v1),
    ],
    products: [
        .library(name: "SurfaceCoordinatorKit", targets: ["SurfaceCoordinatorKit"]),
    ],
    targets: [
        .target(name: "SurfaceCoordinatorKit"),
        .testTarget(
            name: "SurfaceCoordinatorKitTests",
            dependencies: ["SurfaceCoordinatorKit"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
