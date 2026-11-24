import Foundation
import CoreGraphics

enum DeskTool: String, CaseIterable, Codable {
    case chat = "Terminal chat", phone = "Simulator", web = "Browser", shell = "Terminal"
}

struct DeskColumn: Codable, Equatable, Identifiable {
    var id = UUID()
    var tools: [DeskTool]
    var width: Double
}

struct DeskLayout: Codable, Equatable {
    var columns = [DeskColumn(tools: [.chat], width: 0.38), DeskColumn(tools: [.phone], width: 0.25),
                   DeskColumn(tools: [.web, .shell], width: 0.37)]
    var heights: [DeskTool: Double] = [.web: 0.58, .shell: 0.42]
    enum Edge: String, CaseIterable { case left, right, above, below }

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
