import Foundation

enum Verdict: String, Codable, CaseIterable {
    case untested = "Untested", passed = "Passed", failed = "Failed", blocked = "Blocked"
}

struct TestCheck: Codable, Identifiable {
    var id = UUID()
    var time = Date()
    let title: String
    let web: Verdict
    let mobile: Verdict
    let note: String
    let address: String
    let mobileTarget: String
}

struct TestRun: Codable {
    var address = ""
    var checks: [TestCheck] = []
    var report: String {
        let dates = ISO8601DateFormatter()
        return (["# Product test run", "\(checks.count) recorded checks"] + checks.map { check in
            """
            ## \(check.title)

            \(dates.string(from: check.time))

            - Web (\(check.address.isEmpty ? "No URL loaded" : check.address)) — \(check.web.rawValue)
            - Mobile (\(check.mobileTarget)) — \(check.mobile.rawValue)

            \(check.note)
            """
        }).joined(separator: "\n\n") + "\n"
    }
}
