import SwiftUI
import SimulatorHost

struct SimulatorDisplay: NSViewRepresentable {
    let host: WBDisplayHost
    func makeNSView(context: Context) -> WBDisplayHost { host }
    func updateNSView(_ view: WBDisplayHost, context: Context) {}
    static func dismantleNSView(_ view: WBDisplayHost, coordinator: ()) { view.detach() }

    @MainActor static func connect(_ identifier: String) async throws -> WBDisplayHost {
        guard let uuid = UUID(uuidString: identifier) else { throw failure("Invalid simulator identifier.") }
        let directory = try await Task.detached(priority: .userInitiated) {
            let task = Process(), pipe = Pipe()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            task.arguments = ["--find", "simctl"]
            task.standardOutput = pipe
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard task.terminationStatus == 0, path.hasSuffix("/usr/bin/simctl") else {
                throw failure("Select a full Xcode installation to run an embedded simulator.")
            }
            return String(path.dropLast("/usr/bin/simctl".count))
        }.value
        try Task.checkCancellation()
        var error: NSError?
        guard let device = WBDevice(uuid, directory, &error) else {
            throw error ?? failure("The simulator service could not find this device.")
        }

        // The adapter registers display ports asynchronously, including after bootstatus succeeds.
        for _ in 0..<50 {
            try Task.checkCancellation()
            if let screen = mainScreen(of: device as AnyObject) {
                return try WBDisplayHost(device: device, screen: screen)
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw failure("The device booted but its main display is unavailable. Try connecting again.")
    }

    private static func mainScreen(of device: AnyObject) -> NSObject? {
        guard var storage = WBCopyScreens(device) else { return nil }
        defer { WBReleaseScreens(storage) }
        // Borrow the framework’s native Swift Dictionary value while its storage is retained.
        return withUnsafePointer(to: &storage) { pointer in
            pointer.withMemoryRebound(to: [UInt32: NSObject].self, capacity: 1) { screens in
                screens.pointee.values.first { ($0.value(forKey: "isDefault") as? NSNumber)?.boolValue == true }
            }
        }
    }

    nonisolated private static func failure(_ description: String) -> NSError {
        NSError(domain: "Workbench.Simulator", code: 2, userInfo: [NSLocalizedDescriptionKey: description])
    }
}
