// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SQLiteVecKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "SQLiteVecStore", targets: ["SQLiteVecStore"]),
    ],
    targets: [
        .target(
            name: "CSQLiteVec",
            path: "Sources/CSQLiteVec",
            // sqlite-vec.c is compiled only through SQLiteVecShim.c, which
            // enables the NEON fast paths on arm64 without editing upstream.
            // checksums.lock/LICENSE-MIT/LICENSE-APACHE are vendoring/licensing
            // artifacts, not source -- excluded to avoid SwiftPM's "unhandled
            // file(s)" warning.
            exclude: ["sqlite-vec.c", "checksums.lock", "LICENSE-MIT", "LICENSE-APACHE"],
            sources: ["SQLiteVecShim.c", "SQLiteVecBootstrap.c"],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("."),
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),
        .target(
            name: "SQLiteVecStore",
            dependencies: ["CSQLiteVec"]
        ),
        .testTarget(
            name: "SQLiteVecStoreTests",
            dependencies: ["SQLiteVecStore", "CSQLiteVec"]
        ),
        .testTarget(
            name: "CSQLiteVecTests",
            dependencies: ["CSQLiteVec"]
        ),
    ]
)
