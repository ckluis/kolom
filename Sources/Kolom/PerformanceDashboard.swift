import SwiftUI
import AppKit
import KolomCore

private typealias DashboardState<Value> = SwiftUI.State<Value>
private let cpuTint = Color(red: 0.37, green: 0.57, blue: 0.24)
private let memoryTint = Color(red: 0.28, green: 0.49, blue: 0.74)
private let networkTint = Color(red: 0.60, green: 0.40, blue: 0.68)
private let gpuTint = Color(red: 0.80, green: 0.47, blue: 0.20)

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

private enum ResourceSort: String { case cpu = "CPU", gpu = "GPU", memory = "MEMORY" }

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
    let close: () -> Void

    private func value(_ cpu: Double?, _ gpu: Double?, _ memory: Double?) -> Double {
        switch sort {
        case .cpu: return cpu ?? -1
        case .gpu: return gpu ?? -1
        case .memory: return memory ?? -1
        }
    }
    private func ordered(_ nodes: [ProcessNode]) -> [ProcessNode] {
        nodes.sorted {
            let a = value($0.cpu, $0.gpu, $0.memory)
            let b = value($1.cpu, $1.gpu, $1.memory)
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
            let a = value($0.cpu, $0.gpu, $0.memory)
            let b = value($1.cpu, $1.gpu, $1.memory)
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
                    insight
                    table
                    footnote
                }.padding(20)
            }
            HStack(spacing: 6) {
                Circle().fill(cpuTint).frame(width: 5, height: 5)
                Text("LOCAL · READ ONLY").tracking(1)
                Spacer()
                Text("2s samples · up to 2m history")
            }.font(.system(size: 9)).foregroundColor(.secondary).padding(.horizontal, 20).padding(.vertical, 12)
                .background(Color.primary.opacity(0.025))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(KolomSurface(theme: theme)).foregroundColor(.primary)
        .preferredColorScheme(theme == "Light" ? .light : .dark)
        .overlay(alignment: .trailing) { Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1) }
        .onAppear { monitor.beginDetails() }.onDisappear { monitor.endDetails() }
        .onExitCommand(perform: close)
    }
    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Performance").font(.system(size: 22, weight: .semibold, design: .rounded))
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
        }
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
        }
    }
    private func formatted(_ node: ProcessNode) -> String {
        switch sort {
        case .cpu: return resourcePercent(node.cpu)
        case .gpu: return resourcePercent(node.gpu)
        case .memory: return resourceBytes(node.memory)
        }
    }
    private var insight: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform.path").foregroundColor(cpuTint)
            if let top = ordered(monitor.nodes).first, value(top.cpu, top.gpu, top.memory) >= 0 {
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
                sortButton(.cpu).frame(width: 84, alignment: .trailing)
                sortButton(.gpu).frame(width: 84, alignment: .trailing)
                    .help("Share of GPU time, from the GPU's own per-app accounting")
                sortButton(.memory).frame(width: 100, alignment: .trailing)
            }.font(.system(size: 9, weight: .medium)).foregroundColor(.secondary).padding(.bottom, 9)
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
            "Sort by \(key.rawValue == "GPU" ? "GPU" : key.rawValue.lowercased()), highest first")
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
                cpu: node.cpu, gpu: node.gpu, memory: node.memory, cpuHistory: node.cpuHistory.samples,
                gpuHistory: node.gpuHistory.samples, memoryHistory: node.memoryHistory.samples)
        }.padding(.vertical, level == 0 ? 11 : 8)
            .background(
                level == 0
                    ? cpuTint.opacity(min(0.07, (node.cpu ?? 0) * 0.15)) : Color.primary.opacity(0.02 * Double(level)))
            .overlay(alignment: .bottom) { Divider().opacity(level == 0 ? 0.45 : 0.25) }
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
                cpu: process.cpu, gpu: process.gpu, memory: process.memory, cpuHistory: process.cpuHistory.samples,
                gpuHistory: process.gpuHistory.samples, memoryHistory: process.memoryHistory.samples)
        }.padding(.vertical, 9)
            .overlay(alignment: .bottom) { Divider().opacity(0.3) }
    }
    @ViewBuilder private func metrics(
        cpu: Double?, gpu: Double?, memory: Double?, cpuHistory: [Double?], gpuHistory: [Double?],
        memoryHistory: [Double?]
    ) -> some View {
        metric(resourcePercent(cpu), history: cpuHistory, tint: cpuTint, width: 84)
        if monitor.gpuMeasured {
            metric(resourcePercent(gpu), history: gpuHistory, tint: gpuTint, width: 84)
        } else {
            VStack(alignment: .trailing, spacing: 5) {
                Text("—").font(.system(size: 11)).foregroundColor(.secondary)
                Color.clear.frame(width: 40, height: 13)
            }.frame(width: 84, alignment: .trailing).help("This Mac’s GPU does not report per-app time")
        }
        metric(resourceBytes(memory), history: memoryHistory, tint: memoryTint, width: 100)
    }
    private func metric(_ value: String, history: [Double?], tint: Color, width: CGFloat) -> some View {
        VStack(alignment: .trailing, spacing: 5) {
            Text(value).font(.system(size: 11, weight: .medium, design: .monospaced)).monospacedDigit()
            ResourceSparkline(samples: history, tint: tint, relative: true).frame(width: 70, height: 13)
        }.frame(width: width, alignment: .trailing)
    }
    private var footnote: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(
                "Processes are grouped under the app macOS holds responsible for them, as Activity Monitor does: a terminal’s shells and everything they run, a browser’s tabs. Unfold an app for its sessions (named by shell and folder), then for their processes. Background services of macOS share one row."
            )
            Text(
                "CPU is normalized across all cores: 100% means the whole Mac. GPU is each app’s share of GPU time, as the GPU itself accounts it; engines run side by side, so shares can add up past the GPU widget. Memory is physical footprint; shared allocations can overlap."
            )
            Text(
                "Safari and other WebKit browsers run tabs, frames and extensions in separate Web Content processes; macOS does not say which tab each one is. Per-app network traffic needs administrator access, so only the Mac’s total is shown. \(monitor.inaccessibleProcesses) protected or exited processes could not be sampled."
            )
        }.font(.system(size: 10)).foregroundColor(.secondary).lineSpacing(3)
    }
}

private extension ProcessNode {
    var level0: Bool { kind == .app || kind == .system || (kind == .process && depth == 0 && !id.contains("/")) }
}
