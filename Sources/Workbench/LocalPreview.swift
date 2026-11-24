import Foundation

/// Server banners may arrive in several PTY reads, including mid-escape or mid-port.
struct LocalPreviewDetector {
    private var partial = Data()
    private var skippingLongLine = false
    private static let ansi = try! NSRegularExpression(pattern: #"\x1b\[[0-?]*[ -/]*[@-~]"#)
    private static let address = try! NSRegularExpression(
        pattern: #"(?i)(?<![\w.@/:-])(?:https?://(?:localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1?\])(?::[0-9]{1,5})?|(?:localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1?\]):[0-9]{1,5})(?:[/?#][^\s\x00-\x1f<>"']*)?(?=$|[\s\x1b<>"'),;])"#)

    mutating func consume(_ bytes: ArraySlice<UInt8>) -> [URL] {
        var urls: [URL] = []
        for byte in bytes {
            if byte == 10 || byte == 13 {
                if !skippingLongLine && !partial.isEmpty {
                    urls += Self.urls(in: String(decoding: partial, as: UTF8.self))
                }
                partial.removeAll(keepingCapacity: true)
                skippingLongLine = false
            } else if !skippingLongLine {
                if partial.count < 8192 { partial.append(byte) }
                else { skippingLongLine = true }
            }
        }
        return urls
    }

    private static func urls(in line: String) -> [URL] {
        guard line.contains(":") else { return [] }
        let clean = ansi.stringByReplacingMatches(in: line, range: NSRange(line.startIndex..., in: line), withTemplate: "")
        return address.matches(in: clean, range: NSRange(clean.startIndex..., in: clean)).compactMap { match in
            var value = (clean as NSString).substring(with: match.range)
            if !value.contains("://") { value = "http://" + value }
            guard var parts = URLComponents(string: value), let host = parts.host?.lowercased(),
                  ["localhost", "127.0.0.1", "0.0.0.0", "[::1]", "[::]", "::1", "::"].contains(host),
                  (1...65535).contains(parts.port ?? 80) else { return nil }
            if ["0.0.0.0", "[::]", "::"].contains(host) { parts.host = "localhost" }
            if parts.path.isEmpty { parts.path = "/" }
            return parts.url
        }
    }
}
