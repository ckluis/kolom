import Foundation

/// Every Space of every display has its own strip, like another display: its own
/// columns, widths and order. The strip a display shows lives in Kolom's
/// workspaces; the strips of Spaces not shown wait here and swap in when their
/// Space is shown again. Their windows are left alone meanwhile.
public struct SpaceStrips: Codable, Equatable {
    /// What a display shows and has, from the WindowServer.
    public struct Shown: Equatable {
        public var current: UInt64
        /// Its Spaces in Mission Control order.
        public var ordered: [UInt64]
        public init(current: UInt64, ordered: [UInt64]) {
            self.current = current
            self.ordered = ordered.contains(current) ? ordered : ordered + [current]
        }
    }

    /// The Space each display shows.
    public private(set) var shown: [String: UInt64] = [:]
    /// Each display's Spaces in order, to follow a reconnect that renumbers them.
    public private(set) var order: [String: [UInt64]] = [:]
    /// Strips of Spaces not shown, by display and Space.
    public private(set) var stashed: [String: [UInt64: Workspace]] = [:]

    public init() {}

    public var isEmpty: Bool { shown.isEmpty }

    /// Windows waiting in strips not shown.
    public var elsewhere: Set<String> {
        Set(stashed.values.flatMap { $0.values.flatMap(\.windowIDs) })
    }

    /// The Space a waiting window's strip belongs to.
    public func space(of id: String) -> (display: String, space: UInt64)? {
        for (display, strips) in stashed {
            for (space, strip) in strips where strip.windowIDs.contains(id) { return (display, space) }
        }
        return nil
    }

    /// Starts from what each display shows; strips kept from before (a restart)
    /// stay for Spaces that still exist.
    public mutating func start(_ current: [String: Shown]) {
        for (display, now) in current {
            renumber(display, to: now)
            shown[display] = now.current
            order[display] = now.ordered
            stashed[display]?[now.current] = nil
        }
        prune()
    }

    /// Brings strips up to date with the Spaces shown. For each display whose Space
    /// changed, its strip in `workspaces` is put away and the shown Space's strip
    /// (empty if new) takes its place. Returns those displays. A display not listed
    /// (disconnected) keeps its strips for when it returns.
    @discardableResult
    public mutating func update(_ current: [String: Shown], workspaces: inout [String: Workspace]) -> Set<String> {
        var changed: Set<String> = []
        for (display, now) in current {
            renumber(display, to: now)
            defer { order[display] = now.ordered }
            guard let before = shown[display] else {
                // A display seen for the first time: it shows what it shows.
                shown[display] = now.current
                continue
            }
            guard before != now.current else { continue }
            // The shown Space is gone (removed, or renumbered with no way to match it):
            // the strip on screen is that same place; keep it.
            guard now.ordered.contains(before) else {
                shown[display] = now.current
                continue
            }
            let outgoing = workspaces[display] ?? Workspace()
            if !outgoing.windowIDs.isEmpty { stashed[display, default: [:]][before] = outgoing }
            workspaces[display] = stashed[display]?.removeValue(forKey: now.current) ?? Workspace()
            shown[display] = now.current
            changed.insert(display)
        }
        prune()
        return changed
    }

    /// Windows listed now are on a Space shown: they leave any waiting strip (a
    /// window moved there with Mission Control joins the strip it is in now).
    public mutating func claim(_ listed: Set<String>) {
        for (display, strips) in stashed {
            for (space, strip) in strips {
                let gone = Set(strip.windowIDs).intersection(listed)
                guard !gone.isEmpty else { continue }
                var kept = strip
                for id in gone { kept.remove(id) }
                stashed[display]?[space] = kept.windowIDs.isEmpty ? nil : kept
            }
        }
        prune()
    }

    /// Windows that closed leave their waiting strips.
    public mutating func drop(_ closed: Set<String>) { claim(closed) }

    public mutating func reset() { self = SpaceStrips() }

    /// A reconnect can renumber every Space of a display. With the same number of
    /// Spaces and none in common, they are matched by position.
    private mutating func renumber(_ display: String, to now: Shown) {
        guard let old = order[display], !old.isEmpty, old.count == now.ordered.count,
            Set(old).isDisjoint(with: now.ordered)
        else { return }
        let map = Dictionary(uniqueKeysWithValues: zip(old, now.ordered))
        if let s = shown[display], let mapped = map[s] { shown[display] = mapped }
        if let strips = stashed[display] {
            stashed[display] = Dictionary(
                strips.compactMap { key, value in map[key].map { ($0, value) } }, uniquingKeysWith: { a, _ in a })
        }
        order[display] = now.ordered
    }

    /// Strips of Spaces that no longer exist, and empty ones, are let go: their
    /// windows were moved by macOS and will be found where they are.
    private mutating func prune() {
        for (display, strips) in stashed {
            let known = Set(order[display] ?? [])
            let kept = strips.filter { (known.isEmpty || known.contains($0.key)) && !$0.value.windowIDs.isEmpty }
            stashed[display] = kept.isEmpty ? nil : kept
        }
    }
}
