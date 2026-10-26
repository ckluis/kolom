import CoreGraphics
import Foundation

/// One standard AX window of an app, in AX order, after duplicate elements are removed.
public struct WindowIdentityCandidate {
    public var frame: CGRect
    public var title: String
    /// The ID of an already-managed window whose AX element is this element.
    public var retainedID: String?
    /// Stable per-element fallback when no WindowServer row matches.
    public var fallbackKey: String
    public init(frame: CGRect, title: String, retainedID: String? = nil, fallbackKey: String) {
        self.frame = frame
        self.title = title
        self.retainedID = retainedID
        self.fallbackKey = fallbackKey
    }
}

/// One layer-0 WindowServer row owned by the same app.
public struct WindowServerRow {
    public var number: UInt32
    public var frame: CGRect?
    public var name: String?
    public init(number: UInt32, frame: CGRect?, name: String?) {
        self.number = number
        self.frame = frame
        self.name = name
    }
}

public struct WindowIdentity: Equatable {
    public var id: String
    /// Index into the rows passed to `assignWindowIdentities`, when one matched.
    public var row: Int?
}

/// The WindowServer number encoded in a Kolom window ID (`pid:number`).
public func windowServerNumber(fromID id: String, pid: Int32) -> UInt32? {
    let parts = id.split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count == 2, Int32(parts[0]) == pid else { return nil }
    return UInt32(parts[1])
}

/// Assign one ID per candidate. IDs are unique within the app and retained
/// windows keep their existing IDs. Retained windows claim their WindowServer
/// rows first, so a new window can never be matched to a retained window's row
/// and inherit its ID.
public func assignWindowIdentities(
    pid: Int32, candidates: [WindowIdentityCandidate], rows: [WindowServerRow], reserved: Set<String> = []
) -> [WindowIdentity] {
    var result = [WindowIdentity?](repeating: nil, count: candidates.count)
    var taken = Set<String>()
    var claimed = Set<String>()
    var usedRows = Set<Int>()
    for (index, candidate) in candidates.enumerated() {
        guard let id = candidate.retainedID, !claimed.contains(id) else { continue }
        claimed.insert(id)
        taken.insert(id)
        let number = windowServerNumber(fromID: id, pid: pid)
        let row = number.flatMap { n in rows.indices.first { rows[$0].number == n && !usedRows.contains($0) } }
        if let row { usedRows.insert(row) }
        result[index] = WindowIdentity(id: id, row: row)
    }
    // A retained window's ID and row stay reserved even when that window is
    // missing from this pass, so another window cannot take over its identity.
    taken.formUnion(reserved)
    for (index, row) in rows.enumerated() where taken.contains("\(pid):\(row.number)") { usedRows.insert(index) }
    for (index, candidate) in candidates.enumerated() where result[index] == nil {
        func distance(_ row: WindowServerRow) -> Double {
            guard let r = row.frame else { return .greatestFiniteMagnitude }
            let titlePenalty = row.name.map { $0 == candidate.title ? 0.0 : 10000.0 } ?? 0
            let value =
                abs(r.minX - candidate.frame.minX) + abs(r.minY - candidate.frame.minY)
                + abs(r.width - candidate.frame.width) + abs(r.height - candidate.frame.height) + titlePenalty
            return value.isFinite ? value : .greatestFiniteMagnitude
        }
        let row = rows.indices.filter { !usedRows.contains($0) }.min { distance(rows[$0]) < distance(rows[$1]) }
        var id = row.map { "\(pid):\(rows[$0].number)" } ?? "\(pid):\(candidate.fallbackKey)"
        if taken.contains(id) { id = "\(pid):\(candidate.fallbackKey)" }
        var suffix = 2
        let base = id
        while taken.contains(id) {
            id = "\(base)#\(suffix)"
            suffix += 1
        }
        if let row { usedRows.insert(row) }
        taken.insert(id)
        result[index] = WindowIdentity(id: id, row: row)
    }
    return result.map { $0! }
}

/// Build an ID-keyed dictionary without trapping on duplicate IDs. The first
/// occurrence wins, matching discovery order.
public func uniqueByID<T>(_ values: [T], id: (T) -> String) -> [String: T] {
    Dictionary(values.map { (id($0), $0) }, uniquingKeysWith: { first, _ in first })
}
