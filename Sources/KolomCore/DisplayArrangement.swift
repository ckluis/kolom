import CoreGraphics
import Foundation

// Display staircase and pointer mapping adapted from Defi
// (https://github.com/qeude/Defi, MIT, © 2026 Quentin Eude; see THIRD-PARTY-NOTICES.md).
//
// Displays side by side share an edge, so a column scrolled past it would appear on
// the neighbor and has to be parked early. While Kolom manages windows, displays
// whose heights overlap are moved corner to corner (the staircase): no edge has a
// neighbor and columns slide off any edge. The user's arrangement (the desk) stays
// authoritative for pointer crossings and is restored on pause, quit or crash.

/// Technical coordinates only: displays keyed by CGDirectDisplayID, in global
/// top-left coordinates. Unchanged when no two displays overlap vertically.
public func isolatedDisplayArrangement(_ frames: [UInt32: CGRect], primary: UInt32) -> [UInt32: CGRect] {
    guard frames[primary] != nil, frames.count > 1 else { return frames }
    let vertical = frames.values.sorted { $0.minY < $1.minY }
    guard zip(vertical, vertical.dropFirst()).contains(where: { $0.maxY > $1.minY }) else { return frames }
    return displayStaircase(frames, primary: primary)
}

/// True for the shape Kolom applies; such frames are never taken as the user's desk.
public func isDisplayStaircase(_ frames: [UInt32: CGRect], primary: UInt32) -> Bool {
    frames.count > 1 && frames[primary] != nil && displayStaircase(frames, primary: primary) == frames
}

/// Widest first along x, each top at the previous bottom, anchored on the primary.
private func displayStaircase(_ frames: [UInt32: CGRect], primary: UInt32) -> [UInt32: CGRect] {
    let ordered = frames.keys.sorted {
        let a = frames[$0]!.width
        let b = frames[$1]!.width
        return a == b ? $0 < $1 : a > b
    }
    var result: [UInt32: CGRect] = [:]
    var x = 0.0
    var y = 0.0
    for (index, id) in ordered.enumerated() {
        let size = frames[id]!.size
        if index > 0 { y -= size.height }
        result[id] = CGRect(origin: CGPoint(x: x, y: y), size: size)
        x += size.width
    }
    let anchor = result[primary]!.origin
    let origin = frames[primary]!.origin
    return result.mapValues { $0.offsetBy(dx: origin.x - anchor.x, dy: origin.y - anchor.y) }
}

/// Where the pointer goes when it presses against a technical display edge that
/// has a neighbor on the desk: the same relative position across that desk edge.
/// Parts of an edge with no desk neighbor keep the pointer where it is.
public func displayPointerDestination(
    x: Double, y: Double, deltaX: Double, deltaY: Double, technical: [UInt32: CGRect], desk: [UInt32: CGRect]
) -> CGPoint? {
    guard technical != desk else { return nil }
    let ids = technical.keys.sorted()
    func containing(_ x: Double, _ y: Double) -> UInt32? {
        ids.first { technical[$0]!.contains(CGPoint(x: x, y: y)) }
    }
    // One event can overshoot into the gap between technical displays before macOS clamps it.
    let current = containing(x, y)
    guard let sourceID = current ?? containing(x - deltaX, y - deltaY), let source = technical[sourceID],
        let logical = desk[sourceID]
    else { return nil }
    let localX = x - source.minX
    let localY = y - source.minY
    enum Edge { case left, right, up, down }
    let edges: [(Edge, Bool)] = [
        (.left, localX <= 1 && deltaX < 0), (.right, localX >= source.width - 2 && deltaX > 0),
        (.up, localY <= 1 && deltaY < 0), (.down, localY >= source.height - 2 && deltaY > 0),
    ]
    for (edge, crossing) in edges where crossing {
        var edgeX = x
        var edgeY = y
        if current == nil {
            let previousX = x - deltaX
            let previousY = y - deltaY
            let fraction: Double
            switch edge {
            case .left: fraction = (source.minX - previousX) / deltaX
            case .right: fraction = (source.maxX - previousX) / deltaX
            case .up: fraction = (source.minY - previousY) / deltaY
            case .down: fraction = (source.maxY - previousY) / deltaY
            }
            guard (0...1).contains(fraction) else { continue }
            edgeX = previousX + deltaX * fraction
            edgeY = previousY + deltaY * fraction
            switch edge {
            case .left, .right: guard edgeY >= source.minY, edgeY < source.maxY else { continue }
            case .up, .down: guard edgeX >= source.minX, edgeX < source.maxX else { continue }
            }
        }
        let deskX = logical.minX + (edgeX - source.minX) / source.width * logical.width
        let deskY = logical.minY + (edgeY - source.minY) / source.height * logical.height
        for id in ids where id != sourceID {
            guard let target = desk[id], let native = technical[id] else { continue }
            let alongY = deskY >= target.minY && deskY < target.maxY
            let alongX = deskX >= target.minX && deskX < target.maxX
            let nativeY = native.minY + (deskY - target.minY) / target.height * native.height
            let nativeX = native.minX + (deskX - target.minX) / target.width * native.width
            switch edge {
            case .left where abs(target.maxX - logical.minX) <= 1 && alongY:
                return CGPoint(x: max(native.minX, native.maxX + min(localX, -3)), y: nativeY)
            case .right where abs(target.minX - logical.maxX) <= 1 && alongY:
                return CGPoint(x: min(native.maxX - 1, native.minX + max(localX - source.width, 2)), y: nativeY)
            case .up where abs(target.maxY - logical.minY) <= 1 && alongX:
                return CGPoint(x: nativeX, y: max(native.minY, native.maxY + min(localY, -3)))
            case .down where abs(target.minY - logical.maxY) <= 1 && alongX:
                return CGPoint(x: nativeX, y: min(native.maxY - 1, native.minY + max(localY - source.height, 2)))
            default: continue
            }
        }
    }
    return nil
}

/// The same rectangle in desk coordinates: moved with the technical display it
/// overlaps most. Recovery records use desk coordinates, because restoring
/// windows happens after the desk is back (pause) or macOS put it back (crash).
public func deskRect(_ rect: CGRect, technical: [UInt32: CGRect], desk: [UInt32: CGRect]) -> CGRect {
    guard technical != desk else { return rect }
    let area: (CGRect) -> Double = { r in
        let i = rect.intersection(r)
        return i.isNull ? 0 : Double(i.width * i.height)
    }
    let center = CGPoint(x: rect.midX, y: rect.midY)
    guard
        let id = technical.keys.sorted().max(by: { a, b in
            let (x, y) = (area(technical[a]!), area(technical[b]!))
            if x != y { return x < y }
            return !technical[a]!.contains(center) && technical[b]!.contains(center)
        }), let from = technical[id], let to = desk[id]
    else { return rect }
    return rect.offsetBy(dx: to.minX - from.minX, dy: to.minY - from.minY)
}

/// Owns only the temporary display configuration, never workspaces. Changes are
/// applied with `.forAppOnly`, so WindowServer restores the desk if Kolom exits.
public final class DisplayArrangement {
    public private(set) var desk: [UInt32: CGRect] = [:]
    public private(set) var applied: [UInt32: CGRect] = [:]
    public private(set) var status = "native"
    public var isolated: Bool { status == "isolated" && applied != desk }
    private var saved: [Set<UInt32>: [UInt32: CGRect]] = [:]
    private let read: () -> [UInt32: CGRect]
    private let write: ([UInt32: CGRect], CGConfigureOption) -> CGError
    private let primary: () -> UInt32
    private let mirrored: (UInt32) -> Bool
    private let stateURL: URL?
    private let sessionID: String?
    private var stored: Stored?

    struct Stored: Codable, Equatable {
        var version = 1
        let sessionID: String
        let technical: [String: CGRect]
        let desk: [String: CGRect]
    }

    public init(
        read: @escaping () -> [UInt32: CGRect], write: @escaping ([UInt32: CGRect], CGConfigureOption) -> CGError,
        primary: @escaping () -> UInt32, mirrored: @escaping (UInt32) -> Bool = { _ in false },
        stateURL: URL? = nil, sessionID: String? = nil
    ) {
        self.read = read
        self.write = write
        self.primary = primary
        self.mirrored = mirrored
        self.stateURL = stateURL
        self.sessionID = sessionID
        if let stateURL, let data = try? Data(contentsOf: stateURL),
            let value = try? JSONDecoder().decode(Stored.self, from: data), value.version == 1,
            value.sessionID == sessionID,
            value.desk.values.allSatisfy({ $0.width > 0 && $0.height > 0 && $0.minX.isFinite && $0.minY.isFinite })
        {
            stored = value
        }
    }

    /// Applies the staircase for the current displays, learning the desk from any
    /// arrangement that is not Kolom's own. Returns true when display geometry
    /// changed, so callers relayout once the change is reported.
    @discardableResult public func reconcile() -> Bool {
        let current = read()
        let primary = primary()
        guard current.count > 1, let primaryFrame = current[primary] else {
            applied = current
            desk = current
            status = "native"
            return false
        }
        defer { save() }
        // A display-mode change can commit Kolom's staircase to the session; recover
        // only Kolom's exact last geometry. A new native arrangement wins.
        if applied.isEmpty, let stored, decode(stored.technical) == current,
            Set(decode(stored.desk).keys) == Set(current.keys),
            !isDisplayStaircase(decode(stored.desk), primary: primary)
        {
            desk = decode(stored.desk)
            applied = current
            saved[Set(current.keys)] = desk
        }
        if current == applied, !desk.isEmpty {
            status = current == desk ? "native" : "isolated"
            return false
        }
        let ids = Set(current.keys)
        let same = ids == Set(applied.keys)
        let resized = same && current.contains { applied[$0.key]?.size != $0.value.size }
        let shift = CGPoint(
            x: primaryFrame.minX - (applied[primary]?.minX ?? 0), y: primaryFrame.minY - (applied[primary]?.minY ?? 0))
        let translated =
            same
            && current.allSatisfy {
                $0.value.minX - applied[$0.key]!.minX == shift.x && $0.value.minY - applied[$0.key]!.minY == shift.y
            }
        // Resolution and main-display changes keep the desk; a new native
        // arrangement of the same displays is the user's.
        if !same, let known = saved[ids] {
            desk = known
        } else if desk.isEmpty || (!resized && !translated) {
            desk = deskFor(current, primary: primary)
        }
        if let anchor = desk[primary]?.origin {
            desk = desk.mapValues { $0.offsetBy(dx: -anchor.x, dy: -anchor.y) }
        }
        guard !desk.isEmpty else {
            applied = current
            status = "ambiguous"
            return false
        }
        saved[ids] = desk
        guard !current.keys.contains(where: mirrored) else {
            applied = current
            status = "native"
            return false
        }
        let desired = isolatedDisplayArrangement(current, primary: primary)
        guard desired != current else {
            applied = current
            status = current == desk ? "native" : "isolated"
            return false
        }
        let result = write(desired, .forAppOnly)
        let observed = read()
        guard result == .success, observed == desired else {
            // Never map the pointer against geometry macOS did not accept.
            if observed != current { _ = write(current, .forAppOnly) }
            applied = read()
            desk = deskFor(applied, primary: primary)
            status =
                desk.isEmpty ? "ambiguous" : result == .success ? "observation-mismatch" : "failed:\(result.rawValue)"
            return observed != current
        }
        applied = observed
        status = "isolated"
        return true
    }

    /// Puts the desk back. Returns true when display geometry changed.
    @discardableResult public func restore() -> Bool {
        let current = read()
        defer {
            applied = [:]
            status = "native"
        }
        // Never undo a newer arrangement made after the last reconciliation.
        guard !desk.isEmpty, current == applied, Set(current.keys) == Set(desk.keys), current != desk else {
            return false
        }
        // Absolute desk origins: the desk is stored relative to the primary at (0, 0).
        let result = write(desk, .forAppOnly)
        if result != .success || read() != desk {
            // The staircase may have been committed to the session (a display-mode change).
            _ = write(desk, .forSession)
        }
        return true
    }

    /// Desk crossing maps for the pointer router; equal maps mean no routing.
    public var pointerMaps: (technical: [UInt32: CGRect], desk: [UInt32: CGRect]) {
        isolated ? (applied, desk) : ([:], [:])
    }

    private func deskFor(_ frames: [UInt32: CGRect], primary: UInt32) -> [UInt32: CGRect] {
        guard isDisplayStaircase(frames, primary: primary) else { return frames }
        let candidates = [desk, stored.map { decode($0.desk) } ?? [:]]
        return candidates.first { Set($0.keys) == Set(frames.keys) && !isDisplayStaircase($0, primary: primary) } ?? [:]
    }
    private func decode(_ frames: [String: CGRect]) -> [UInt32: CGRect] {
        Dictionary(uniqueKeysWithValues: frames.compactMap { key, value in UInt32(key).map { ($0, value) } })
    }
    private func save() {
        guard let stateURL, let sessionID else { return }
        let encode: ([UInt32: CGRect]) -> [String: CGRect] = {
            Dictionary(uniqueKeysWithValues: $0.map { (String($0.key), $0.value) })
        }
        let value = Stored(sessionID: sessionID, technical: encode(applied), desk: encode(desk))
        guard value != stored else { return }
        try? FileManager.default.createDirectory(
            at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if (try? JSONEncoder().encode(value).write(to: stateURL, options: .atomic)) != nil { stored = value }
    }
}
