import AppKit
import KolomCore
import SwiftUI

private typealias StorageState<Value> = SwiftUI.State<Value>
private let storageTint = Color(red: 0.55, green: 0.47, blue: 0.30)

/// Disks first; opening one scans it and shows its folders largest first, to drill
/// into. Nothing is scanned until a disk is opened, and leaving stops the scan and
/// frees what it held.
struct StorageView: View {
    @StateObject private var scanner = StorageScanner()
    @StorageState private var volumes: [StorageVolume] = []
    @StorageState private var trail: [String] = []
    @StorageState private var files: [(name: String, size: UInt64)] = []
    @StorageState private var showFiles = false
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
            }
            if let volume = scanner.volume {
                folderView(volume)
            } else {
                volumeList
            }
        }
        .onAppear { volumes = StorageVolume.mounted() }
        .onDisappear { scanner.cancel() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in
            volumes = StorageVolume.mounted()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in
            volumes = StorageVolume.mounted()
        }
    }

    // MARK: Disks

    private var volumeList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(volumes) { volume in
                Button {
                    open(volume)
                } label: {
                    HStack(spacing: 12) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: volume.url.path)).resizable()
                            .frame(width: 30, height: 30)
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(volume.name).font(.system(size: 12, weight: .medium))
                                Text(volume.kind).font(.system(size: 9)).foregroundColor(.secondary)
                                Spacer()
                                Text(volume.available == 0 ? "Full" : "\(StorageFormat.bytes(volume.available)) available")
                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                            }
                            usageBar(volume.usedFraction).frame(height: 6)
                            Text("\(StorageFormat.bytes(volume.used)) used of \(StorageFormat.bytes(volume.total))")
                                .font(.system(size: 9)).foregroundColor(.secondary)
                        }
                        Image(systemName: "chevron.right").font(.system(size: 9)).foregroundColor(.secondary)
                    }.padding(.vertical, 11).contentShape(Rectangle())
                }.buttonStyle(.plain).help("Scan \(volume.name) for its largest folders")
                    .overlay(alignment: .bottom) { Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 1) }
                    .contextMenu { revealItems(volume.url.path) }
            }
            if volumes.isEmpty {
                Text("No disks are mounted").foregroundColor(.secondary).font(.system(size: 12)).padding(24)
            }
            Text("Open a disk to scan its folders, largest first. Sizes only; the ? beside Performance says more.")
                .font(.system(size: 10)).foregroundColor(.secondary).padding(.top, 12)
        }
    }

    private func open(_ volume: StorageVolume) {
        trail = []
        files = []
        showFiles = false
        scanner.scan(volume)
    }

    // MARK: Folders

    private struct Row: Identifiable {
        let name: String
        let path: String
        let size: UInt64
        let files: Int
        let unreadable: Int
        let trimmed: Bool
        var id: String { path }
    }
    private struct Listing {
        var path = ""
        var size: UInt64 = 0
        var rows: [Row] = []
        var filesSize: UInt64 = 0
        var fileCount = 0
        var totalFiles = 0
        var unreadable = 0
        var trimmed = false
        var found = false
    }

    /// The shown folder, copied under the scanner's lock.
    private var listing: Listing {
        _ = scanner.revision
        scanner.lock.lock()
        defer { scanner.lock.unlock() }
        guard let folder = scanner.root?.descendant(trail) else { return Listing() }
        return Listing(
            path: folder.path, size: folder.size,
            rows: folder.sortedChildren.map {
                Row(
                    name: $0.name, path: $0.path, size: $0.size, files: $0.totalFiles, unreadable: $0.totalUnreadable,
                    trimmed: $0.trimmed)
            }, filesSize: folder.filesSize, fileCount: folder.fileCount, totalFiles: folder.totalFiles,
            unreadable: folder.totalUnreadable, trimmed: folder.trimmed, found: true)
    }

    @ViewBuilder private func folderView(_ volume: StorageVolume) -> some View {
        let shown = listing
        VStack(alignment: .leading, spacing: 10) {
            breadcrumbs(volume)
            status(volume, shown)
            if shown.found {
                header(shown, volume: volume)
                VStack(spacing: 0) {
                    ForEach(shown.rows.prefix(200)) { row in folderRow(row, of: shown.size) }
                    if shown.fileCount > 0 { filesRow(shown) }
                    if trail.isEmpty, volume.startup, scanner.state != .scanning, volume.used > shown.size,
                        volume.used - shown.size > 500_000_000
                    {
                        otherRow(volume.used - shown.size, of: volume.used)
                    }
                    if shown.rows.count > 200 {
                        Text("\(shown.rows.count - 200) smaller folders not shown").font(.system(size: 10))
                            .foregroundColor(.secondary).padding(10)
                    }
                    if shown.trimmed {
                        ProgressView("Reading this folder’s subfolders…").controlSize(.small).font(.system(size: 10))
                            .padding(12)
                    }
                }
                if shown.unreadable > 0 { unreadableNote(shown.unreadable) }
            }
        }
        .onChange(of: trail) { _ in
            files = []
            showFiles = false
        }
    }

    private func breadcrumbs(_ volume: StorageVolume) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                Button("All disks") {
                    scanner.cancel()
                    scannerReset()
                }.buttonStyle(.plain).foregroundColor(.secondary)
                Image(systemName: "chevron.right").font(.system(size: 7)).foregroundColor(.secondary)
                Button(volume.name) { trail = [] }.buttonStyle(.plain)
                    .foregroundColor(trail.isEmpty ? .primary : .secondary)
                ForEach(Array(trail.enumerated()), id: \.offset) { index, name in
                    Image(systemName: "chevron.right").font(.system(size: 7)).foregroundColor(.secondary)
                    Button(name) { trail = Array(trail.prefix(index + 1)) }.buttonStyle(.plain)
                        .foregroundColor(index == trail.count - 1 ? .primary : .secondary)
                }
            }.font(.system(size: 11)).lineLimit(1)
        }
    }

    private func scannerReset() {
        trail = []
        volumes = StorageVolume.mounted()
        scanner.forget()
    }

    @ViewBuilder private func status(_ volume: StorageVolume, _ shown: Listing) -> some View {
        HStack(spacing: 8) {
            switch scanner.state {
            case .scanning:
                ProgressView().controlSize(.small)
                let progress = scanner.progress
                Text("Scanning · \(progress.files.formatted()) files · \(progress.path)").lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Button("Stop") { scanner.cancel() }
            case .finished(let seconds):
                Image(systemName: "checkmark.circle").foregroundColor(storageTint)
                Text("Scanned \(shown.found ? (scanner.root?.totalFiles ?? 0).formatted() : "0") files in \(Int(seconds.rounded())) s")
                Spacer(minLength: 0)
                Button("Rescan") { scanner.scan(volume) }
            case .cancelled:
                Image(systemName: "pause.circle").foregroundColor(.secondary)
                Text("Scan stopped · sizes so far are partial")
                Spacer(minLength: 0)
                Button("Scan again") { scanner.scan(volume) }
            case .idle:
                EmptyView()
            }
        }.font(.system(size: 10)).foregroundColor(.secondary).controlSize(.small)
    }

    private func header(_ shown: Listing, volume: StorageVolume) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(StorageFormat.bytes(shown.size)).font(.system(size: 20, weight: .medium, design: .rounded))
                .monospacedDigit()
            Text("in \(shown.totalFiles.formatted()) files").font(.system(size: 10)).foregroundColor(.secondary)
            Spacer()
            if trail.isEmpty {
                Text("\(StorageFormat.bytes(volume.used)) used on the disk").font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
        }.padding(.bottom, 6).overlay(alignment: .bottom) {
            Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 1)
        }
    }

    private func folderRow(_ row: Row, of total: UInt64) -> some View {
        Button {
            trail.append(row.name)
            if row.trimmed, let folder = folder(at: trail) { scanner.expand(folder) }
        } label: {
            sizeRow(
                icon: "folder.fill", title: row.name,
                detail: "\(row.files.formatted()) files" + (row.unreadable > 0 ? " · \(row.unreadable) unreadable" : ""),
                size: row.size, total: total, chevron: true)
        }.buttonStyle(.plain).contextMenu { revealItems(row.path) }
    }

    private func folder(at names: [String]) -> StorageFolder? {
        scanner.lock.lock()
        defer { scanner.lock.unlock() }
        return scanner.root?.descendant(names)
    }

    @ViewBuilder private func filesRow(_ shown: Listing) -> some View {
        Button {
            showFiles.toggle()
            if showFiles, files.isEmpty {
                let path = shown.path
                DispatchQueue.global(qos: .userInitiated).async {
                    let largest = StorageScanner.largestFiles(in: path)
                    DispatchQueue.main.async { files = largest }
                }
            }
        } label: {
            sizeRow(
                icon: showFiles ? "chevron.down" : "doc.on.doc", title: "Files in this folder",
                detail: "\(shown.fileCount.formatted()) files", size: shown.filesSize, total: shown.size,
                chevron: false)
        }.buttonStyle(.plain)
        if showFiles {
            ForEach(files, id: \.name) { file in
                sizeRow(icon: "doc", title: file.name, detail: "", size: file.size, total: shown.size, chevron: false)
                    .padding(.leading, 18)
                    .contextMenu { revealItems((shown.path as NSString).appendingPathComponent(file.name)) }
            }
        }
    }

    private func otherRow(_ bytes: UInt64, of used: UInt64) -> some View {
        sizeRow(
            icon: "questionmark.square.dashed", title: "Not in the folders scanned",
            detail: "macOS itself, snapshots, purgeable space and folders Kolom could not read", size: bytes,
            total: used, chevron: false
        ).opacity(0.75)
    }

    private func sizeRow(icon: String, title: String, detail: String, size: UInt64, total: UInt64, chevron: Bool)
        -> some View
    {
        let share = total > 0 ? Double(size) / Double(total) : 0
        return HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 13)).foregroundColor(storageTint).frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
                if !detail.isEmpty {
                    Text(detail).font(.system(size: 9)).foregroundColor(.secondary).lineLimit(1)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            usageBar(share).frame(width: 90, height: 5)
            Text(String(format: "%.0f%%", share * 100)).font(.system(size: 9)).foregroundColor(.secondary)
                .frame(width: 30, alignment: .trailing)
            Text(StorageFormat.bytes(size)).font(.system(size: 11, weight: .medium, design: .monospaced))
                .monospacedDigit().frame(width: 76, alignment: .trailing)
            Image(systemName: "chevron.right").font(.system(size: 8)).foregroundColor(.secondary)
                .opacity(chevron ? 1 : 0)
        }.padding(.vertical, 8).contentShape(Rectangle())
            .overlay(alignment: .bottom) { Rectangle().fill(Color.primary.opacity(0.07)).frame(height: 1) }
    }

    private func usageBar(_ fraction: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule().fill(storageTint.opacity(0.85)).frame(width: max(2, geo.size.width * min(1, fraction)))
            }
        }
    }

    private func unreadableNote(_ count: Int) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "lock").foregroundColor(.secondary)
            Text(
                "\(count.formatted()) folder\(count == 1 ? "" : "s") could not be read. macOS protects some (Mail, Messages, other apps’ data); their size is not counted here. Give Kolom Full Disk Access to include them."
            ).lineSpacing(2)
            Spacer(minLength: 0)
            Button("Full Disk Access…") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                    NSWorkspace.shared.open(url)
                }
            }
        }.font(.system(size: 10)).foregroundColor(.secondary).padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
    }

    @ViewBuilder private func revealItems(_ path: String) -> some View {
        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(path, forType: .string)
        }
    }
}
