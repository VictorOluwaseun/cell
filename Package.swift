// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Cell",
    platforms: [.macOS(.v14)],
    products: [.library(name: "BatteryCore", targets: ["BatteryCore"])],
    targets: [
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3"),
        .target(name: "BatteryCore", dependencies: ["CSQLite"]),
        .testTarget(name: "BatteryCoreTests", dependencies: ["BatteryCore", "CSQLite"])
    ]
)
