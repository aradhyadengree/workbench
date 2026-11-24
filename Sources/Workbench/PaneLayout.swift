import CoreGraphics
import Foundation

enum ToolTab: String, CaseIterable, Codable {
    case claude = "Claude", editor = "Editor", files = "Files", terminal = "Terminal", browser = "Browser", simulator = "Simulator"

    var icon: String {
        switch self {
        case .claude: return "sparkles"
        case .editor: return "chevron.left.forwardslash.chevron.right"
        case .files: return "folder"
        case .terminal: return "terminal"
        case .browser: return "globe"
        case .simulator: return "iphone"
        }
    }
}

struct PaneGroup: Identifiable, Codable {
    var id = UUID()
    var tabs: [ToolTab]
    var selected: ToolTab
    init(_ tool: ToolTab) { tabs = [tool]; selected = tool }
}

struct PaneLayout: Codable {
    var groups: [PaneGroup] = [.init(.claude), .init(.editor), .init(.terminal)]
    var shares: [String: Double] = [:]

    func index(of tool: ToolTab) -> Int? { groups.firstIndex { $0.tabs.contains(tool) } }
    mutating func show(_ tool: ToolTab) {
        if let i = index(of: tool) { groups[i].selected = tool }
        else { groups.append(PaneGroup(tool)) }
    }
    mutating func remove(_ tool: ToolTab) {
        guard let i = index(of: tool), let j = groups[i].tabs.firstIndex(of: tool) else { return }
        groups[i].tabs.remove(at: j)
        if groups[i].tabs.isEmpty { groups.remove(at: i) }
        else if groups[i].selected == tool { groups[i].selected = groups[i].tabs[min(j, groups[i].tabs.count - 1)] }
    }
    mutating func move(_ tool: ToolTab, into id: UUID, before anchor: ToolTab? = nil) {
        guard groups.contains(where: { $0.id == id }), anchor != tool else { return }
        if let i = index(of: tool), groups[i].id == id {
            groups[i].tabs.removeAll { $0 == tool }
        } else { remove(tool) }
        guard let i = groups.firstIndex(where: { $0.id == id }) else { return }
        let j = anchor.flatMap { groups[i].tabs.firstIndex(of: $0) } ?? groups[i].tabs.count
        groups[i].tabs.insert(tool, at: j)
        groups[i].selected = tool
    }
    mutating func split(_ tool: ToolTab) {
        guard let i = index(of: tool), groups[i].tabs.count > 1 else { return }
        remove(tool)
        groups.insert(PaneGroup(tool), at: i + 1)
    }
    mutating func shift(_ id: UUID, by delta: Int) {
        guard let i = groups.firstIndex(where: { $0.id == id }), groups.indices.contains(i + delta) else { return }
        groups.swapAt(i, i + delta)
    }

    func division(_ items: [PaneGroup], in size: CGSize) -> (cut: Int, across: Bool, share: CGFloat, key: String) {
        let sidebar = items[0].tabs == [.files] && size.width >= 900
        let cut = sidebar ? 1 : (items.count + 1) / 2
        let editorAndShell = items.count == 2 && Set(items.map(\.selected)) == [.editor, .terminal]
        let across = sidebar || (!editorAndShell && size.width >= size.height * 1.65)
        let key = (across ? "x" : "y") + items.map { $0.id.uuidString }.joined()
        var share = CGFloat(cut) / CGFloat(items.count)
        if sidebar { share = 190 / size.width }
        else if editorAndShell { share = items[0].selected == .editor ? 0.70 : 0.30 }
        let extent = across ? size.width : size.height
        let minimum = min(0.45, (across ? 150 : 90) / max(1, extent))
        return (cut, across, min(1 - minimum, max(minimum, shares[key] ?? share)), key)
    }
}

struct PaneFrames {
    struct DividerLine: Identifiable {
        let id: String
        let rect: CGRect
        let across: Bool
        let extent: CGFloat
        let share: CGFloat
    }
    var panes: [UUID: CGRect] = [:]
    var dividers: [DividerLine] = []
    init(layout: PaneLayout, size: CGSize) {
        func place(_ groups: [PaneGroup], _ rect: CGRect) {
            guard let first = groups.first else { return }
            guard groups.count > 1 else { panes[first.id] = rect; return }
            let d = layout.division(groups, in: rect.size)
            let edge: CGRectEdge = d.across ? .minXEdge : .minYEdge
            let span = max(0, (d.across ? rect.width : rect.height) - 5)
            let parts = rect.divided(atDistance: (span * d.share).rounded(), from: edge)
            let remaining = parts.remainder.divided(atDistance: 5, from: edge)
            dividers.append(.init(id: d.key, rect: remaining.slice, across: d.across, extent: span, share: d.share))
            place(Array(groups.prefix(d.cut)), parts.slice)
            place(Array(groups.dropFirst(d.cut)), remaining.remainder)
        }
        place(layout.groups, CGRect(origin: .zero, size: size))
    }
}
