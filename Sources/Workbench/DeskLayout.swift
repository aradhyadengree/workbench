import Foundation
import CoreGraphics

/// Live Desk panes. Raw values are pane titles AND persisted in "deskLayout"; renaming one
/// drops that pane from users' saved layouts.
enum DeskTool: String, CaseIterable, Codable {
    case chat = "Terminal chat", phone = "Simulator", web = "Browser", shell = "Terminal", cases = "Test cases"

    var symbol: String {
        switch self {
        case .chat: "bubble.left.and.text.bubble.right"; case .phone: "iphone"; case .web: "globe"
        case .shell: "apple.terminal"; case .cases: "checklist"
        }
    }
}

struct DeskColumn: Codable, Equatable, Identifiable {
    var id = UUID()
    var tools: [DeskTool]
    var width: Double
}

struct DeskLayout: Codable, Equatable {
    var columns = [DeskColumn(tools: [.chat, .cases], width: 0.38), DeskColumn(tools: [.phone], width: 0.25),
                   DeskColumn(tools: [.web, .shell], width: 0.37)]
    var heights: [DeskTool: Double] = [.chat: 0.55, .cases: 0.45, .web: 0.58, .shell: 0.42]
    enum Edge: String, CaseIterable { case left, right, above, below }

    /// A test run: every pane you read or drive gets full height, side by side. The shell is
    /// hidden (Layout menu brings it back). The simulator column is narrowest because the
    /// device is portrait; the browser is widest because desktop sites need the room.
    static let testing = DeskLayout(columns: [
        DeskColumn(tools: [.chat], width: 0.24), DeskColumn(tools: [.cases], width: 0.27),
        DeskColumn(tools: [.phone], width: 0.19), DeskColumn(tools: [.web], width: 0.30),
    ])

    mutating func move(_ tool: DeskTool, beside other: DeskTool, edge: Edge) {
        guard tool != other, let from = columns.firstIndex(where: { $0.tools.contains(tool) }) else { return }
        columns[from].tools.removeAll { $0 == tool }
        if columns[from].tools.isEmpty { columns.remove(at: from) }
        guard let target = columns.firstIndex(where: { $0.tools.contains(other) }),
              let row = columns[target].tools.firstIndex(of: other) else { return }
        switch edge {
        case .above, .below:
            columns[target].tools.insert(tool, at: row + (edge == .below ? 1 : 0))
            heights[tool] = heights[other] ?? 1
        case .left, .right:
            let weight = columns.map(\.width).reduce(0,+) / Double(columns.count)
            columns.insert(DeskColumn(tools: [tool], width: weight), at: target + (edge == .right ? 1 : 0))
        }
    }

    func contains(_ tool: DeskTool) -> Bool { columns.contains { $0.tools.contains(tool) } }

    mutating func remove(_ tool: DeskTool) {
        for c in columns.indices { columns[c].tools.removeAll { $0 == tool } }
        columns.removeAll { $0.tools.isEmpty }
    }

    /// Where a re-shown pane goes: stacked under its usual neighbour, or its own column.
    static func home(of tool: DeskTool) -> DeskTool? {
        switch tool { case .cases: .chat; case .shell: .web; case .chat, .phone, .web: nil }
    }

    /// Shows a pane below `anchor` (or as a new last column if there is no anchor or it's hidden).
    mutating func show(_ tool: DeskTool, below anchor: DeskTool?) {
        guard !contains(tool) else { return }
        if let anchor, contains(anchor) {
            columns[columns.firstIndex { $0.tools.contains(anchor) }!].tools.append(tool)
            heights[tool] = heights[anchor] ?? 1
        } else {
            columns.append(DeskColumn(tools: [tool], width: columns.map(\.width).reduce(0,+) / Double(max(1, columns.count))))
        }
    }

    mutating func swap(_ first: DeskTool, _ second: DeskTool) {
        for c in columns.indices {
            columns[c].tools = columns[c].tools.map { $0 == first ? second : $0 == second ? first : $0 }
        }
        let old = heights[first]; heights[first] = heights[second]; heights[second] = old
    }

    // Reserve space for each pane’s controls, then distribute the remaining points.
    static func lengths(_ extent: CGFloat, weights: [Double], minimum: CGFloat) -> [CGFloat] {
        let available = max(0, extent - CGFloat(weights.count - 1) * 5)
        let base = min(minimum, available / CGFloat(weights.count))
        let extra = available - base * CGFloat(weights.count)
        let total = weights.reduce(0,+)
        return weights.map { base + extra * $0 / total }
    }
}
