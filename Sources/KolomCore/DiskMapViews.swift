import Foundation

/// What tile areas measure in the Disk Map.
public enum DiskMeasure: String, CaseIterable, Codable {
    /// Bytes on disk (the default).
    case size
    /// Number of files: where the many small files are.
    case files
    /// Bytes, coloured by last write instead of kind.
    case age

    public var label: String {
        switch self {
        case .size: return "Size"
        case .files: return "Files"
        case .age: return "Age"
        }
    }

    public func value(_ node: DiskNode) -> Double {
        self == .files ? Double(max(0, node.files)) : Double(node.size)
    }
}

/// How long ago something was last written, in the steps the Age view colours.
public enum DiskAge: Int, CaseIterable {
    case week, month, quarter, year, older, unknown

    public static func of(_ modified: Double, now: Double = Date().timeIntervalSince1970) -> DiskAge {
        guard modified > 0 else { return .unknown }
        let days = (now - modified) / 86_400
        if days < 7 { return .week }
        if days < 31 { return .month }
        if days < 92 { return .quarter }
        if days < 366 { return .year }
        return .older
    }

    public var label: String {
        switch self {
        case .week: return "This week"
        case .month: return "This month"
        case .quarter: return "3 months"
        case .year: return "This year"
        case .older: return "Older"
        case .unknown: return "Unknown"
        }
    }
}

public enum DiskFilter {
    /// Nodes whose name contains `query` (case-insensitive), and every folder holding
    /// one, so a match deep inside keeps the path to it lit.
    public static func matches(in root: DiskNode, query: String) -> Set<ObjectIdentifier> {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return [] }
        var found: Set<ObjectIdentifier> = []
        var stack: [DiskNode] = [root]
        while let node = stack.popLast() {
            if node.role != .smallerFiles, node.name.lowercased().contains(needle) {
                var current: DiskNode? = node
                while let n = current, found.insert(ObjectIdentifier(n)).inserted { current = n.parent }
            }
            stack.append(contentsOf: node.children)
        }
        return found
    }
}

extension DiskNode {
    /// A dot-folder or dot-file (hidden by Finder).
    public var isHidden: Bool { role != .smallerFiles && name.hasPrefix(".") }

    /// The node at `path` beneath this one (this node's path is its name), if the
    /// scan kept it.
    public func find(path: String) -> DiskNode? {
        let base = self.path
        guard path == base || path.hasPrefix(base.hasSuffix("/") ? base : base + "/") else { return nil }
        let rest = path.dropFirst(base.count).split(separator: "/").map(String.init)
        var node: DiskNode? = self
        for name in rest { node = node?.child(named: name) }
        return node
    }
}
