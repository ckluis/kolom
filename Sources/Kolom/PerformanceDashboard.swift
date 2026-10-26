import SwiftUI
import AppKit
import KolomCore

private typealias DashboardState<Value> = SwiftUI.State<Value>
private let cpuTint = Color(red: 0.37, green: 0.57, blue: 0.24)
private let memoryTint = Color(red: 0.28, green: 0.49, blue: 0.74)
private let networkTint = Color(red: 0.60, green: 0.40, blue: 0.68)

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

struct PerformanceDashboard: View {
    @KolomPreference("kolomTheme") private var theme = "Light"
    @ObservedObject private var monitor = ResourceMonitor.shared
    @DashboardState private var groupApps = true
    @DashboardState private var sortMemory = false
    @DashboardState private var query = ""
    @DashboardState private var expanded: Set<String> = []
    let close: () -> Void
    private var apps: [AppResource] {
        monitor.apps.filter {
            query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)
                || $0.processes.contains { $0.name.localizedCaseInsensitiveContains(query) }
        }.sorted {
            let a = sortMemory ? $0.memory : $0.cpu
            let b = sortMemory ? $1.memory : $1.cpu
            if (a ?? -1) != (b ?? -1) { return (a ?? -1) > (b ?? -1) }
            return ($0.memory ?? 0) > ($1.memory ?? 0)
        }
    }
    private var processes: [ProcessResource] {
        monitor.processes.filter {
            query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)
                || $0.groupName.localizedCaseInsensitiveContains(query) || String($0.pid).contains(query)
        }.sorted {
            let a = sortMemory ? $0.memory : $0.cpu
            let b = sortMemory ? $1.memory : $1.cpu
            if (a ?? -1) != (b ?? -1) { return (a ?? -1) > (b ?? -1) }
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
                "MEMORY", resourcePercent(monitor.memory), "used · estimate", monitor.memoryHistory.samples, memoryTint,
                1)
            widget(
                "NETWORK", resourceBytes(monitor.network), "per second · ↑ + ↓", monitor.networkHistory.samples,
                networkTint, nil)
            widget("GPU", "—", "Not available", [], .secondary, nil)
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
    private var insight: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform.path").foregroundColor(cpuTint)
            if let top = apps.first, sortMemory || top.cpu != nil {
                Text("\(top.name)").fontWeight(.medium).lineLimit(1)
                Text(sortMemory ? "has the largest measured memory footprint" : "has the highest measured CPU")
                    .foregroundColor(.secondary).lineLimit(1)
                Spacer(minLength: 0)
                Text(sortMemory ? resourceBytes(top.memory) : resourcePercent(top.cpu)).monospacedDigit().fontWeight(
                    .medium)
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
                Toggle("Group apps", isOn: $groupApps).toggleStyle(.switch).controlSize(.mini).font(.system(size: 10))
            }.padding(.bottom, 12)
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField("Filter apps or processes", text: $query).textFieldStyle(.plain)
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
                sortButton("CPU", memory: false).frame(width: 84, alignment: .trailing)
                Text("GPU").frame(width: 64, alignment: .trailing).help("Per-process GPU utilization is unavailable")
                sortButton("MEMORY", memory: true).frame(width: 100, alignment: .trailing)
                Text("NETWORK").frame(width: 90, alignment: .trailing).help("Per-process network rates are unavailable")
            }.font(.system(size: 9, weight: .medium)).foregroundColor(.secondary).padding(.bottom, 9)
            Divider()
            LazyVStack(spacing: 0) {
                if groupApps {
                    ForEach(apps) { app in
                        appRow(app)
                        if expanded.contains(app.id) {
                            ForEach(
                                app.processes.sorted {
                                    (sortMemory ? $0.memory ?? 0 : $0.cpu ?? 0)
                                        > (sortMemory ? $1.memory ?? 0 : $1.cpu ?? 0)
                                }
                            ) { process in processRow(process, child: true) }
                        }
                    }
                } else {
                    ForEach(processes) { process in processRow(process, child: false) }
                }
                if monitor.detailsReady && (groupApps ? apps.isEmpty : processes.isEmpty) {
                    Text(query.isEmpty ? "No readable process counters" : "No matching apps or processes")
                        .foregroundColor(.secondary).font(.system(size: 12)).padding(24)
                }
                if !monitor.detailsReady {
                    ProgressView("Reading process counters…").controlSize(.small).font(.system(size: 11)).padding(24)
                }
            }
        }
    }
    private func sortButton(_ title: String, memory: Bool) -> some View {
        Button {
            sortMemory = memory
        } label: {
            HStack(spacing: 3) {
                Text(title)
                if sortMemory == memory { Image(systemName: "arrow.down").font(.system(size: 8)) }
            }
        }.buttonStyle(.plain).foregroundColor(sortMemory == memory ? .primary : .secondary).help(
            "Sort by \(title.lowercased()), highest first")
    }
    private func appRow(_ app: AppResource) -> some View {
        HStack(spacing: 12) {
            Button {
                if expanded.contains(app.id) { expanded.remove(app.id) } else { expanded.insert(app.id) }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: expanded.contains(app.id) ? "chevron.down" : "chevron.right").font(
                        .system(size: 8)
                    ).foregroundColor(.secondary).frame(width: 9)
                    if let icon = monitor.appIcons[app.id] {
                        Image(nsImage: icon).resizable().frame(width: 22, height: 22)
                    } else {
                        Image(systemName: "gearshape").font(.system(size: 17)).foregroundColor(.secondary).frame(
                            width: 22, height: 22)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(app.name).font(.system(size: 11, weight: .medium)).lineLimit(1)
                        Text(
                            app.processes.count > 1
                                ? "\(app.processes.count) processes" : "PID \(String(app.processes[0].pid))"
                        ).font(.system(size: 9)).foregroundColor(.secondary)
                    }
                    Spacer(minLength: 0)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel(
                "\(app.name), \(app.processes.count) processes, \(expanded.contains(app.id) ? "collapse":"expand")")
            metrics(
                cpu: app.cpu, memory: app.memory, cpuHistory: app.cpuHistory.samples,
                memoryHistory: app.memoryHistory.samples)
        }.padding(.vertical, 11).background(cpuTint.opacity(min(0.07, (app.cpu ?? 0) * 0.15)))
            .overlay(alignment: .bottom) { Divider().opacity(0.45) }
    }
    private func processRow(_ process: ProcessResource, child: Bool) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                if child { Text("↳").foregroundColor(.secondary).padding(.leading, 17) }
                VStack(alignment: .leading, spacing: 3) {
                    Text(process.name).font(.system(size: 10)).lineLimit(1)
                    Text("PID \(String(process.pid))").font(.system(size: 9)).foregroundColor(.secondary)
                }
                Spacer(minLength: 0)
            }.frame(maxWidth: .infinity, alignment: .leading)
            metrics(
                cpu: process.cpu, memory: process.memory, cpuHistory: process.cpuHistory.samples,
                memoryHistory: process.memoryHistory.samples)
        }.padding(.vertical, 9).background(Color.primary.opacity(child ? 0.025 : 0))
            .overlay(alignment: .bottom) { Divider().opacity(0.3) }
    }
    @ViewBuilder private func metrics(cpu: Double?, memory: Double?, cpuHistory: [Double?], memoryHistory: [Double?])
        -> some View
    {
        metric(resourcePercent(cpu), history: cpuHistory, tint: cpuTint, width: 84, ceiling: nil)
        missing(width: 64, help: "GPU: unavailable through the public APIs used here")
        metric(resourceBytes(memory), history: memoryHistory, tint: memoryTint, width: 100, ceiling: nil)
        missing(
            width: 90,
            help:
                "Per-process network attribution is not available. The top widget shows system-wide physical-interface traffic."
        )
    }
    private func metric(_ value: String, history: [Double?], tint: Color, width: CGFloat, ceiling: Double?) -> some View
    {
        VStack(alignment: .trailing, spacing: 5) {
            Text(value).font(.system(size: 11, weight: .medium, design: .monospaced)).monospacedDigit()
            ResourceSparkline(samples: history, tint: tint, ceiling: ceiling, relative: true).frame(
                width: 70, height: 13)
        }.frame(width: width, alignment: .trailing)
    }
    private func missing(width: CGFloat, help: String) -> some View {
        VStack(alignment: .trailing, spacing: 5) {
            Text("—").font(.system(size: 11)).foregroundColor(.secondary)
            Color.clear.frame(width: 40, height: 13)
        }.frame(width: width, alignment: .trailing).help(help).accessibilityLabel(help)
    }
    private var footnote: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(
                "CPU is normalized across all cores: 100% means the whole Mac. Memory is physical footprint; shared allocations can overlap. Helpers inside an identified app bundle are grouped; shared system services stay separate."
            )
            Text(
                "GPU and per-process network are unavailable, not zero. \(monitor.inaccessibleProcesses) protected or exited processes could not be sampled. Charts show real samples only; row charts use independent scales for trends."
            )
        }.font(.system(size: 10)).foregroundColor(.secondary).lineSpacing(3)
    }
}
