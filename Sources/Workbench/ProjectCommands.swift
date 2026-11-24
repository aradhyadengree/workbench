// Shortcut chips under the Terminal pane, detected from the project's own files so a click runs
// what this project actually uses (pnpm dev, swift test, docker compose up…) rather than a fixed
// list. Detection only reads files in the project root; nothing is executed until clicked.

import Foundation

struct QuickCommand: Identifiable, Hashable {
    let command: String
    let icon: String
    var id: String { command }
}

enum ProjectCommands {
    /// At most this many chips, so the bar fits a narrow pane.
    static let limit = 7

    static func detect(in folder: URL) -> [QuickCommand] {
        let fm = FileManager.default
        func has(_ name: String) -> Bool { fm.fileExists(atPath: folder.appendingPathComponent(name).path) }
        var found: [QuickCommand] = []
        func add(_ command: String, _ icon: String) {
            if !found.contains(where: { $0.command == command }) { found.append(QuickCommand(command: command, icon: icon)) }
        }

        if let node = nodeCommands(in: folder, has: has) { node.forEach { add($0.command, $0.icon) } }
        if has("Package.swift") { add("swift build", "hammer"); add("swift test", "checkmark.circle") }
        if has("Cargo.toml") { add("cargo run", "play.fill"); add("cargo test", "checkmark.circle") }
        if has("go.mod") { add("go run .", "play.fill"); add("go test ./...", "checkmark.circle") }
        if has("uv.lock") { add("uv sync", "arrow.down.circle"); add("uv run pytest", "checkmark.circle") }
        if has("justfile") || has("Justfile") { add("just", "list.bullet") }
        else if has("Makefile") { add("make", "hammer") }
        if ["compose.yaml", "compose.yml", "docker-compose.yaml", "docker-compose.yml"].contains(where: has) {
            add("docker compose up -d", "shippingbox")
        }
        if fm.isExecutableFile(atPath: folder.appendingPathComponent("dev.sh").path) { add("./dev.sh", "play.circle") }
        if has(".git") { add("git status", "arrow.triangle.branch") }
        if found.isEmpty { add("ls -la", "list.bullet") }
        return Array(found.prefix(limit))
    }

    /// package.json scripts, run with the project's package manager.
    private static func nodeCommands(in folder: URL, has: (String) -> Bool) -> [QuickCommand]? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("package.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let manager = packageManager(declared: json["packageManager"] as? String, has: has)
        let scripts = (json["scripts"] as? [String: Any]).map { Array($0.keys) } ?? []
        // The scripts people run while testing, in the order they're reached for.
        let preferred = ["dev", "start", "test", "build", "lint", "typecheck", "check"]
        var chosen = preferred.filter(scripts.contains).prefix(4).map { $0 }
        if chosen.isEmpty { chosen = Array(scripts.sorted().prefix(3)) }
        var commands: [QuickCommand] = []
        if !has("node_modules") { commands.append(QuickCommand(command: manager + " install", icon: "arrow.down.circle")) }
        for script in chosen {
            // npm needs "run" except for its built-in start/test; pnpm, yarn and bun don't.
            let command = manager == "npm" && !["start", "test"].contains(script) ? "npm run \(script)" : "\(manager) \(script)"
            let icon = ["dev", "start"].contains(script) ? "play.fill"
                : script == "test" ? "checkmark.circle" : script == "build" ? "hammer" : "checklist"
            commands.append(QuickCommand(command: command, icon: icon))
        }
        return commands
    }

    /// `packageManager` ("pnpm@9.15.9") wins, then the lockfile, else npm.
    private static func packageManager(declared: String?, has: (String) -> Bool) -> String {
        if let name = declared?.split(separator: "@").first.map(String.init),
           ["pnpm", "yarn", "bun", "npm"].contains(name) { return name }
        if has("pnpm-lock.yaml") { return "pnpm" }
        if has("yarn.lock") { return "yarn" }
        if has("bun.lockb") || has("bun.lock") { return "bun" }
        return "npm"
    }
}
