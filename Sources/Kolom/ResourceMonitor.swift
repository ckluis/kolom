import SwiftUI
import Darwin
import AppKit
import KolomCore

/// One low-frequency sampler shared by every display rail. No window capture,
/// network requests, subprocesses, or privileged hardware APIs are involved.
final class ResourceMonitor: ObservableObject {
    static let shared = ResourceMonitor()
    @Published var cpu: Double?
    @Published var memory: Double?
    @Published var network: Double?
    @Published var cpuHistory = ResourceHistory()
    @Published var memoryHistory = ResourceHistory()
    @Published var networkHistory = ResourceHistory()
    @Published var processes: [ProcessResource] = []
    @Published var apps: [AppResource] = []
    @Published var appIcons: [String: NSImage] = [:]
    @Published var inaccessibleProcesses = 0
    @Published var detailsReady = false
    private var detailed = false
    private let processSampler = ProcessResourceSampler()
    func beginDetails() { queue.async { [weak self] in self?.detailed = true } }
    func endDetails() {
        queue.async { [weak self] in
            self?.detailed = false
            self?.processSampler.reset()
        }
        processes = []
        apps = []
        detailsReady = false
    }
    private let queue = DispatchQueue(label: "Kolom.resources", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var previousCPU: (busy: UInt64, total: UInt64)?
    private var previousNetwork: [String: (UInt32, UInt32)] = [:]
    private var previousTime: TimeInterval?
    private init() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 2, leeway: .milliseconds(250))
        timer.setEventHandler { [weak self] in self?.sample() }
        self.timer = timer
        timer.resume()
    }
    private func sample() {
        var cpuValue: Double?
        var load = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &load) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        if result == KERN_SUCCESS {
            let ticks = load.cpu_ticks
            let busy = UInt64(ticks.0) + UInt64(ticks.1) + UInt64(ticks.3)
            let total = busy + UInt64(ticks.2)
            if let old = previousCPU, total > old.total, busy >= old.busy {
                cpuValue = min(1, Double(busy - old.busy) / Double(total - old.total))
            }
            previousCPU = (busy, total)
        }
        var memoryValue: Double?
        var vm = vm_statistics64()
        count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let vmResult = withUnsafeMutablePointer(to: &vm) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        if vmResult == KERN_SUCCESS {
            // Active + wired + compressed pages; cached inactive pages are excluded.
            let pages = UInt64(vm.active_count) + UInt64(vm.wire_count) + UInt64(vm.compressor_page_count)
            memoryValue = min(
                1, Double(pages) * Double(vm_kernel_page_size) / Double(ProcessInfo.processInfo.physicalMemory))
        }
        let now = ProcessInfo.processInfo.systemUptime
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        var next: [String: (UInt32, UInt32)] = [:]
        var bytes: UInt64 = 0
        let valid = getifaddrs(&interfaces) == 0
        if valid {
            var current = interfaces
            while let entry = current {
                let interface = entry.pointee
                let name = String(cString: interface.ifa_name)
                if interface.ifa_addr?.pointee.sa_family == UInt8(AF_LINK),
                    name.hasPrefix("en"), interface.ifa_flags & UInt32(IFF_UP) != 0,
                    let data = interface.ifa_data?.assumingMemoryBound(to: if_data.self).pointee
                {
                    let incoming = data.ifi_ibytes
                    let outgoing = data.ifi_obytes
                    next[name] = (incoming, outgoing)
                    if let old = previousNetwork[name] {
                        // BSD counters wrap at 32 bits. Wrapping subtraction keeps
                        // ordinary rollover from producing a negative sample.
                        bytes += UInt64(incoming &- old.0) + UInt64(outgoing &- old.1)
                    }
                }
                current = interface.ifa_next
            }
            freeifaddrs(interfaces)
        }
        var networkValue: Double?
        if valid, let oldTime = previousTime, now > oldTime, !next.isEmpty {
            networkValue = Double(bytes) / (now - oldTime)
        }
        previousNetwork = next
        previousTime = now
        var detail: ([ProcessResource], [AppResource], Int)?
        var icons: [String: NSImage] = [:]
        if detailed {
            let identities: [ProcessResourceSampler.AppIdentity] = DispatchQueue.main.sync {
                NSWorkspace.shared.runningApplications.compactMap { app in
                    guard let path = app.bundleURL?.path else { return nil }
                    let id = app.bundleIdentifier ?? path
                    if let icon = app.icon { icons[id] = icon }
                    return ProcessResourceSampler.AppIdentity(
                        pid: app.processIdentifier, path: path, id: id, name: app.localizedName ?? "App")
                }
            }
            detail = processSampler.sample(apps: identities)
        }
        DispatchQueue.main.async { [weak self] in
            self?.cpuHistory.append(cpuValue)
            self?.memoryHistory.append(memoryValue)
            self?.networkHistory.append(networkValue)
            if let detail {
                self?.processes = detail.0
                self?.apps = detail.1
                self?.inaccessibleProcesses = detail.2
                self?.appIcons = icons
                self?.detailsReady = true
            }
            self?.cpu = cpuValue
            self?.memory = memoryValue
            self?.network = networkValue
        }
    }
}

private typealias ResourceState<Value> = SwiftUI.State<Value>

struct ResourceMonitorView: View {
    @ObservedObject private var monitor = ResourceMonitor.shared
    let open: () -> Void
    private func percent(_ value: Double?) -> String { value.map { "\(Int(($0 * 100).rounded()))%" } ?? "—" }
    private var rate: String {
        guard let value = monitor.network else { return "—" }
        if value >= 1_000_000 { return String(format: "%.1fM", value / 1_000_000) }
        return "\(Int(value / 1000))K"
    }
    var body: some View {
        Button(action: open) {
            VStack(spacing: 5) {
                Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 1).padding(.bottom, 3)
                row("CPU", percent(monitor.cpu))
                row("MEM", percent(monitor.memory))
                row("NET", rate)
                row("GPU", "—")
            }.padding(.horizontal, 5).padding(.vertical, 6)
        }.buttonStyle(.plain)
            .help("Open performance dashboard")
            .accessibilityLabel(
                "System resources. CPU \(percent(monitor.cpu)), memory \(percent(monitor.memory)), network \(rate) bytes per second. GPU unavailable. Show details."
            )
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(spacing: 1) {
            Text(title).font(.system(size: 7, weight: .medium)).opacity(0.65)
            Spacer(minLength: 0)
            Text(value).font(.system(size: 8, weight: .medium, design: .monospaced)).monospacedDigit()
        }
    }
}
