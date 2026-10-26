/// Launch/reopen intent survives permission checks and asynchronous recovery.
/// Explicit Pause cancels a pending start; failed recovery never enables tiling.
public final class StartupSequence {
    public var requested = true
    public private(set) var inProgress = false
    public init() {}
    public func attempt(
        authorized: Bool, enabled: Bool, needsRecovery: Bool,
        recover: (@escaping (Bool) -> Void) -> Void,
        enable: @escaping () -> Void, blocked: @escaping () -> Void
    ) {
        guard requested, authorized, !enabled, !inProgress else { return }
        inProgress = true
        var completed = false
        let finish: (Bool) -> Void = { [weak self] recovered in
            guard let self, !completed else { return }
            completed = true
            self.inProgress = false
            guard self.requested else { return }
            self.requested = false
            if recovered { enable() } else { blocked() }
        }
        if needsRecovery { recover(finish) } else { finish(true) }
    }
}
