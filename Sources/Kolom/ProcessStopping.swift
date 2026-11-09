import AppKit
import Darwin
import KolomCore

/// What a dashboard row can stop: an app (quit as from its own menu) or a set of
/// processes (a session, a bucket, one process). Only processes of the current user
/// outside macOS's folders qualify, and never Kolom or its recovery helper.
struct StopTarget {
    enum Kind {
        case app(NSRunningApplication)
        case processes([Int32])
    }
    let kind: Kind
    let name: String
    let count: Int
    /// Terminal sessions it ends (an idle group, a session), for the wording.
    let sessions: Int?

    init?(node: ProcessNode) {
        guard node.stoppable, !node.pids.isEmpty, node.kind != .system else { return nil }
        guard Set(node.pids).isDisjoint(with: Self.protectedPIDs()) else { return nil }
        name = node.title
        count = node.pids.count
        sessions = node.kind == .idle ? node.children.count : node.kind == .session ? 1 : nil
        if node.kind == .app, node.appID != nil, let pid = node.pid,
            let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy != .prohibited
        {
            kind = .app(app)
        } else {
            kind = .processes(node.pids)
        }
    }

    /// Kolom and anything running Kolom's executable (the recovery helper).
    static func protectedPIDs() -> Set<Int32> {
        var protected: Set<Int32> = [getpid(), 0, 1]
        if let own = Bundle.main.executableURL?.resolvingSymlinksInPath().path {
            var pids = [Int32](repeating: 0, count: 8192)
            let found = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
            for pid in pids.prefix(max(0, Int(found))) where pid > 0 {
                var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
                if proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0, String(cString: buffer) == own {
                    protected.insert(pid)
                }
            }
        }
        return protected
    }

    private var processesWord: String { count == 1 ? "process" : "\(count) processes" }

    func title(force: Bool) -> String {
        switch kind {
        case .app: return force ? "Force Quit \(name)" : "Quit \(name)"
        case .processes:
            if let sessions, sessions > 1 {
                return force ? "Force Stop \(sessions) Idle Sessions" : "Stop \(sessions) Idle Sessions"
            }
            return force ? "Force Stop \(processesWord)" : "Stop \(processesWord)"
        }
    }
    func button(force: Bool) -> String {
        switch kind {
        case .app: return force ? "Force Quit" : "Quit"
        case .processes: return force ? "Force Stop" : "Stop"
        }
    }
    func question(force: Bool) -> String {
        switch kind {
        case .app: return force ? "Force quit \(name)?" : "Quit \(name)?"
        case .processes:
            return count == 1 ? "\(force ? "Force stop" : "Stop") \(name)?" : "\(force ? "Force stop" : "Stop") \(name) (\(count) processes)?"
        }
    }
    func explanation(force: Bool) -> String {
        switch kind {
        case .app:
            return force
                ? "\(name) ends at once, as Force Quit in the Dock does. Unsaved work in it is lost."
                : "\(name) is asked to quit, as from its own menu. It may ask to save first."
        case .processes(let pids):
            let names = pids.prefix(6).map { "\(Self.name(of: $0)) (\($0))" }.joined(separator: ", ")
            let more = pids.count > 6 ? " and \(pids.count - 6) more" : ""
            let how =
                force
                ? "They end at once (SIGKILL). Unsaved work in them is lost."
                : "They are asked to stop as closing their terminal would: shells get SIGHUP, other programs SIGTERM. Programs may save first; Force Stop ends anything that stays."
            let tabs = sessions != nil ? "\n\nTheir terminal tabs stay open but show the session as ended; close them in the terminal app." : ""
            return "\(names)\(more).\n\n\(how)\(tabs)"
        }
    }

    /// Acts, then reports in a sentence once the processes had a moment to exit.
    func perform(force: Bool, completion: @escaping (String) -> Void) {
        let pids: [Int32]
        switch kind {
        case .app(let app):
            _ = force ? app.forceTerminate() : app.terminate()
            pids = [app.processIdentifier]
        case .processes(let list):
            // Children first, so a shell does not respawn or report what it started.
            pids = list.reversed()
            // An interactive shell ignores SIGTERM; a terminal closing sends it SIGHUP.
            for pid in pids { kill(pid, force ? SIGKILL : Self.isShell(pid) ? SIGHUP : SIGTERM) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + (force ? 0.5 : 2)) {
            let running = pids.filter { kill($0, 0) == 0 || errno == EPERM }
            if running.isEmpty {
                completion(
                    "\(name): \(force ? "ended" : "stopped")\(pids.count > 1 ? " (\(pids.count) processes)" : "")")
            } else if case .app = kind, !force {
                completion("\(name) has not quit yet; it may be asking to save. Force Quit ends it.")
            } else {
                completion(
                    "\(name): \(running.count) of \(pids.count) still running\(force ? "" : " · Force Stop ends them")")
            }
        }
    }

    static func isShell(_ pid: Int32) -> Bool {
        ["zsh", "bash", "fish", "sh", "tcsh", "ksh", "dash", "nu", "login"].contains(name(of: pid))
    }

    static func name(of pid: Int32) -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        return proc_name(pid, &buffer, UInt32(buffer.count)) > 0 ? String(cString: buffer) : "PID \(pid)"
    }
}
