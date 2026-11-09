import Foundation

/// One process as the performance sampler read it.
public struct ProcessSample {
    /// "pid:start", unique even when a pid is reused.
    public var id: String
    public var pid: Int32
    /// The parent pid, 0 when unreadable.
    public var parent: Int32
    /// The process macOS holds responsible for this one (what Activity Monitor groups by):
    /// the terminal for a shell, Safari for its web content. nil when unknown.
    public var responsible: Int32?
    public var name: String
    public var path: String
    /// The working directory, when readable.
    public var directory: String?
    /// A macOS service: a system account, or an executable in the system's own folders.
    public var system: Bool
    public var cpu: Double?
    public var gpu: Double?
    public var memory: Double?
    public init(
        id: String, pid: Int32, parent: Int32, responsible: Int32?, name: String, path: String, directory: String?,
        system: Bool, cpu: Double?, gpu: Double?, memory: Double?
    ) {
        self.id = id
        self.pid = pid
        self.parent = parent
        self.responsible = responsible
        self.name = name
        self.path = path
        self.directory = directory
        self.system = system
        self.cpu = cpu
        self.gpu = gpu
        self.memory = memory
    }

    /// Executables in these folders belong to macOS. /bin and /usr/bin are left out:
    /// shells and tools there are the user's own work.
    public static let systemFolders = ["/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/", "/Library/Apple/"]
    public static func isSystem(path: String, uid: UInt32) -> Bool {
        uid < 500 || systemFolders.contains { path.hasPrefix($0) }
    }
}

/// A running app, the owner processes are attributed to.
public struct ProcessOwnerApp {
    public var pid: Int32
    public var path: String
    public var id: String
    public var name: String
    public init(pid: Int32, path: String, id: String, name: String) {
        self.pid = pid
        self.path = path
        self.id = id
        self.name = name
    }
}

/// A row of the performance table: an app, a session inside it, a group of alike
/// processes, or one process. Totals cover every process beneath it.
public struct ProcessNode: Identifiable {
    public enum Kind: Equatable { case app, system, session, bucket, process }
    public var id: String
    public var kind: Kind
    public var title: String
    public var detail: String
    /// The app's bundle id, for its icon; nil below the top level.
    public var appID: String?
    public var pid: Int32?
    /// Indent inside an unfolded session (child processes of a shell).
    public var depth = 0
    public var count: Int
    public var cpu: Double?
    public var gpu: Double?
    public var memory: Double?
    public var children: [ProcessNode]
    /// Lowercased names, folders and pids of everything beneath, for the filter.
    public var searchText: String
    public var cpuHistory = ResourceHistory()
    public var gpuHistory = ResourceHistory()
    public var memoryHistory = ResourceHistory()

    public func matches(_ query: String) -> Bool {
        query.isEmpty || searchText.contains(query.lowercased())
    }
}

public enum ProcessGrouping {
    public static let systemID = "system"
    private enum Owner: Hashable {
        case app(String)
        case system
        case root(Int32)
    }

    /// Groups processes under the app that is responsible for them, then by session.
    /// `home` shortens folders to "~/…".
    public static func tree(_ samples: [ProcessSample], apps: [ProcessOwnerApp], home: String) -> [ProcessNode] {
        var byPID: [Int32: ProcessSample] = [:]
        for sample in samples { byPID[sample.pid] = sample }
        var appByPID: [Int32: ProcessOwnerApp] = [:]
        for app in apps { appByPID[app.pid] = app }
        let bundled = apps.filter { !$0.path.isEmpty }
        func bundleOwner(_ path: String) -> ProcessOwnerApp? {
            bundled.filter { path.hasPrefix($0.path + "/") }.max { $0.path.count < $1.path.count }
        }

        var resolved: [Int32: Owner] = [:]
        var visiting: Set<Int32> = []
        // An app claims a process directly, by bundle, by responsibility or by ancestry;
        // otherwise it is a macOS service or heads (or joins) its own group.
        func appOwner(_ pid: Int32) -> String? {
            if let owner = resolve(pid), case .app(let id) = owner { return id }
            return nil
        }
        func resolve(_ pid: Int32) -> Owner? {
            if let known = resolved[pid] { return known }
            guard let sample = byPID[pid], !visiting.contains(pid) else { return nil }
            visiting.insert(pid)
            defer { visiting.remove(pid) }
            var owner: Owner
            if let app = appByPID[pid] ?? bundleOwner(sample.path) {
                owner = .app(app.id)
            } else if let r = sample.responsible, r > 1, r != pid, let app = appByPID[r] ?? byPID[r].flatMap({ bundleOwner($0.path) }) {
                owner = .app(app.id)
            } else if sample.parent > 1, sample.parent != pid, let id = appOwner(sample.parent) {
                owner = .app(id)
            } else if let r = sample.responsible, r > 1, r != pid, let id = appOwner(r) {
                owner = .app(id)
            } else if sample.system {
                owner = .system
            } else if let r = sample.responsible, r > 1, r != pid, let other = resolve(r) {
                owner = other
            } else if sample.parent > 1, sample.parent != pid, let other = resolve(sample.parent), other != .system {
                owner = other
            } else {
                owner = .root(pid)
            }
            resolved[pid] = owner
            return owner
        }

        var members: [Owner: [ProcessSample]] = [:]
        for sample in samples {
            members[resolve(sample.pid) ?? .root(sample.pid), default: []].append(sample)
        }
        let appByID = Dictionary(apps.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var nodes: [ProcessNode] = []
        for (owner, group) in members {
            switch owner {
            case .app(let id):
                let app = appByID[id]!
                let entries = sessions(group, groupID: id, mainPID: app.pid, home: home)
                nodes.append(
                    total(
                        id: id, kind: .app, title: app.name,
                        detail: group.count == 1 ? "PID \(group[0].pid)" : "\(group.count) processes", appID: id,
                        pid: group.count == 1 ? group[0].pid : nil, children: group.count == 1 ? [] : entries,
                        processes: group, home: home))
            case .system:
                let entries = buckets(group.map { leaf($0, groupID: systemID, depth: 0, home: home) }, groupID: systemID)
                nodes.append(
                    total(
                        id: systemID, kind: .system, title: "macOS",
                        detail: "\(group.count) background services", appID: nil, pid: nil, children: entries,
                        processes: group, home: home))
            case .root(let pid):
                let head = byPID[pid]!
                if group.count == 1 {
                    var node = leaf(head, groupID: "", depth: 0, home: home)
                    node.id = "process:" + head.id
                    nodes.append(node)
                } else {
                    let id = "process:" + head.id
                    nodes.append(
                        total(
                            id: id, kind: .app, title: head.name, detail: "\(group.count) processes", appID: nil,
                            pid: nil, children: sessions(group, groupID: id, mainPID: pid, home: home),
                            processes: group, home: home))
                }
            }
        }
        return nodes
    }

    /// The second level: the app's own process, then each subtree it started (a
    /// terminal's shells), with alike leftovers (Safari's web content) gathered.
    static func sessions(_ group: [ProcessSample], groupID: String, mainPID: Int32, home: String) -> [ProcessNode] {
        let pids = Set(group.map(\.pid))
        var children: [Int32: [ProcessSample]] = [:]
        for sample in group where pids.contains(sample.parent) && sample.parent != sample.pid {
            children[sample.parent, default: []].append(sample)
        }
        var roots = group.filter { !pids.contains($0.parent) || $0.parent == $0.pid }
        // The app's own process stays a single row; what it started becomes sessions.
        var entries: [ProcessNode] = []
        if let main = roots.firstIndex(where: { $0.pid == mainPID }) {
            let sample = roots.remove(at: main)
            var node = leaf(sample, groupID: groupID, depth: 0, home: home)
            node.detail = "Main process · " + node.detail
            entries.append(node)
            roots.insert(contentsOf: children[sample.pid] ?? [], at: 0)
        }
        var singles: [ProcessNode] = []
        for root in roots {
            var subtree: [(ProcessSample, Int)] = []
            var seen: Set<Int32> = []
            func walk(_ sample: ProcessSample, _ depth: Int) {
                guard seen.insert(sample.pid).inserted else { return }
                subtree.append((sample, depth))
                for child in (children[sample.pid] ?? []).sorted(by: { $0.pid < $1.pid }) { walk(child, depth + 1) }
            }
            walk(root, 0)
            if subtree.count == 1 {
                singles.append(leaf(root, groupID: groupID, depth: 0, home: home))
                continue
            }
            // A terminal's login wrapper says nothing; name the session after the shell under it.
            let head = subtree.first { $0.0.name != "login" }?.0 ?? root
            let others = subtree.map(\.0).filter { $0.pid != head.pid && $0.name != "login" }
            var names: [String] = []
            for sample in others where !names.contains(displayName(sample)) { names.append(displayName(sample)) }
            let folder = head.directory.map { abbreviate($0, home: home) }
            let name = displayName(head)
            let title = folder.flatMap { $0 == "~" || $0 == "/" ? nil : "\(name) · \(lastComponent($0))" } ?? name
            var detail = [folder, "\(subtree.count) processes"].compactMap { $0 }.joined(separator: " · ")
            if !names.isEmpty {
                detail += " · " + names.prefix(3).joined(separator: ", ") + (names.count > 3 ? " +\(names.count - 3)" : "")
            }
            entries.append(
                total(
                    id: "\(groupID)/session:\(root.id)", kind: .session, title: title, detail: detail, appID: nil, pid: nil,
                    children: subtree.map { leaf($0.0, groupID: groupID, depth: $0.1, home: home) },
                    processes: subtree.map(\.0), home: home))
        }
        return entries + buckets(singles, groupID: groupID)
    }

    /// Gathers single processes that share a name ("Safari Web Content" ×12).
    static func buckets(_ leaves: [ProcessNode], groupID: String) -> [ProcessNode] {
        var order: [String] = []
        var byName: [String: [ProcessNode]] = [:]
        for node in leaves {
            if byName[node.title] == nil { order.append(node.title) }
            byName[node.title, default: []].append(node)
        }
        return order.flatMap { name -> [ProcessNode] in
            let alike = byName[name]!
            guard alike.count > 1 else { return alike }
            var node = ProcessNode(
                id: "\(groupID)/bucket:\(name)", kind: .bucket, title: name, detail: "\(alike.count) processes",
                count: alike.count, cpu: sum(alike.map(\.cpu)), gpu: sum(alike.map(\.gpu)),
                memory: sum(alike.map(\.memory)), children: alike,
                searchText: alike.map(\.searchText).joined(separator: " "))
            if name == webContentName {
                node.detail += " · tabs, frames and extensions; macOS does not say which tab each one is"
            }
            return [node]
        }
    }

    static let friendlyNames = [
        "com.apple.WebKit.WebContent": "Web Content",
        "com.apple.WebKit.Networking": "Web Networking",
        "com.apple.WebKit.GPU": "Web Graphics",
    ]
    static let webContentName = "Web Content"

    /// What to call a process. Some tools install one executable per version
    /// (…/claude/versions/2.1.316); those are named after the tool.
    public static func displayName(_ sample: ProcessSample) -> String {
        if let friendly = friendlyNames[sample.name] { return friendly }
        guard sample.name.contains("."), sample.name.allSatisfy({ $0.isNumber || $0 == "." }) else { return sample.name }
        var folders = sample.path.split(separator: "/").dropLast()
        if folders.last == "versions" { folders = folders.dropLast() }
        guard let tool = folders.last, !tool.hasPrefix(".") else { return sample.name }
        return "\(tool) \(sample.name)"
    }

    static func leaf(_ sample: ProcessSample, groupID: String, depth: Int, home: String) -> ProcessNode {
        let folder = sample.directory.flatMap { $0 == "/" ? nil : abbreviate($0, home: home) }
        let title = displayName(sample)
        return ProcessNode(
            id: "\(groupID)/\(sample.id)", kind: .process, title: title,
            detail: (["PID \(sample.pid)"] + [folder].compactMap { $0 }).joined(separator: " · "), pid: sample.pid,
            depth: depth, count: 1, cpu: sample.cpu, gpu: sample.gpu, memory: sample.memory, children: [],
            searchText: search(sample, home: home))
    }

    static func total(
        id: String, kind: ProcessNode.Kind, title: String, detail: String, appID: String?, pid: Int32?,
        children: [ProcessNode], processes: [ProcessSample], home: String
    ) -> ProcessNode {
        ProcessNode(
            id: id, kind: kind, title: title, detail: detail, appID: appID, pid: pid, count: processes.count,
            cpu: sum(processes.map(\.cpu)), gpu: sum(processes.map(\.gpu)), memory: sum(processes.map(\.memory)),
            children: children,
            searchText: ([title.lowercased()] + processes.map { search($0, home: home) }).joined(separator: " "))
    }

    /// A total of what was measured; nil only when nothing was (a process that just
    /// started has no CPU reading yet and must not blank its app's).
    public static func sum(_ values: [Double?]) -> Double? {
        let known = values.compactMap { $0 }
        return known.isEmpty ? nil : known.reduce(0, +)
    }

    static func search(_ sample: ProcessSample, home: String) -> String {
        [sample.name, displayName(sample), String(sample.pid), sample.directory.map { abbreviate($0, home: home) }]
            .compactMap { $0 }.joined(separator: " ").lowercased()
    }

    public static func abbreviate(_ path: String, home: String) -> String {
        guard !home.isEmpty, home != "/" else { return path }
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    static func lastComponent(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }
}

/// GPU time a process used between two readings, as a share of the wall clock.
/// Can exceed what Activity Monitor calls utilization when several GPU engines overlap;
/// it is capped at 100%.
public func processGPUShare(previous: UInt64?, current: UInt64, elapsed: Double) -> Double? {
    guard let previous, current >= previous, elapsed.isFinite, elapsed > 0 else { return nil }
    return min(1, Double(current - previous) / (elapsed * 1_000_000_000))
}
