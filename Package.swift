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
            ?? .package(url: "https://github.com/xocialize-code/gaea-plugin-kit.git", from: "0.14.1"), // 0.14.1 on: the manifest names the engine actually linked (AB-L-0366)
        .package(url: "https://github.com/xocialize/boogu-image-swift.git", exact: "0.5.0"), // its newest; admits mlx-swift 0.33.x (ml-explore from 0.32.3)
        // mlx-engine-swift 0.82.1, the first on the fleet's mlx-swift 0.33.1.
        .package(url: "https://github.com/xocialize/mlx-engine-swift.git", from: "0.82.1"),
        // The fleet's mlx-swift fork, as mlx-engine-swift 0.82.1 takes it: 0.33.1 is upstream 0.33.0 with the vendored
        // MLX's head-dim-split SDPA routes off, which abort or give wrong attention on M5 (AB-D-0264, AB-R-1009). Named
        // at the root so no dependency's ml-explore URL wins and builds the unpatched one.
        .package(url: "https://github.com/xocialize/mlx-swift", from: "0.33.1"),
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
