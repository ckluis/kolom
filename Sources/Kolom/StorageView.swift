import AppKit
import KolomCore
import SwiftUI

private typealias StorageState<Value> = SwiftUI.State<Value>
private let storageTint = Color(red: 0.55, green: 0.47, blue: 0.30)

/// The disks, one row each. Opening one shows it in the Disk Map window, which
/// scans it; nothing is scanned here.
struct StorageView: View {
    @StorageState private var volumes: [StorageVolume] = []
    let back: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Button(action: back) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left").font(.system(size: 9, weight: .semibold))
                        Text("Processes")
                    }
                }.buttonStyle(.plain).foregroundColor(.secondary).font(.system(size: 10))
                Text("Storage").font(.system(size: 14, weight: .semibold))
                Spacer()
                Button("Choose a folder…", action: chooseFolder).controlSize(.small)
                    .help("Map any folder")
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(volumes) { volume in row(volume) }
                if volumes.isEmpty {
                    Text("No disks are mounted").foregroundColor(.secondary).font(.system(size: 12)).padding(24)
                }
            }
            Text("Open a disk to map it: what fills it, coloured by kind, with what can be had back hatched.")
                .font(.system(size: 10)).foregroundColor(.secondary)
        }
        .onAppear { volumes = StorageVolume.mounted() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in
            volumes = StorageVolume.mounted()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in
            volumes = StorageVolume.mounted()
        }
    }

    private func row(_ volume: StorageVolume) -> some View {
        Button {
            DiskMapHost.open(path: volume.url.path, name: volume.name, startupDisk: volume.startup)
        } label: {
            HStack(spacing: 12) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: volume.url.path)).resizable().frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(volume.name).font(.system(size: 12, weight: .medium))
                        Text(volume.kind).font(.system(size: 9)).foregroundColor(.secondary)
                        Spacer()
                        Text(volume.available == 0 ? "Full" : "\(StorageFormat.bytes(volume.available)) available")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.primary.opacity(0.08))
                            Capsule().fill(storageTint.opacity(0.85))
                                .frame(width: max(2, geo.size.width * min(1, volume.usedFraction)))
                        }
                    }.frame(height: 6)
                    Text("\(StorageFormat.bytes(volume.used)) used of \(StorageFormat.bytes(volume.total))")
                        .font(.system(size: 9)).foregroundColor(.secondary)
                }
                Image(systemName: "rectangle.split.3x3").font(.system(size: 11)).foregroundColor(.secondary)
            }.padding(.vertical, 11).contentShape(Rectangle())
        }.buttonStyle(.plain).help("Open \(volume.name) in the Disk Map")
            .overlay(alignment: .bottom) { Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 1) }
            .contextMenu {
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([volume.url]) }
            }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Map"
        panel.message = "Choose a folder to map"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        DiskMapHost.open(path: url.path, name: url.lastPathComponent, startupDisk: false)
    }
}
