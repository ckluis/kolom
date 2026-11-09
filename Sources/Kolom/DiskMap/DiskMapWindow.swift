import AppKit
import KolomCore
import SwiftUI

private typealias MapState<Value> = SwiftUI.State<Value>

/// The Disk Map window: one at a time; opening another disk replaces its scan.
final class DiskMapWindow: NSObject, NSWindowDelegate {
    private static var current: DiskMapWindow?
    private let window: NSWindow
    private let model: DiskMapModel

    static func open(path: String, name: String, startupDisk: Bool) {
        if let current, current.model.target.path == path {
            current.show()
            return
        }
        current?.window.close()
        let controller = DiskMapWindow(target: .init(path: path, name: name, startupDisk: startupDisk))
        current = controller
        controller.show()
        controller.model.start()
    }

    private init(target: DiskMapModel.Target) {
        model = DiskMapModel(target: target)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1240, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered,
            defer: false)
        super.init()
        window.title = "Disk Map · \(target.name)"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.minSize = NSSize(width: 820, height: 520)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: DiskMapView(model: model))
        window.setFrameAutosaveName("KolomDiskMap")
        let theme = UserDefaults.standard.string(forKey: "kolomTheme") ?? "Light"
        window.appearance = NSAppearance(named: theme == "Light" ? .aqua : .darkAqua)
        if !window.setFrameUsingName("KolomDiskMap") { window.center() }
    }

    private func show() {
        // A window of its own belongs in the Dock and ⌘-Tab while it is open.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        model.close()
        if Self.current === self {
            Self.current = nil
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

struct DiskMapView: View {
    @ObservedObject var model: DiskMapModel

    var body: some View {
        VStack(spacing: 0) {
            DiskMapTopBar(model: model).padding(.leading, 78).padding(.trailing, 14).frame(height: 44)
            Divider()
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    ZStack {
                        TreemapRepresentable(model: model)
                        if model.root == nil { DiskMapProgress(model: model) }
                    }
                    DiskMapLegend().padding(.horizontal, 12).padding(.vertical, 7)
                }
                Divider()
                DiskMapPanel(model: model).frame(width: 300)
            }
        }
        .frame(minWidth: 820, minHeight: 520)
        .background(Color(nsColor: .windowBackgroundColor))
        .ignoresSafeArea(.container, edges: .top)
    }
}

private struct TreemapRepresentable: NSViewRepresentable {
    let model: DiskMapModel
    func makeNSView(context: Context) -> TreemapView {
        let view = TreemapView()
        view.model = model
        model.view = view
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }
    func updateNSView(_ view: TreemapView, context: Context) { view.needsDisplay = true }
}

// MARK: Top bar

private struct DiskMapTopBar: View {
    @ObservedObject var model: DiskMapModel
    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 2) {
                Button(action: model.back) { Image(systemName: "chevron.left") }.disabled(!model.canGoBack)
                    .help("Back · ⌘[")
                Button(action: model.forward) { Image(systemName: "chevron.right") }.disabled(!model.canGoForward)
                    .help("Forward · ⌘]")
            }.buttonStyle(.borderless).font(.system(size: 12, weight: .medium))
            Breadcrumbs(model: model)
            Spacer(minLength: 8)
            if let root = model.root {
                Text("\(StorageFormat.bytes(root.size)) · \(root.files.formatted()) files")
                    .font(.system(size: 11)).foregroundColor(.secondary).monospacedDigit()
            }
            Button {
                model.isScanning ? model.stop() : model.rescan()
            } label: {
                Label(model.isScanning ? "Stop" : "Rescan", systemImage: model.isScanning ? "stop.fill" : "arrow.clockwise")
                    .font(.system(size: 11))
            }.help(model.isScanning ? "Stop the scan · Escape" : "Scan again · ⌘R")
        }
    }
}

private struct Breadcrumbs: View {
    @ObservedObject var model: DiskMapModel
    var body: some View {
        let line = model.focus?.lineage ?? []
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 3) {
                if line.isEmpty {
                    Text(model.target.name).font(.system(size: 12, weight: .semibold))
                }
                ForEach(Array(line.enumerated()), id: \.offset) { index, node in
                    if index > 0 { Image(systemName: "chevron.compact.right").foregroundColor(.secondary).font(.system(size: 10)) }
                    crumb(node, isLast: index == line.count - 1, title: index == 0 ? model.target.name : node.name)
                }
            }.padding(.vertical, 4)
        }
    }

    @ViewBuilder private func crumb(_ node: DiskNode, isLast: Bool, title: String) -> some View {
        let siblings = (node.parent?.children ?? []).filter { $0.isFolder && $0.size > 0 }
        HStack(spacing: 1) {
            Button(title) { model.go(to: node, select: nil) }.buttonStyle(.plain)
                .font(.system(size: 12, weight: isLast ? .semibold : .regular))
                .foregroundColor(isLast ? .primary : .secondary)
            if siblings.count > 1 {
                Menu {
                    ForEach(Array(siblings.prefix(40).enumerated()), id: \.offset) { _, sibling in
                        Button("\(sibling.name)  ·  \(StorageFormat.bytes(sibling.size))  ·  \(share(sibling, of: node.parent!))") {
                            model.go(to: sibling, select: nil)
                        }
                    }
                } label: {
                    Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold))
                }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().foregroundColor(.secondary)
                    .help("Folders beside \(title), largest first")
            }
        }
    }
}

private func share(_ node: DiskNode, of parent: DiskNode) -> String {
    guard parent.size > 0 else { return "" }
    let value = Double(node.size) / Double(parent.size) * 100
    return value < 1 ? "<1%" : String(format: "%.0f%%", value)
}

// MARK: Scanning

private struct DiskMapProgress: View {
    @ObservedObject var model: DiskMapModel
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if model.isScanning { ProgressView().controlSize(.small) }
                Text(model.isScanning ? "Measuring \(model.target.name)" : model.stopped ? "Scan stopped" : "Starting…")
                    .font(.system(size: 13, weight: .semibold))
            }
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 3) {
                lane("Files", model.progress.files.formatted())
                lane("Folders", model.progress.folders.formatted())
                lane("Measured", StorageFormat.bytes(model.progress.bytes))
                lane("Unreadable", model.progress.unreadable.formatted())
                lane("Elapsed", String(format: "%.0f s", model.elapsed))
            }.font(.system(size: 11, design: .monospaced))
            Text(model.progress.path).font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary)
                .lineLimit(1).truncationMode(.middle).frame(width: 300, alignment: .leading)
            if model.stopped {
                Button("Scan again") { model.rescan() }
            } else {
                Text("The map behind is what is measured so far; it fills in when the scan finishes.")
                    .font(.system(size: 10)).foregroundColor(.secondary).frame(width: 300, alignment: .leading)
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
    }

    private func lane(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundColor(.secondary)
            Text(value).monospacedDigit().frame(minWidth: 110, alignment: .trailing)
        }
    }
}

// MARK: Legend

private struct DiskMapLegend: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        HStack(spacing: 12) {
            ForEach(DiskKind.legend, id: \.self) { kind in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2).fill(Color(nsColor: DiskMapPalette.base(kind, dark: scheme == .dark)))
                        .frame(width: 10, height: 10)
                    Text(kind.label)
                }
            }
            HStack(spacing: 4) {
                HatchSwatch().frame(width: 10, height: 10)
                Text("Can be had back")
            }
            Spacer(minLength: 0)
        }.font(.system(size: 10)).foregroundColor(.secondary).lineLimit(1)
    }
}

private struct HatchSwatch: View {
    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color.secondary.opacity(0.2)))
            var path = Path()
            var x: CGFloat = -size.height
            while x < size.width {
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += 3.5
            }
            context.stroke(path, with: .color(Color(nsColor: DiskMapPalette.amber)), lineWidth: 1)
        }.clipShape(RoundedRectangle(cornerRadius: 2))
    }
}

// MARK: Side panel

private struct DiskMapPanel: View {
    @ObservedObject var model: DiskMapModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if let node = model.selection ?? model.focus {
                    selectionCard(node)
                }
                if let root = model.root {
                    worthALook(root)
                }
                disk
            }.padding(16)
        }
    }

    private func selectionCard(_ node: DiskNode) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(node === model.focus ? "SHOWING" : "SELECTED").font(.system(size: 9, weight: .semibold)).tracking(0.8)
                .foregroundColor(.secondary)
            HStack(spacing: 7) {
                RoundedRectangle(cornerRadius: 3).fill(Color(nsColor: DiskMapPalette.base(node.kind, dark: scheme == .dark)))
                    .frame(width: 12, height: 12)
                Text(node.lineage.count == 1 ? model.target.name : node.title).font(.system(size: 14, weight: .semibold))
                    .lineLimit(2)
            }
            Text(StorageFormat.bytes(node.size)).font(.system(size: 28, weight: .medium, design: .rounded)).monospacedDigit()
            VStack(alignment: .leading, spacing: 4) {
                if let parent = node.parent, let root = model.root {
                    fact("Share", "\(share(node, of: parent)) of \(parent.parent == nil ? model.target.name : parent.name) · \(share(node, of: root)) of the scan")
                }
                fact("Files", node.files.formatted())
                fact("Kind", node.kind.label)
                if node.modified > 0 {
                    fact("Last change", Date(timeIntervalSince1970: node.modified).formatted(.relative(presentation: .named)))
                }
                if node.unreadable > 0 { fact("Unreadable", "\(node.unreadable.formatted()) folders") }
            }
            if let reclaim = node.reclaim {
                HStack(spacing: 6) {
                    HatchSwatch().frame(width: 12, height: 12)
                    Text("Can be had back · \(reclaim.label)").font(.system(size: 11, weight: .medium))
                }.padding(.top, 2)
            }
            Text(node.path).font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary).lineLimit(3)
                .textSelection(.enabled)
            HStack {
                if node.isFolder, node !== model.focus {
                    Button("Open") { model.enter(node) }.keyboardShortcut(.defaultAction)
                }
                Button("Reveal in Finder") { model.reveal(node) }
            }.controlSize(.small).padding(.top, 2)
        }
    }

    private func fact(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).foregroundColor(.secondary).frame(width: 74, alignment: .leading)
            Text(value).lineLimit(2)
        }.font(.system(size: 11))
    }

    private func worthALook(_ root: DiskNode) -> some View {
        let items = root.reclaimable(limit: 8)
        return VStack(alignment: .leading, spacing: 6) {
            Text("WORTH A LOOK").font(.system(size: 9, weight: .semibold)).tracking(0.8).foregroundColor(.secondary)
            if items.isEmpty {
                Text("Nothing large that can plainly be had back.").font(.system(size: 11)).foregroundColor(.secondary)
            }
            ForEach(Array(items.enumerated()), id: \.offset) { _, node in
                Button {
                    model.reveal(inMap: node)
                } label: {
                    HStack(spacing: 8) {
                        HatchSwatch().frame(width: 10, height: 10)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(node.name).font(.system(size: 11, weight: .medium)).lineLimit(1)
                            Text("\(node.parent.map { abbreviated($0.path) } ?? "") · \(node.reclaim?.label ?? "")")
                                .font(.system(size: 9)).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer(minLength: 4)
                        Text(StorageFormat.bytes(node.size)).font(.system(size: 11, design: .monospaced))
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }
    }

    private var disk: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("DISK").font(.system(size: 9, weight: .semibold)).tracking(0.8).foregroundColor(.secondary)
            if let available = model.available, let capacity = model.capacity, capacity > 0 {
                HStack(alignment: .firstTextBaseline) {
                    Text(StorageFormat.bytes(available)).font(.system(size: 18, weight: .medium, design: .rounded))
                    Text("free of \(StorageFormat.bytes(capacity))").font(.system(size: 11)).foregroundColor(.secondary)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.08))
                        Capsule().fill(Color.primary.opacity(0.45))
                            .frame(width: geo.size.width * CGFloat(1 - Double(available) / Double(capacity)))
                    }
                }.frame(height: 6)
                if let root = model.root, model.target.startupDisk, capacity - available > root.size {
                    Text("\(StorageFormat.bytes(capacity - available - root.size)) used outside the folders scanned: macOS, snapshots, purgeable space, unreadable folders.")
                        .font(.system(size: 10)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func abbreviated(_ path: String) -> String {
        ProcessGrouping.abbreviate(path, home: FileManager.default.homeDirectoryForCurrentUser.path)
    }
}
