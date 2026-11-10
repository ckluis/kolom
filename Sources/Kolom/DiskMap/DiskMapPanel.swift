import AppKit
import KolomCore
import SwiftUI

private typealias MapState<Value> = SwiftUI.State<Value>

/// Opens the Disk Map beside Performance; the app delegate connects it to the controller.
enum DiskMapHost {
    static var open: ((DiskMapModel.Target) -> Void)?
    static func open(path: String, name: String, startupDisk: Bool) {
        open?(.init(path: path, name: name, startupDisk: startupDisk))
    }
}

/// The Disk Map's panel: takes the keyboard (arrows, Space, Enter) like Performance.
final class DiskMapPanel: NSPanel {
    var dismiss: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { dismiss?() } else { super.keyDown(with: event) }
    }
}

struct DiskMapView: View {
    @ObservedObject var model: DiskMapModel
    @KolomPreference("kolomTheme") private var theme = "Light"

    var body: some View {
        VStack(spacing: 0) {
            DiskMapTopBar(model: model).padding(.horizontal, 14).frame(height: 48)
            DiskMapControls(model: model).padding(.horizontal, 14).padding(.bottom, 8)
            Divider()
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    ZStack {
                        TreemapRepresentable(model: model)
                        if model.root == nil { DiskMapProgress(model: model) }
                    }
                    if model.notice != nil || model.removing != nil { DiskMapNotice(model: model) }
                    Group {
                        if model.measure == .age { AgeLegend() } else { DiskMapLegend() }
                    }.padding(.horizontal, 12).padding(.vertical, 7)
                }
                Divider()
                DiskMapSidebar(model: model).frame(width: 300)
            }
        }
        .background(KolomSurface(theme: theme)).foregroundColor(.primary)
        .preferredColorScheme(theme == "Light" ? .light : .dark)
        .overlay(alignment: .trailing) { Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1) }
        .sheet(isPresented: $model.reviewing) { DiskMapReview(model: model) }
        .sheet(isPresented: $model.showingHelp) { DiskMapKeys(close: { model.showingHelp = false }) }
    }
}

/// One line under the map: why a mark was refused, removal progress, what came back.
private struct DiskMapNotice: View {
    @ObservedObject var model: DiskMapModel
    var body: some View {
        HStack(spacing: 8) {
            if let removing = model.removing {
                ProgressView(value: Double(removing.done), total: Double(max(1, removing.total))).frame(width: 120)
                Text("Removing \(removing.done) of \(removing.total)…")
            } else if let notice = model.notice {
                Image(systemName: "info.circle").foregroundColor(.secondary)
                Text(notice).lineLimit(2)
                Spacer(minLength: 4)
                Button {
                    model.notice = nil
                } label: {
                    Image(systemName: "xmark").font(.system(size: 9))
                }.buttonStyle(.plain).foregroundColor(.secondary)
            }
            Spacer(minLength: 0)
        }.font(.system(size: 11)).padding(.horizontal, 12).padding(.vertical, 7)
            .background(Color.primary.opacity(0.04))
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
            Button {
                model.requestClose?()
            } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .medium)).padding(6).contentShape(Rectangle())
            }.buttonStyle(.plain).foregroundColor(.secondary).help("Close the Disk Map · Escape at the top")
                .accessibilityLabel("Close the Disk Map")
                .padding(.trailing, -4)
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

/// Full labels when there is room, short ones when narrower, swatches with
/// tooltips when narrow (the panel on a 1080p display); never cut off mid-word.
private struct DiskMapLegend: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        ViewThatFits(in: .horizontal) {
            row { $0.label }
            row { Self.short($0) }
            row { _ in nil }
        }.font(.system(size: 10)).foregroundColor(.secondary).lineLimit(1)
    }

    private func row(_ title: @escaping (DiskKind) -> String?) -> some View {
        HStack(spacing: 10) {
            ForEach(DiskKind.legend, id: \.self) { kind in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2).fill(Color(nsColor: DiskMapPalette.base(kind, dark: scheme == .dark)))
                        .frame(width: 10, height: 10)
                    if let text = title(kind) { Text(text).fixedSize() }
                }.help(kind.label)
            }
            HStack(spacing: 4) {
                HatchSwatch().frame(width: 10, height: 10)
                Text(title(.cache) == nil ? "Reclaimable" : "Can be had back").fixedSize()
            }.help("Space that can be had back")
        }
    }

    static func short(_ kind: DiskKind) -> String {
        switch kind {
        case .agentScratch: return "Agents"
        case .toolchain: return "Tools"
        case .documents: return "Docs"
        default: return kind.label
        }
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

private struct DiskMapSidebar: View {
    @ObservedObject var model: DiskMapModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if let node = model.selection ?? model.focus {
                    selectionCard(node)
                }
                if !model.marks.isEmpty { marked }
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

    private var marked: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("MARKED").font(.system(size: 9, weight: .semibold)).tracking(0.8).foregroundColor(.secondary)
                Spacer()
                Button("Clear") { model.clearMarks() }.buttonStyle(.plain).font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            HStack(alignment: .firstTextBaseline) {
                Text(StorageFormat.bytes(model.marks.bytes)).font(.system(size: 18, weight: .medium, design: .rounded))
                    .foregroundColor(Color(nsColor: DiskMapPalette.danger))
                Text("in \(model.marks.count) item\(model.marks.count == 1 ? "" : "s")").font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            ForEach(Array(model.marks.nodes.prefix(5).enumerated()), id: \.offset) { _, node in
                HStack(spacing: 6) {
                    Button {
                        model.unmark(node)
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                    }.buttonStyle(.plain).help("Unmark")
                    Text(node.title).font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    Text(StorageFormat.bytes(node.size)).font(.system(size: 11, design: .monospaced))
                }
            }
            if model.marks.count > 5 {
                Text("and \(model.marks.count - 5) more").font(.system(size: 10)).foregroundColor(.secondary)
            }
            Button {
                model.reviewing = true
            } label: {
                Text("Review…").frame(maxWidth: .infinity)
            }.controlSize(.large).buttonStyle(.borderedProminent).tint(Color(nsColor: DiskMapPalette.amber))
                .help("Review what is marked, then move it to the Trash · C")
        }
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
                if !model.marks.isEmpty, let after = model.freeAfterMarks {
                    Text("\(StorageFormat.bytes(after)) free after removing what is marked")
                        .font(.system(size: 11, weight: .medium)).foregroundColor(Color(nsColor: DiskMapPalette.amber))
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

// MARK: Review

/// Everything marked, with what to know about each, then Move to Trash (the
/// default: recoverable until the Trash is emptied) or Delete Permanently (asks).
private struct DiskMapReview: View {
    @ObservedObject var model: DiskMapModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Remove \(model.marks.count) item\(model.marks.count == 1 ? "" : "s")?")
                    .font(.system(size: 17, weight: .semibold))
                Text("\(StorageFormat.bytes(model.marks.bytes)) in \(model.marks.files.formatted()) files. Moved to the Trash, they can be put back until it is emptied.")
                    .font(.system(size: 11)).foregroundColor(.secondary)
            }.padding(20)
            Divider()
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(model.marks.nodes.enumerated()), id: \.offset) { _, node in row(node) }
                }
            }.frame(minHeight: 160, maxHeight: 380)
            Divider()
            HStack {
                Button("Delete Permanently…", role: .destructive, action: confirmPermanent)
                    .help("Removes them for good, without the Trash")
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Move to Trash") { model.removeMarked(permanently: false) }
                    .keyboardShortcut(.defaultAction).disabled(model.marks.isEmpty)
            }.padding(16)
        }.frame(width: 560)
    }

    private func row(_ node: DiskNode) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                model.unmark(node)
                if model.marks.isEmpty { dismiss() }
            } label: {
                Image(systemName: "minus.circle").foregroundColor(.secondary)
            }.buttonStyle(.plain).help("Unmark")
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(node.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    if let reclaim = node.reclaim {
                        Text(reclaim.label).font(.system(size: 9, weight: .medium)).padding(.horizontal, 5)
                            .padding(.vertical, 1).background(Capsule().fill(Color(nsColor: DiskMapPalette.amber).opacity(0.25)))
                    }
                }
                Text(ProcessGrouping.abbreviate(node.path, home: model.policy.home)).font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
                if let git = model.gitNotes[node.path] {
                    Label(git, systemImage: git.contains("clean") ? "checkmark.circle" : "exclamationmark.triangle.fill")
                        .font(.system(size: 10, weight: git.contains("clean") ? .regular : .semibold))
                        .foregroundColor(git.contains("clean") ? .secondary : Color(nsColor: DiskMapPalette.danger))
                }
                if let warning = model.policy.warning(for: node) {
                    Label(warning, systemImage: "exclamationmark.triangle").font(.system(size: 10))
                        .foregroundColor(Color(nsColor: DiskMapPalette.danger))
                }
            }
            Spacer(minLength: 8)
            Text(StorageFormat.bytes(node.size)).font(.system(size: 12, design: .monospaced))
        }.padding(.horizontal, 20).padding(.vertical, 9)
            .overlay(alignment: .bottom) { Rectangle().fill(Color.primary.opacity(0.07)).frame(height: 1) }
    }

    private func confirmPermanent() {
        let alert = NSAlert()
        alert.messageText = "Delete \(model.marks.count) item\(model.marks.count == 1 ? "" : "s") permanently?"
        alert.informativeText = "\(StorageFormat.bytes(model.marks.bytes)) in \(model.marks.files.formatted()) files are removed for good and cannot be put back: \(model.marks.nodes.prefix(4).map(\.title).joined(separator: ", "))\(model.marks.count > 4 ? ", …" : "")."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Delete Permanently")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { model.removeMarked(permanently: true) }
    }
}

// MARK: Views, depth, hidden, filter

private struct DiskMapControls: View {
    @ObservedObject var model: DiskMapModel
    @FocusState private var filterFocused: Bool
    var body: some View {
        HStack(spacing: 12) {
            Picker("", selection: $model.measure) {
                ForEach(DiskMeasure.allCases, id: \.self) { Text($0.label).tag($0) }
            }.pickerStyle(.segmented).labelsHidden().frame(width: 180)
                .help("What tile areas measure; Age colours by last write · T")
            HStack(spacing: 4) {
                Text("Depth").foregroundColor(.secondary)
                Button { model.depth = max(1, model.depth - 1) } label: { Image(systemName: "minus") }
                    .disabled(model.depth <= 1).help("Fewer levels · [")
                Text("\(model.depth)").monospacedDigit().frame(width: 12)
                Button { model.depth = min(6, model.depth + 1) } label: { Image(systemName: "plus") }
                    .disabled(model.depth >= 6).help("More levels · ]")
            }.buttonStyle(.borderless)
            Toggle("Hidden", isOn: $model.showHidden).toggleStyle(.checkbox)
                .help("Show dot-folders and dot-files (often caches and toolchains) · .")
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField("Filter by name  /", text: $model.filter).textFieldStyle(.plain).focused($filterFocused)
                    .onSubmit { filterFocused = false }
                if !model.filter.isEmpty {
                    Button { model.filter = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundColor(.secondary)
                }
            }.padding(5).background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
                .frame(maxWidth: 260)
            Spacer(minLength: 0)
            Button { model.showingHelp = true } label: { Image(systemName: "questionmark.circle") }
                .buttonStyle(.borderless).help("Every key · ?")
        }.font(.system(size: 11)).controlSize(.small)
            .onChange(of: model.filterFocus) { _ in filterFocused = true }
    }
}

private struct AgeLegend: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        HStack(spacing: 10) {
            Text("Last write").foregroundColor(.secondary)
            ForEach([DiskAge.week, .month, .quarter, .year, .older], id: \.self) { age in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color(nsColor: DiskMapPalette.age(age, level: 0, dark: scheme == .dark)))
                        .frame(width: 10, height: 10)
                    Text(age.label).fixedSize()
                }
            }
            Spacer(minLength: 0)
        }.font(.system(size: 10)).foregroundColor(.secondary).lineLimit(1)
    }
}

/// Every key, from ? or the button.
private struct DiskMapKeys: View {
    let close: () -> Void
    private let keys: [(String, String)] = [
        ("Click", "select"), ("Double-click · Enter", "go into a folder"), ("Scroll up · down", "go in · go up"),
        ("Pinch apart · together", "go in · go up"),
        ("Backspace · Esc", "go up (Esc clears a filter first)"), ("← → ↑ ↓ · Tab", "move between tiles"),
        ("⌘[ · ⌘]", "back · forward"), ("[ · ]", "fewer · more levels"), ("T", "Size, Files, Age"),
        (".", "show or hide dot-folders"), ("/", "filter by name"), ("Space · X · ⌘-click", "mark or unmark"),
        ("C", "review what is marked"), ("O · right-click", "reveal in Finder"), ("⌘R", "scan again"), ("?", "these keys"),
    ]
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Disk Map keys").font(.system(size: 15, weight: .semibold))
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                ForEach(keys, id: \.0) { key, action in
                    GridRow {
                        Text(key).font(.system(size: 11, weight: .medium, design: .monospaced))
                        Text(action).font(.system(size: 11)).foregroundColor(.secondary)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Done", action: close).keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 420)
    }
}
