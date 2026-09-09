sed: --: No such file or directory
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WallpaperConverter",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "WallpaperConverter", targets: ["WallpaperConverter"])
    ],
    targets: [
        .executableTarget(
            name: "WallpaperConverter",
            path: "Sources/WallpaperConverter"
        )
    ]
)
