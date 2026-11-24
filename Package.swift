// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Workbench",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "ShellPTY"),
        .target(name: "SimulatorHost"),
        .executableTarget(name: "Workbench", dependencies: ["ShellPTY", "SimulatorHost"], resources: [.copy("ChatTerminal")])
    ]
)
