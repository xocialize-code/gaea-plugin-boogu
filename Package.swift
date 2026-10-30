// swift-tools-version: 6.2
import PackageDescription

// gaea-plugin-boogu: Boogu-Image 0.1 (Apache-2.0) as a Gaea plugin. One worker executable built on GaeaPluginKit over
// boogu-image-swift, packaged as a signed .gaeaplugin by scripts/build-plugin.sh.
//
// boogu-inproc is not part of the plugin: it runs the same package in-process through MLXServeEngine, with the same
// dependency resolution, as the reference a run through Gaea is compared against.
//
// GAEA_PLUGIN_KIT_PATH points the kit at a local checkout while you work on both.
let kitPath = Context.environment["GAEA_PLUGIN_KIT_PATH"]

let package = Package(
    name: "gaea-plugin-boogu",
    platforms: [.macOS(.v26)], // mlx-engine-swift's MLXToolKit requires macOS 26
    dependencies: [
        kitPath.map { .package(path: $0) }
            ?? .package(url: "https://github.com/xocialize-code/gaea-plugin-kit.git", from: "0.5.0"),
        .package(url: "https://github.com/xocialize/boogu-image-swift.git", exact: "0.5.0"),
        .package(url: "https://github.com/xocialize/mlx-engine-swift.git", from: "0.73.0"),
    ],
    targets: [
        .target(
            name: "BooguPlugin",
            dependencies: [
                .product(name: "GaeaPluginKit", package: "gaea-plugin-kit"),
                .product(name: "MLXBoogu", package: "boogu-image-swift"),
                .product(name: "MLXToolKit", package: "mlx-engine-swift"),
            ]
        ),
        .executableTarget(
            name: "gaea-boogu-worker",
            dependencies: [
                "BooguPlugin",
                .product(name: "GaeaPluginKit", package: "gaea-plugin-kit"),
            ]
        ),
        .executableTarget(
            name: "boogu-inproc",
            dependencies: [
                "BooguPlugin",
                .product(name: "MLXBoogu", package: "boogu-image-swift"),
                .product(name: "MLXToolKit", package: "mlx-engine-swift"),
                .product(name: "MLXServeCore", package: "mlx-engine-swift"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
