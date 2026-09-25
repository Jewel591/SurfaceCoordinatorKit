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
        .library(name: "SurfaceCoordinatorKitUI", targets: ["SurfaceCoordinatorKitUI"]),
    ],
    targets: [
        .target(name: "SurfaceCoordinatorKit"),
        .target(
            name: "SurfaceCoordinatorKitUI",
            dependencies: ["SurfaceCoordinatorKit"]
        ),
        .testTarget(
            name: "SurfaceCoordinatorKitTests",
            dependencies: ["SurfaceCoordinatorKit"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
