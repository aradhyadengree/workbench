import Foundation

enum GitStatusType: String {
    case modified = "M"
    case untracked = "U"
    case staged = "A"
    case deleted = "D"
    case renamed = "R"
}

final class GitManager {
    static func currentBranch(in folder: URL) -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.currentDirectoryURL = folder
        process.arguments = ["rev-parse", "--abbrev-ref", "HEAD"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                let name = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                return name.isEmpty ? nil : name
            }
        } catch {}
        return nil
    }

    static func fileStatuses(in folder: URL) -> [String: GitStatusType] {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.currentDirectoryURL = folder
        process.arguments = ["status", "--porcelain=v1", "-z"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            if process.terminationStatus != 0 { return [:] }

            var result: [String: GitStatusType] = [:]
            let entries = data.split(separator: 0)
            for entry in entries {
                let str = String(decoding: entry, as: UTF8.self)
                guard str.count >= 3 else { continue }
                let x = str[str.startIndex]
                let y = str[str.index(after: str.startIndex)]
                let path = String(str.dropFirst(3))

                if x == "?" && y == "?" {
                    result[path] = .untracked
                } else if x == "A" || y == "A" {
                    result[path] = .staged
                } else if x == "D" || y == "D" {
                    result[path] = .deleted
                } else if x == "R" || y == "R" {
                    result[path] = .renamed
                } else if x == "M" || y == "M" {
                    result[path] = .modified
                }
            }
            return result
        } catch {
            return [:]
        }
    }
}
