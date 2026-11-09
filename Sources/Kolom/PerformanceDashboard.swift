import SwiftUI
import AppKit
import KolomCore

private typealias DashboardState<Value> = SwiftUI.State<Value>
private let cpuTint = Color(red: 0.37, green: 0.57, blue: 0.24)
private let memoryTint = Color(red: 0.28, green: 0.49, blue: 0.74)
private let networkTint = Color(red: 0.60, green: 0.40, blue: 0.68)
private let gpuTint = Color(red: 0.80, green: 0.47, blue: 0.20)
private let storageTint = Color(red: 0.55, green: 0.47, blue: 0.30)

struct ResourceSparkline: View {
    let samples: [Double?]
    var tint: Color = cpuTint
    var ceiling: Double? = nil
    var relative = false
    var body: some View {
        GeometryReader { geo in
            let values = samples.compactMap { $0 }
            let maximum = max(0.001, ceiling ?? values.max() ?? 1)
            let lower = relative ? (values.min() ?? 0) : 0
            let span = max(0.001, maximum - lower, relative ? maximum * 0.01 : 0)
            Path { path in
                var continuing = false
                for (i, sample) in samples.enumerated() {
                    guard let sample else {
                        continuing = false
                        continue
                    }
                    let point = CGPoint(
                        x: geo.size.width * Double(i) / Double(max(1, samples.count - 1)),
                        y: geo.size.height * (1 - max(0, min(1, (sample - lower) / span))))
                    if continuing {
                        path.addLine(to: point)
                    } else {
                        path.move(to: point)
                        continuing = true
                    }
                }
            }.stroke(tint, style: StrokeStyle(lineWidth: 1.35, lineCap: .round, lineJoin: .round))
            Path { p in
                p.move(to: CGPoint(x: 0, y: geo.size.height))
                p.addLine(to: CGPoint(x: geo.size.width, y: geo.size.height))
            }.stroke(tint.opacity(0.12), lineWidth: 0.5)
        }.accessibilityHidden(true)
    }
}
private func resourcePercent(_ value: Double?) -> String { value.map { String(format: "%.1f%%", $0 * 100) } ?? "—" }
private func resourceBytes(_ value: Double?) -> String {
    guard let value else { return "—" }
    if value >= 1_000_000_000 { return String(format: "%.2f GB", value / 1_000_000_000) }
    if value >= 1_000_000 { return String(format: "%.0f MB", value / 1_000_000) }
    return String(format: "%.0f KB", value / 1000)
}

private func resourceRate(_ value: Double?) -> String {
    guard let value else { return "—" }
    if value < 1 { return "0 B/s" }
    if value < 1000 { return String(format: "%.0f B/s", value) }
    if value < 1_000_000 { return String(format: "%.0f KB/s", value / 1000) }
    return String(format: "%.1f MB/s", value / 1_000_000)
}
private enum ResourceSort: String { case cpu = "CPU", gpu = "GPU", memory = "MEMORY", network = "NETWORK" }

/// One visible line of the outline: a node at its unfolded depth.
private struct OutlineRow: Identifiable {
    let node: ProcessNode
    let level: Int
    var id: String { node.id }
}

struct PerformanceDashboard: View {
    @KolomPreference("kolomTheme") private var theme = "Light"
    @ObservedObject private var monitor = ResourceMonitor.shared
    @DashboardState private var groupApps = true
    @DashboardState private var sort = ResourceSort.cpu
    @DashboardState private var query = ""
    @DashboardState private var expanded: Set<String> = []
    @DashboardState private var notice: String?
    @DashboardState private var showStorage = false
    @DashboardState private var showHelp = false
    let close: () -> Void

    private func value(_ cpu: Double?, _ gpu: Double?, _ memory: Double?, _ network: Double?) -> Double {
        switch sort {
        case .cpu: return cpu ?? -1
        case .gpu: return gpu ?? -1
        case .memory: return memory ?? -1
        case .network: return network ?? -1
        }
    }
    private func ordered(_ nodes: [ProcessNode]) -> [ProcessNode] {
        nodes.sorted {
            let a = value($0.cpu, $0.gpu, $0.memory, $0.network)
            let b = value($1.cpu, $1.gpu, $1.memory, $1.network)
            if a != b { return a > b }
            if ($0.memory ?? 0) != ($1.memory ?? 0) { return ($0.memory ?? 0) > ($1.memory ?? 0) }
            return $0.id < $1.id
        }
    }
    private var topNodes: [ProcessNode] { ordered(monitor.nodes.filter { $0.matches(query) }) }
    /// The outline as drawn. A filter unfolds whatever holds a match.
    private var rows: [OutlineRow] {
        var rows: [OutlineRow] = []
        func add(_ node: ProcessNode, _ level: Int) {
            rows.append(OutlineRow(node: node, level: level))
            guard !node.children.isEmpty, expanded.contains(node.id) || !query.isEmpty else { return }
            // A session keeps its process tree order, so children sit under their parents.
            let children = node.kind == .session ? node.children : ordered(node.children)
            for child in children where child.matches(query) { add(child, level + 1) }
        }
        for node in topNodes { add(node, 0) }
        return rows
    }
    private var processes: [ProcessResource] {
        monitor.processes.filter {
            query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)
                || $0.groupName.localizedCaseInsensitiveContains(query)
                || $0.detail.localizedCaseInsensitiveContains(query)
        }.sorted {
            let a = value($0.cpu, $0.gpu, $0.memory, $0.network)
            let b = value($1.cpu, $1.gpu, $1.memory, $1.network)
            if a != b { return a > b }
            return ($0.memory ?? 0) > ($1.memory ?? 0)
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    widgets
                    if showStorage {
                        StorageView(back: { setStorage(false) })
                    } else {
                        insight
                        table
                    }
                }.padding(20)
            }
            HStack(spacing: 6) {
                Circle().fill(cpuTint).frame(width: 5, height: 5)
                Text("LOCAL · RIGHT-CLICK A ROW TO QUIT OR STOP IT").tracking(1)
                Spacer()
                Text("2s samples · up to 2m history")
            }.font(.system(size: 9)).foregroundColor(.secondary).padding(.horizontal, 20).padding(.vertical, 12)
                .background(Color.primary.opacity(0.025))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(KolomSurface(theme: theme)).foregroundColor(.primary)
        .preferredColorScheme(theme == "Light" ? .light : .dark)
        .overlay(alignment: .trailing) { Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1) }
        .overlay {
            if showHelp {
                ZStack(alignment: .trailing) {
                    Color.black.opacity(0.18).onTapGesture { withAnimation(.easeOut(duration: 0.18)) { showHelp = false } }
                    PerformanceHelp(theme: theme, unreadable: monitor.inaccessibleProcesses) {
                        withAnimation(.easeOut(duration: 0.18)) { showHelp = false }
                    }.frame(width: 420).transition(.move(edge: .trailing))
                }.transition(.opacity)
            }
        }
        .onAppear { if !showStorage { monitor.beginDetails() } }.onDisappear { monitor.endDetails() }
        .onExitCommand {
            if showHelp {
                withAnimation(.easeOut(duration: 0.18)) { showHelp = false }
            } else {
                close()
            }
        }
    }
    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text("Performance").font(.system(size: 22, weight: .semibold, design: .rounded))
                    Button {
                        withAnimation(.easeOut(duration: 0.18)) { showHelp.toggle() }
                    } label: {
                        Image(systemName: "questionmark.circle").font(.system(size: 14)).foregroundColor(.secondary)
                    }.buttonStyle(.plain).help("How Performance groups and measures")
                        .accessibilityLabel("How Performance works")
                }
                Text("A little clarity about what’s working hard.").font(.system(size: 11)).foregroundColor(.secondary)
            }
            Spacer()
            Button(action: close) { Image(systemName: "sidebar.left").font(.system(size: 15)).padding(7) }.buttonStyle(
                .plain
            ).help("Close performance · Escape").accessibilityLabel("Close performance dashboard")
        }.padding(20)
            .overlay(alignment: .bottom) { Divider() }
    }
    private var widgets: some View {
        HStack(spacing: 8) {
            widget("CPU", resourcePercent(monitor.cpu), "of this Mac", monitor.cpuHistory.samples, cpuTint, 1)
            widget(
                "GPU", resourcePercent(monitor.gpu), monitor.gpu == nil ? "Not reported by this Mac" : "busiest GPU",
                monitor.gpuHistory.samples, gpuTint, 1)
            widget(
                "MEMORY", resourcePercent(monitor.memory), "used · estimate", monitor.memoryHistory.samples, memoryTint,
                1)
            widget(
                "NETWORK", resourceBytes(monitor.network), "per second · ↑ + ↓", monitor.networkHistory.samples,
                networkTint, nil)
            storageWidget
        }
    }
    /// Process sampling (ps, nettop) pauses while the storage view is shown.
    private func setStorage(_ shown: Bool) {
        showStorage = shown
        if shown { monitor.endDetails() } else { monitor.beginDetails() }
    }
    private var storageWidget: some View {
        Button {
            setStorage(!showStorage)
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 4) {
                    Text("STORAGE").font(.system(size: 9, weight: .semibold)).tracking(0.8)
                    Spacer(minLength: 0)
                    Image(systemName: showStorage ? "xmark" : "chevron.right").font(.system(size: 8))
                }.foregroundColor(.secondary)
                Text(monitor.startupDisk.map { StorageFormat.bytes($0.available) } ?? "—")
                    .font(.system(size: 20, weight: .medium, design: .rounded)).monospacedDigit()
                    .minimumScaleFactor(0.6).lineLimit(1)
                Text(
                    monitor.startupDisk.map { "free of \(StorageFormat.bytes($0.total))" } ?? "startup disk"
                ).font(.system(size: 9)).foregroundColor(.secondary).lineLimit(1)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(storageTint.opacity(0.15))
                        Capsule().fill(storageTint).frame(
                            width: geo.size.width
                                * (monitor.startupDisk.map { 1 - Double($0.available) / Double(max(1, $0.total)) } ?? 0))
                    }
                }.frame(height: 5).padding(.top, 12)
                Text(monitor.diskCount > 1 ? "+\(monitor.diskCount - 1) more disk\(monitor.diskCount == 2 ? "" : "s")" : " ")
                    .font(.system(size: 8)).foregroundColor(.secondary).lineLimit(1)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                .background(RoundedRectangle(cornerRadius: 12).fill(storageTint.opacity(showStorage ? 0.14 : 0.055)))
                .overlay(
                    RoundedRectangle(cornerRadius: 12).stroke(storageTint.opacity(showStorage ? 0.45 : 0.12), lineWidth: showStorage ? 1 : 0.5)
                )
                .contentShape(Rectangle())
        }.buttonStyle(.plain).help(showStorage ? "Back to processes" : "Disks and their largest folders")
            .accessibilityLabel("Storage, \(monitor.startupDisk.map { StorageFormat.bytes($0.available) } ?? "unknown") free. Show disks.")
    }
    private func widget(
        _ title: String, _ value: String, _ subtitle: String, _ history: [Double?], _ tint: Color, _ ceiling: Double?
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 9, weight: .semibold)).tracking(0.8).foregroundColor(.secondary)
            Text(value).font(.system(size: 20, weight: .medium, design: .rounded)).monospacedDigit().minimumScaleFactor(
                0.6
            ).lineLimit(1)
            Text(subtitle).font(.system(size: 9)).foregroundColor(.secondary).lineLimit(1)
            ResourceSparkline(samples: history, tint: tint, ceiling: ceiling).frame(height: 25).padding(.top, 5)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill(tint.opacity(0.055)))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(tint.opacity(0.12), lineWidth: 0.5))
            .accessibilityElement(children: .combine)
    }
    private var insightPhrase: String {
        switch sort {
        case .cpu: return "uses the most CPU"
        case .gpu: return "uses the most GPU time"
        case .memory: return "has the largest memory footprint"
        case .network: return "moves the most network traffic"
        }
    }
    private func formatted(_ node: ProcessNode) -> String {
        switch sort {
        case .cpu: return resourcePercent(node.cpu)
        case .gpu: return resourcePercent(node.gpu)
        case .memory: return resourceBytes(node.memory)
        case .network: return resourceRate(node.network)
        }
    }
    private var insight: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform.path").foregroundColor(cpuTint)
            if let top = ordered(monitor.nodes).first, value(top.cpu, top.gpu, top.memory, top.network) >= 0 {
                Text(top.title).fontWeight(.medium).lineLimit(1)
                Text(top.count > 1 ? "\(insightPhrase) across \(top.count) processes" : insightPhrase)
                    .foregroundColor(.secondary).lineLimit(1)
                Spacer(minLength: 0)
                Text(formatted(top)).monospacedDigit().fontWeight(.medium)
            } else {
                Text("Collecting the first live samples…").foregroundColor(.secondary)
            }
        }.font(.system(size: 11)).padding(12)
            .background(RoundedRectangle(cornerRadius: 9).fill(cpuTint.opacity(0.06)))
    }
    private var table: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Resource offenders").font(.system(size: 14, weight: .semibold))
                Spacer()
                if monitor.inaccessibleProcesses > 0 {
                    Text("\(monitor.inaccessibleProcesses) unavailable").font(.system(size: 9)).foregroundColor(
                        .secondary
                    ).help(
                        "Protected or exited processes could not be sampled; this table includes readable counters only."
                    )
                }
                if groupApps && !expanded.isEmpty {
                    Button("Fold all") { expanded = [] }.buttonStyle(.plain).font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                Toggle("Group by app", isOn: $groupApps).toggleStyle(.switch).controlSize(.mini).font(.system(size: 10))
                    .help("Group every process under the app responsible for it, as Activity Monitor does")
            }.padding(.bottom, 12)
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField("Filter apps, processes, folders or PIDs", text: $query).textFieldStyle(.plain)
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                    }.buttonStyle(.plain)
                }
            }.font(.system(size: 11)).padding(9).background(Color.primary.opacity(0.04)).cornerRadius(7).padding(
                .bottom, 12)
            HStack(spacing: 12) {
                Text(groupApps ? "APP / PROCESS" : "PROCESS").frame(maxWidth: .infinity, alignment: .leading)
                sortButton(.cpu).frame(width: 76, alignment: .trailing)
                    .help(
                        "Share of the whole Mac: 100% is all \(ProcessInfo.processInfo.activeProcessorCount) cores busy. Activity Monitor shows % of one core, \(ProcessInfo.processInfo.activeProcessorCount)× this number.")
                sortButton(.gpu).frame(width: 72, alignment: .trailing)
                    .help("Share of GPU time, from the GPU's own per-app accounting")
                sortButton(.memory).frame(width: 92, alignment: .trailing)
                sortButton(.network).frame(width: 84, alignment: .trailing)
                    .help("Bytes sent and received per second, from Apple’s nettop while this dashboard is open")
            }.font(.system(size: 9, weight: .medium)).foregroundColor(.secondary).padding(.bottom, 9)
            if let notice {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle").foregroundColor(.secondary)
                    Text(notice).lineLimit(2)
                    Spacer(minLength: 0)
                    Button {
                        self.notice = nil
                    } label: {
                        Image(systemName: "xmark").font(.system(size: 9))
                    }.buttonStyle(.plain).foregroundColor(.secondary)
                }.font(.system(size: 10)).padding(8).background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.05)))
                    .padding(.bottom, 8)
            }
            Divider()
            LazyVStack(spacing: 0) {
                if groupApps {
                    ForEach(rows) { row in nodeRow(row.node, level: row.level) }
                } else {
                    ForEach(processes) { process in processRow(process) }
                }
                if monitor.detailsReady && (groupApps ? topNodes.isEmpty : processes.isEmpty) {
                    Text(query.isEmpty ? "No readable process counters" : "No matching apps or processes")
                        .foregroundColor(.secondary).font(.system(size: 12)).padding(24)
                }
                if !monitor.detailsReady {
                    ProgressView("Reading process counters…").controlSize(.small).font(.system(size: 11)).padding(24)
                }
            }
        }
    }
    private func sortButton(_ key: ResourceSort) -> some View {
        Button {
            sort = key
        } label: {
            HStack(spacing: 3) {
                Text(key.rawValue)
                if sort == key { Image(systemName: "arrow.down").font(.system(size: 8)) }
            }
        }.buttonStyle(.plain).foregroundColor(sort == key ? .primary : .secondary).help(
            "Sort by \(key == .gpu || key == .cpu ? key.rawValue : key.rawValue.lowercased()), highest first")
    }
    private func toggle(_ id: String) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }
    @ViewBuilder private func icon(_ node: ProcessNode) -> some View {
        if let id = node.appID, let image = monitor.appIcons[id] {
            Image(nsImage: image).resizable().frame(width: 22, height: 22)
        } else {
            let symbol: String = {
                switch node.kind {
                case .system: return "apple.logo"
                case .notable: return "info.circle"
                case .extensions: return "square.grid.2x2"
                case .leftover: return "exclamationmark.circle"
                case .session: return "terminal"
                case .bucket: return "square.stack.3d.up"
                case .app: return "gearshape"
                case .process: return "circle.fill"
                }
            }()
            Image(systemName: symbol).font(.system(size: node.kind == .process ? 4 : (node.level0 ? 17 : 12)))
                .foregroundColor(.secondary).frame(width: node.level0 ? 22 : 14, height: node.level0 ? 22 : 14)
        }
    }
    private func nodeRow(_ node: ProcessNode, level: Int) -> some View {
        let open = expanded.contains(node.id) || (!query.isEmpty && !node.children.isEmpty)
        let indent = CGFloat(level) * 17 + CGFloat(node.depth) * 12
        return HStack(spacing: 12) {
            Button {
                if !node.children.isEmpty { toggle(node.id) }
            } label: {
                HStack(spacing: 7) {
                    Group {
                        if node.children.isEmpty {
                            Text(node.depth > 0 ? "↳" : "").foregroundColor(.secondary)
                        } else {
                            Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 8))
                                .foregroundColor(.secondary)
                        }
                    }.frame(width: 9)
                    icon(node)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(node.title).font(.system(size: level == 0 ? 11 : 10, weight: level == 0 ? .medium : .regular))
                            .lineLimit(1)
                        Text(node.detail).font(.system(size: 9)).foregroundColor(.secondary).lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                }.padding(.leading, indent).contentShape(Rectangle())
            }.buttonStyle(.plain).help(node.detail)
                .accessibilityLabel(
                    node.children.isEmpty
                        ? "\(node.title), \(node.detail)"
                        : "\(node.title), \(node.count) processes, \(open ? "collapse" : "expand")")
            metrics(
                cpu: node.cpu, gpu: node.gpu, memory: node.memory, network: node.network,
                cpuHistory: node.cpuHistory.samples, gpuHistory: node.gpuHistory.samples,
                memoryHistory: node.memoryHistory.samples, networkHistory: node.networkHistory.samples)
        }.padding(.vertical, level == 0 ? 11 : 8)
            .background(
                node.kind == .leftover
                    ? Color.orange.opacity(0.07)
                    : level == 0
                        ? cpuTint.opacity(min(0.07, (node.cpu ?? 0) * 0.15)) : Color.primary.opacity(0.02 * Double(level)))
            .overlay(alignment: .bottom) { Divider().opacity(level == 0 ? 0.45 : 0.25) }
            .contextMenu { actions(for: node) }
    }
    /// Quit for apps (as from their own menu), stop for processes and sessions. Every
    /// action is confirmed; macOS's processes and Kolom's own are never offered.
    @ViewBuilder private func actions(for node: ProcessNode) -> some View {
        let target = StopTarget(node: node)
        if let target {
            Button(target.title(force: false)) { confirm(target, force: false) }
            Button(target.title(force: true)) { confirm(target, force: true) }
        } else {
            Text(
                node.kind == .system || !node.stoppable
                    ? "Belongs to macOS or another user; not stopped from here"
                    : "Kolom doesn’t stop itself from here; use Quit Kolom")
        }
        if let pid = node.pid {
            Divider()
            Button("Copy PID \(String(pid))") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(String(pid), forType: .string)
            }
        }
    }
    private func confirm(_ target: StopTarget, force: Bool) {
        let alert = NSAlert()
        alert.messageText = target.question(force: force)
        alert.informativeText = target.explanation(force: force)
        alert.alertStyle = force ? .critical : .warning
        alert.addButton(withTitle: target.button(force: force))
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        notice = "\(target.button(force: force)) · \(target.name)…"
        target.perform(force: force) { result in notice = result }
    }
    private func processNode(_ process: ProcessResource) -> ProcessNode {
        ProcessNode(
            id: process.id, kind: .process, title: process.name, detail: process.detail, pid: process.pid, count: 1,
            cpu: process.cpu, gpu: process.gpu, memory: process.memory, network: process.network, children: [],
            pids: [process.pid], stoppable: process.stoppable, searchText: "")
    }
    private func processRow(_ process: ProcessResource) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(process.name).font(.system(size: 10)).lineLimit(1)
                    Text(process.groupName == process.name ? process.detail : "\(process.groupName) · \(process.detail)")
                        .font(.system(size: 9)).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }.frame(maxWidth: .infinity, alignment: .leading)
            metrics(
                cpu: process.cpu, gpu: process.gpu, memory: process.memory, network: process.network,
                cpuHistory: process.cpuHistory.samples, gpuHistory: process.gpuHistory.samples,
                memoryHistory: process.memoryHistory.samples, networkHistory: process.networkHistory.samples)
        }.padding(.vertical, 9)
            .overlay(alignment: .bottom) { Divider().opacity(0.3) }
            .contextMenu { actions(for: processNode(process)) }
    }
    @ViewBuilder private func metrics(
        cpu: Double?, gpu: Double?, memory: Double?, network: Double?, cpuHistory: [Double?], gpuHistory: [Double?],
        memoryHistory: [Double?], networkHistory: [Double?]
    ) -> some View {
        metric(resourcePercent(cpu), history: cpuHistory, tint: cpuTint, width: 76)
        if monitor.gpuMeasured {
            metric(resourcePercent(gpu), history: gpuHistory, tint: gpuTint, width: 72)
        } else {
            unavailable(width: 72, help: "This Mac’s GPU does not report per-app time")
        }
        metric(resourceBytes(memory), history: memoryHistory, tint: memoryTint, width: 92)
        if monitor.networkMeasured {
            metric(resourceRate(network), history: networkHistory, tint: networkTint, width: 84)
        } else {
            unavailable(width: 84, help: "Starting nettop, Apple’s per-process network reader…")
        }
    }
    private func unavailable(width: CGFloat, help: String) -> some View {
        VStack(alignment: .trailing, spacing: 5) {
            Text("—").font(.system(size: 11)).foregroundColor(.secondary)
            Color.clear.frame(width: 40, height: 13)
        }.frame(width: width, alignment: .trailing).help(help)
    }
    private func metric(_ value: String, history: [Double?], tint: Color, width: CGFloat) -> some View {
        VStack(alignment: .trailing, spacing: 5) {
            Text(value).font(.system(size: 11, weight: .medium, design: .monospaced)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.8)
            ResourceSparkline(samples: history, tint: tint, relative: true).frame(width: 64, height: 13)
        }.frame(width: width, alignment: .trailing)
    }
}

private extension ProcessNode {
    var level0: Bool {
        kind == .app || kind == .system || kind == .notable || kind == .extensions
            || (kind == .process && depth == 0 && !id.contains("/"))
    }
}
