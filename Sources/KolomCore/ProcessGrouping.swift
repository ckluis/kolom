import Foundation

/// One process as the performance sampler read it.
public struct ProcessSample {
    /// "pid:start", unique even when a pid is reused.
    public var id: String
    public var pid: Int32
    /// The parent pid, 0 when unreadable. 1 (launchd) for services, and for
    /// programs whose terminal session closed while they kept running.
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
    /// Runs as the current user, so it may be stopped from the dashboard.
    public var user: Bool
    /// What macOS calls it when it registers the process ("npm run dev", "AutoFill (cmux)").
    public var label: String?
    public var cpu: Double?
    public var gpu: Double?
    public var memory: Double?
    /// Bytes per second sent and received; nil when network attribution is unavailable.
    public var network: Double?
    public init(
        id: String, pid: Int32, parent: Int32, responsible: Int32?, name: String, path: String, directory: String?,
        system: Bool, user: Bool = true, label: String? = nil, cpu: Double?, gpu: Double?, memory: Double?,
        network: Double? = nil
    ) {
        self.id = id
        self.pid = pid
        self.parent = parent
        self.responsible = responsible
        self.name = name
        self.path = path
        self.directory = directory
        self.system = system
        self.user = user
        self.label = label
        self.cpu = cpu
        self.gpu = gpu
        self.memory = memory
        self.network = network
    }

    /// Executables in these folders belong to macOS (Safari's and WebKit's live under
    /// /System/Volumes/Preboot/Cryptexes). /bin and /usr/bin are left out: shells and
    /// tools there are the user's own work.
    public static let systemFolders = ["/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/", "/Library/Apple/"]
    public static func isSystem(path: String, uid: UInt32) -> Bool {
        uid < 500 || isSystemPath(path)
    }
    public static func isSystemPath(_ path: String) -> Bool { systemFolders.contains { path.hasPrefix($0) } }

    /// Runs from inside an app extension: a widget, a share or AutoFill extension.
    var isExtension: Bool { path.contains(".appex/") }
    /// A widget extension (…/StocksWidget.appex, …/BatteriesAvocadoWidgetExtension.appex).
    var isWidget: Bool {
        path.split(separator: "/").contains { $0.hasSuffix(".appex") && $0.localizedCaseInsensitiveContains("widget") }
    }
    /// A program of the user's own (not inside an app, extension or XPC service bundle).
    var isLoose: Bool {
        !system && !path.isEmpty && !ProcessSample.isSystemPath(path) && !path.contains(".app/")
            && !path.contains(".appex/") && !path.contains(".xpc/")
    }
}

/// A running app as macOS registers it.
public struct ProcessOwnerApp {
    public var pid: Int32
    public var path: String
    public var id: String
    public var name: String
    /// Whether it heads its own row: an app in the Dock, or a menu bar app that is
    /// not part of macOS. Widgets, XPC services and macOS agents are registered too,
    /// but belong to whoever is responsible for them.
    public var owner: Bool
    public init(pid: Int32, path: String, id: String, name: String, owner: Bool = true) {
        self.pid = pid
        self.path = path
        self.id = id
        self.name = name
        self.owner = owner
    }
    /// Dock apps own rows; menu bar (accessory) apps only when they are not macOS's own.
    public static func isOwner(regular: Bool, accessory: Bool, path: String) -> Bool {
        regular || (accessory && !ProcessSample.isSystemPath(path))
    }
}

/// A row of the performance table: an app, a session inside it, a group of alike
/// processes, or one process. Totals cover every process beneath it.
public struct ProcessNode: Identifiable {
    public enum Kind: Equatable { case app, system, notable, extensions, session, leftover, bucket, process }
    public var id: String
    public var kind: Kind
    public var title: String
    public var detail: String
    /// The app's bundle id, for its icon; nil below the top level.
    public var appID: String?
    /// The pid of the process this row is (a process) or of the app's own process (an app).
    public var pid: Int32?
    /// Indent inside an unfolded session (child processes of a shell).
    public var depth = 0
    public var count: Int
    public var cpu: Double?
    public var gpu: Double?
    public var memory: Double?
    public var network: Double?
    public var children: [ProcessNode]
    /// The processes beneath that may be stopped: the user's own, outside macOS. A
    /// terminal's root-owned login wrapper is left out; it ends with its shell.
    public var pids: [Int32]
    /// Something here may be stopped (an app: quit, as from the Dock).
    public var stoppable: Bool
    /// Lowercased names, folders and pids of everything beneath, for the filter.
    public var searchText: String
    public var cpuHistory = ResourceHistory()
    public var gpuHistory = ResourceHistory()
    public var memoryHistory = ResourceHistory()
    public var networkHistory = ResourceHistory()

    public init(
        id: String, kind: Kind, title: String, detail: String, appID: String? = nil, pid: Int32? = nil, depth: Int = 0,
        count: Int, cpu: Double?, gpu: Double?, memory: Double?, network: Double?, children: [ProcessNode],
        pids: [Int32], stoppable: Bool, searchText: String
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.appID = appID
        self.pid = pid
        self.depth = depth
        self.count = count
        self.cpu = cpu
        self.gpu = gpu
        self.memory = memory
        self.network = network
        self.children = children
        self.pids = pids
        self.stoppable = stoppable
        self.searchText = searchText
    }

    public func matches(_ query: String) -> Bool {
        query.isEmpty || searchText.contains(query.lowercased())
    }
}

public enum ProcessGrouping {
    public static let systemID = "system"
    public static let extensionsID = "extensions"
    private enum Owner: Hashable {
        case app(String)
        case system
        case notable(String)
        case extensions
        case root(Int32)
    }

    /// macOS services worth a row of their own: the usual answers to "why is my Mac slow".
    public struct Notable {
        public let id: String
        public let title: String
        public let detail: String
    }
    public static let notables: [String: Notable] = {
        let display = Notable(
            id: "windowserver", title: "WindowServer",
            detail: "Draws every display; DisplayLink and AirPlay screens add work here")
        let spotlight = Notable(
            id: "spotlight", title: "Spotlight indexing",
            detail: "Indexes files for search, after files change")
        let backup = Notable(id: "timemachine", title: "Time Machine", detail: "Backs up this Mac")
        let media = Notable(
            id: "media-analysis", title: "Photo & media analysis",
            detail: "Analyzes photos and video, mostly while idle")
        return [
            "WindowServer": display,
            "mds": spotlight, "mds_stores": spotlight, "mdworker": spotlight, "mdworker_shared": spotlight,
            "corespotlightd": spotlight, "mdbulkimport": spotlight,
            "backupd": backup, "backupd-helper": backup,
            "photoanalysisd": media, "mediaanalysisd": media, "photolibraryd": media,
        ]
    }()

    /// Groups processes under the app that is responsible for them, then by session.
    /// `home` shortens folders to "~/…".
    public static func tree(_ samples: [ProcessSample], apps: [ProcessOwnerApp], home: String) -> [ProcessNode] {
        var byPID: [Int32: ProcessSample] = [:]
        for sample in samples { byPID[sample.pid] = sample }
        var ownerByPID: [Int32: ProcessOwnerApp] = [:]
        for app in apps where app.owner { ownerByPID[app.pid] = app }
        let bundled = apps.filter { $0.owner && !$0.path.isEmpty }
        func bundleOwner(_ path: String) -> ProcessOwnerApp? {
            bundled.filter { path.hasPrefix($0.path + "/") }.max { $0.path.count < $1.path.count }
        }

        var resolved: [Int32: Owner] = [:]
        var visiting: Set<Int32> = []
        func appOwner(_ pid: Int32) -> String? {
            if let owner = resolve(pid), case .app(let id) = owner { return id }
            return nil
        }
        // An app claims its own process, then whatever it is responsible for, then
        // helpers inside its bundle, then descendants. Unclaimed extensions and macOS
        // services get a shared row each; anything else heads (or joins) its own.
        func resolve(_ pid: Int32) -> Owner? {
            if let known = resolved[pid] { return known }
            guard let sample = byPID[pid], !visiting.contains(pid) else { return nil }
            visiting.insert(pid)
            defer { visiting.remove(pid) }
            let responsible = sample.responsible.flatMap { $0 > 1 && $0 != pid ? $0 : nil }
            var owner: Owner
            if let app = ownerByPID[pid] {
                owner = .app(app.id)
            } else if let r = responsible, let app = ownerByPID[r] ?? byPID[r].flatMap({ bundleOwner($0.path) }) {
                owner = .app(app.id)
            } else if let app = bundleOwner(sample.path) {
                owner = .app(app.id)
            } else if sample.parent > 1, sample.parent != pid, let id = appOwner(sample.parent) {
                owner = .app(id)
            } else if let r = responsible, let id = appOwner(r) {
                owner = .app(id)
            } else if sample.isExtension {
                owner = .extensions
            } else if sample.system, let notable = notables[sample.name] {
                owner = .notable(notable.id)
            } else if sample.system {
                owner = .system
            } else if let r = responsible, let other = resolve(r) {
                owner = other
            } else if sample.parent > 1, sample.parent != pid, let other = resolve(sample.parent),
                other != .system, other != .extensions
            {
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
        let appByID = Dictionary(apps.filter(\.owner).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var nodes: [ProcessNode] = []
        for (owner, group) in members {
            switch owner {
            case .app(let id):
                let app = appByID[id]!
                var node: ProcessNode
                if group.count == 1 {
                    node = leaf(group[0], groupID: id, depth: 0, home: home)
                    node.id = id
                    node.kind = .app
                    node.title = app.name
                    node.appID = id
                } else {
                    node = total(
                        id: id, kind: .app, title: app.name, detail: "\(group.count) processes", appID: id,
                        pid: app.pid, children: sessions(group, groupID: id, mainPID: app.pid, home: home),
                        processes: group, home: home)
                }
                // Any app of the user's can be quit, as from the Dock, Safari and Finder included.
                node.pid = app.pid
                node.stoppable = byPID[app.pid]?.user ?? false
                nodes.append(node)
            case .system:
                let entries = buckets(group.map { leaf($0, groupID: systemID, depth: 0, home: home) }, groupID: systemID)
                var node = total(
                    id: systemID, kind: .system, title: "macOS", detail: "\(group.count) background services",
                    appID: nil, pid: nil, children: entries, processes: group, home: home)
                node.stoppable = false
                nodes.append(node)
            case .notable(let id):
                let notable = notables.values.first { $0.id == id }!
                if group.count == 1 {
                    var node = leaf(group[0], groupID: id, depth: 0, home: home)
                    node.id = "notable:" + id
                    node.kind = .notable
                    node.title = notable.title
                    node.detail = "PID \(group[0].pid) · " + notable.detail
                    nodes.append(node)
                } else {
                    let entries = buckets(group.map { leaf($0, groupID: "notable:" + id, depth: 0, home: home) }, groupID: "notable:" + id)
                    nodes.append(
                        total(
                            id: "notable:" + id, kind: .notable, title: notable.title,
                            detail: "\(group.count) processes · " + notable.detail, appID: nil, pid: nil,
                            children: entries, processes: group, home: home))
                }
            case .extensions:
                // Widgets run for the desktop and Notification Center; other extensions
                // (Quick Look thumbnails, System Settings search, sharing) when asked.
                let widgets = group.filter(\.isWidget)
                let others = group.filter { !$0.isWidget }
                var entries: [ProcessNode] = []
                for (part, title, members) in [("widgets", "Widgets", widgets), ("other", "Other extensions", others)]
                where !members.isEmpty {
                    let partID = "\(extensionsID)/\(part)"
                    entries.append(
                        total(
                            id: partID, kind: .bucket, title: title, detail: "\(members.count) processes", appID: nil,
                            pid: nil,
                            children: buckets(members.map { leaf($0, groupID: partID, depth: 0, home: home) }, groupID: partID),
                            processes: members, home: home))
                }
                nodes.append(
                    total(
                        id: extensionsID, kind: .extensions, title: "Widgets & extensions",
                        detail:
                            "\(widgets.count) widgets, \(others.count) other · loaded even while their apps are closed",
                        appID: nil, pid: nil, children: entries, processes: group, home: home))
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
                            id: id, kind: .app, title: displayName(head), detail: "\(group.count) processes",
                            appID: nil, pid: pid, children: sessions(group, groupID: id, mainPID: pid, home: home),
                            processes: group, home: home))
                }
            }
        }
        return nodes
    }

    /// The second level: the app's own process, then each subtree it started (a
    /// terminal's shells), with alike leftovers (Safari's web content) gathered and
    /// programs that outlived their terminal session set apart.
    static func sessions(_ group: [ProcessSample], groupID: String, mainPID: Int32, home: String) -> [ProcessNode] {
        let pids = Set(group.map(\.pid))
        var children: [Int32: [ProcessSample]] = [:]
        for sample in group where pids.contains(sample.parent) && sample.parent != sample.pid {
            children[sample.parent, default: []].append(sample)
        }
        var roots = group.filter { !pids.contains($0.parent) || $0.parent == $0.pid }
        var entries: [ProcessNode] = []
        if let main = roots.firstIndex(where: { $0.pid == mainPID }) {
            let sample = roots.remove(at: main)
            var node = leaf(sample, groupID: groupID, depth: 0, home: home)
            node.detail = "Main process · " + node.detail
            entries.append(node)
            roots.insert(contentsOf: children[sample.pid] ?? [], at: 0)
        }
        var singles: [ProcessNode] = []
        var leftovers: [ProcessNode] = []
        var leftoverProcesses: [ProcessSample] = []
        for root in roots {
            var subtree: [(ProcessSample, Int)] = []
            var seen: Set<Int32> = []
            func walk(_ sample: ProcessSample, _ depth: Int) {
                guard seen.insert(sample.pid).inserted else { return }
                subtree.append((sample, depth))
                for child in (children[sample.pid] ?? []).sorted(by: { $0.pid < $1.pid }) { walk(child, depth + 1) }
            }
            walk(root, 0)
            let node =
                subtree.count == 1
                ? leaf(root, groupID: groupID, depth: 0, home: home)
                : session(subtree, groupID: groupID, home: home)
            // Started by this app but now parented by launchd: its terminal session closed
            // and it kept running (a dev server left behind). XPC services also run under
            // launchd, but from inside a bundle.
            if root.parent == 1, root.isLoose {
                leftovers.append(node)
                leftoverProcesses += subtree.map(\.0)
            } else if subtree.count == 1 {
                singles.append(node)
            } else {
                entries.append(node)
            }
        }
        if !leftovers.isEmpty {
            let count = leftoverProcesses.count
            entries.append(
                total(
                    id: "\(groupID)/leftover", kind: .leftover, title: "Left running",
                    detail:
                        "\(count) process\(count == 1 ? "" : "es") · the terminal session that started \(leftovers.count == 1 ? "it" : "them") has closed",
                    appID: nil, pid: nil, children: leftovers, processes: leftoverProcesses, home: home))
        }
        return entries + buckets(singles, groupID: groupID)
    }

    static func session(_ subtree: [(ProcessSample, Int)], groupID: String, home: String) -> ProcessNode {
        let root = subtree[0].0
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
        return total(
            id: "\(groupID)/session:\(root.id)", kind: .session, title: title, detail: detail, appID: nil,
            pid: root.pid, children: subtree.map { leaf($0.0, groupID: groupID, depth: $0.1, home: home) },
            processes: subtree.map(\.0), home: home)
    }

    /// Gathers single processes that share a name ("Web Content" ×12).
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
                memory: sum(alike.map(\.memory)), network: sum(alike.map(\.network)), children: alike,
                pids: alike.flatMap(\.pids), stoppable: alike.contains(where: \.stoppable),
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

    /// What to call a process: a known WebKit role, the name macOS registered it
    /// under ("npm run dev" rather than "node"), or for tools installed as one
    /// executable per version (…/claude/versions/2.1.316) the tool's name.
    public static func displayName(_ sample: ProcessSample) -> String {
        if let friendly = friendlyNames[sample.name] { return friendly }
        if let label = sample.label, !label.isEmpty { return label }
        guard sample.name.contains("."), sample.name.allSatisfy({ $0.isNumber || $0 == "." }) else { return sample.name }
        var folders = sample.path.split(separator: "/").dropLast()
        if folders.last == "versions" { folders = folders.dropLast() }
        guard let tool = folders.last, !tool.hasPrefix(".") else { return sample.name }
        return "\(tool) \(sample.name)"
    }

    static func leaf(_ sample: ProcessSample, groupID: String, depth: Int, home: String) -> ProcessNode {
        var detail = ["PID \(sample.pid)"]
        if let folder = sample.directory.flatMap({ $0 == "/" ? nil : abbreviate($0, home: home) }) {
            detail.append(folder)
        }
        let title = displayName(sample)
        if sample.label != nil, title != sample.name { detail.append(sample.name) }
        return ProcessNode(
            id: "\(groupID)/\(sample.id)", kind: .process, title: title, detail: detail.joined(separator: " · "),
            pid: sample.pid, depth: depth, count: 1, cpu: sample.cpu, gpu: sample.gpu, memory: sample.memory,
            network: sample.network, children: [], pids: stoppable(sample) ? [sample.pid] : [],
            stoppable: stoppable(sample),
            searchText: search(sample, home: home))
    }

    static func stoppable(_ sample: ProcessSample) -> Bool { sample.user && !sample.system }

    static func total(
        id: String, kind: ProcessNode.Kind, title: String, detail: String, appID: String?, pid: Int32?,
        children: [ProcessNode], processes: [ProcessSample], home: String
    ) -> ProcessNode {
        ProcessNode(
            id: id, kind: kind, title: title, detail: detail, appID: appID, pid: pid, count: processes.count,
            cpu: sum(processes.map(\.cpu)), gpu: sum(processes.map(\.gpu)), memory: sum(processes.map(\.memory)),
            network: sum(processes.map(\.network)), children: children,
            pids: processes.filter(stoppable).map(\.pid), stoppable: processes.contains(where: stoppable),
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

/// One sample of `nettop -P -d -x -J bytes_in,bytes_out`: bytes moved per pid since the
/// previous sample. Lines are "name.pid,in,out,"; a line starting with "," is the
/// header that begins each sample.
public enum NettopParser {
    /// Parses one data line; nil for headers and anything malformed.
    public static func line(_ text: String) -> (pid: Int32, bytes: UInt64)? {
        var fields = text.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        while fields.last == "" { fields.removeLast() }
        guard fields.count >= 3, let output = UInt64(fields[fields.count - 1]),
            let input = UInt64(fields[fields.count - 2])
        else { return nil }
        let name = fields[0..<(fields.count - 2)].joined(separator: ",")
        guard let dot = name.lastIndex(of: "."), let pid = Int32(name[name.index(after: dot)...]), pid > 0 else {
            return nil
        }
        return (pid, input &+ output)
    }
    public static func isHeader(_ text: String) -> Bool { text.hasPrefix(",") }

    /// Bytes per pid from the second sample of a `-L 2 -s 1` run (the first holds
    /// totals since each connection opened); nil when the run did not get that far.
    public static func rates(_ output: String) -> [Int32: Double]? {
        var headers = 0
        var rates: [Int32: Double] = [:]
        for line in output.split(separator: "\n", omittingEmptySubsequences: true).map(String.init) {
            if isHeader(line) {
                headers += 1
            } else if headers == 2, let entry = self.line(line) {
                rates[entry.pid, default: 0] += Double(entry.bytes)
            }
        }
        return headers >= 2 ? rates : nil
    }
}

/// `ps -Ao pid=,ppid=,uid=,%cpu=,rss=,comm=`: the executable path is last and may hold spaces.
public enum PSListing {
    public static let format = "pid=,ppid=,uid=,%cpu=,rss=,comm="
    public struct Entry {
        public let parent: Int32
        public let uid: UInt32
        /// Percent of one core, a recent average.
        public let cpu: Double
        /// Resident bytes.
        public let memory: Double
        public let path: String
    }
    public static func parse(_ text: String) -> [Int32: Entry] {
        var entries: [Int32: Entry] = [:]
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: " ", maxSplits: 5, omittingEmptySubsequences: true)
            guard fields.count == 6, let pid = Int32(fields[0]), let parent = Int32(fields[1]),
                let uid = UInt32(fields[2]), let cpu = Double(fields[3]), let rss = Double(fields[4])
            else { continue }
            entries[pid] = Entry(
                parent: parent, uid: uid, cpu: cpu, memory: rss * 1024,
                path: String(fields[5]).trimmingCharacters(in: .whitespaces))
        }
        return entries
    }
}
