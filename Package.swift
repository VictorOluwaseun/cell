// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Cell",
    platforms: [.macOS(.v14)],
    products: [.library(name: "BatteryCore", targets: ["BatteryCore"]),
               .executable(name: "CellChargeHelper", targets: ["CellChargeHelper"])],
    targets: [
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3"),
        .target(name: "BatteryCore", dependencies: ["CSQLite"]),
        .target(name: "CChargeControl", linkerSettings: [.linkedFramework("IOKit")]),
        .target(name: "ChargeIPC"),
        .target(name: "ChargeHardware", dependencies: ["CChargeControl", "BatteryCore"],
                linkerSettings: [.linkedFramework("IOKit")]),
        .executableTarget(name: "CellChargeHelper", dependencies: ["BatteryCore", "ChargeIPC", "ChargeHardware"],
                          linkerSettings: [.linkedFramework("IOKit")]),
        .testTarget(name: "BatteryCoreTests", dependencies: ["BatteryCore", "CChargeControl", "CSQLite"])
    ]
)
