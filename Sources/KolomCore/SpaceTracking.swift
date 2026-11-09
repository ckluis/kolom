import Foundation

/// Which Space Kolom manages on each display, and whether the user is there.
/// Kolom manages the Space each display showed when management started. On
/// another Space it waits (the layout stays as it is) and resumes on return.
public struct SpaceTracker: Equatable {
    public struct Display: Equatable {
        public var current: UInt64
        public var all: Set<UInt64>
        public init(current: UInt64, all: Set<UInt64>) {
            self.current = current
            self.all = all
        }
    }
    public enum Decision: Equatable {
        /// Every display shows its managed Space.
        case managed
        /// These displays show another Space while theirs still exists.
        case away([String])
    }

    /// The managed Space of each display.
    public private(set) var managed: [String: UInt64] = [:]
    public init() {}

    /// Starts managing what each display shows now.
    public mutating func start(_ current: [String: Display], displays: [String]) {
        managed = [:]
        for id in displays { if let d = current[id] { managed[id] = d.current } }
    }

    public mutating func reset() { managed = [:] }

    /// Judges the Spaces now shown. A display Kolom has not managed yet (one that
    /// just connected) and a display whose managed Space no longer exists (removed,
    /// or renumbered by a reconnect) adopt the Space they show, so Kolom never
    /// waits for a Space that cannot come back. Displays that left are forgotten.
    public mutating func judge(_ current: [String: Display], displays: [String]) -> Decision {
        let present = Set(displays)
        managed = managed.filter { present.contains($0.key) }
        var away: [String] = []
        for id in displays.sorted() {
            guard let shown = current[id] else { continue }
            guard let space = managed[id], shown.all.contains(space) else {
                managed[id] = shown.current
                continue
            }
            if shown.current != space { away.append(id) }
        }
        return away.isEmpty ? .managed : .away(away)
    }
}
