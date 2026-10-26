import Foundation

/// Why window management is suspended. Suspension stops moving windows and
/// keeps the layout and recovery records; unlike a pause, it restores nothing,
/// and management resumes on its own when the reason ends. Only explicit
/// session signals suspend; a Space switch pauses and resumes on return.
public enum SuspensionReason: String, Codable {
    /// Sleep, screen lock, display sleep or fast user switching.
    case sessionInactive
}

/// Decides which managed windows missing from a discovery pass keep their place.
/// A missing window keeps its column while its app runs and its element is
/// valid: for as long as it is in native full screen, otherwise for `grace`
/// seconds (a transient Accessibility gap).
/// Closed windows are never kept, so they cannot come back.
public struct AbsenceTracker {
    public private(set) var missingSince: [String: Double] = [:]
    public init() {}
    public mutating func retained(
        previous: Set<String>, discovered: Set<String>, now: Double, grace: Double = 10,
        isAlive: (String) -> Bool, isFullScreen: (String) -> Bool
    ) -> Set<String> {
        var kept = Set<String>()
        for id in previous.subtracting(discovered) {
            guard isAlive(id) else {
                missingSince.removeValue(forKey: id)
                continue
            }
            let since = missingSince[id] ?? now
            missingSince[id] = since
            if isFullScreen(id) || now - since < grace { kept.insert(id) }
        }
        for id in Array(missingSince.keys) where discovered.contains(id) || !previous.contains(id) {
            missingSince.removeValue(forKey: id)
        }
        return kept
    }
}

/// Windows from the saved layout keep their place while Kolom starts. The first
/// passes can miss windows (apps slow to answer a new process, often right after
/// an update), and a window found later would otherwise join the end of the strip.
/// A saved window is held until it is found, its app quits, or `until` passes;
/// a busy app's windows stay held while it does not answer.
public struct StartupHold {
    public private(set) var waiting: Set<String>
    /// Saved windows let go without being found.
    public private(set) var dropped: Set<String> = []
    public let until: Double
    public init(_ saved: Set<String> = [], until: Double = 0) {
        waiting = saved
        self.until = until
    }
    public mutating func held(
        discovered: Set<String>, now: Double, isRunning: (String) -> Bool, isBusy: (String) -> Bool
    ) -> Set<String> {
        let missing = waiting.subtracting(discovered)
        waiting = missing.filter { isRunning($0) && (now < until || isBusy($0)) }
        dropped.formUnion(missing.subtracting(waiting))
        return waiting
    }
}

/// Windows Kolom parked off its strip, or that are briefly missing, can vanish
/// from enumeration. Keep still-existing ones; never retain closed windows.
public func reconcileRetainedWindows<T>(
    discovered: [String: T], previous: [String: T], hidden: Set<String>, isAlive: (T) -> Bool
) -> [String: T] {
    var result = discovered
    for id in hidden where result[id] == nil {
        if let window = previous[id], isAlive(window) { result[id] = window }
    }
    return result
}
