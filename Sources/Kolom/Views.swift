import SwiftUI
import AppKit
import KolomCore
import UniformTypeIdentifiers

private let paper = Color(red: 0.95, green: 0.96, blue: 0.92)
private let green = Color(red: 0.28, green: 0.40, blue: 0.23)

struct WindowGlyph: View {
    let window: NativeWindow
    var size: CGFloat = 26
    var body: some View {
        Image(nsImage: window.icon).resizable().interpolation(.high).frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
struct RailView: View {
    @KolomPreference("kolomTheme") var theme = "Light"
    @ObservedObject var model: KolomController
    let displayID: String
    var body: some View {
        VStack(spacing: 5) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 7) {
                    ForEach(model.workspaces[displayID]?.columns ?? []) { col in
                        Group {
                            if col.tiles.count > 1 {
                                VStack(spacing: 0) {
                                    ZStack(alignment: .topLeading) {
                                        ForEach(Array(col.tiles.enumerated()), id: \.element.id) { i, tile in
                                            entry(tile.id, stacked: true).offset(x: CGFloat(i) * 3, y: CGFloat(i) * 14)
                                                .zIndex(model.workspaces[displayID]?.focus == tile.id ? 2 : Double(i))
                                        }
                                    }.frame(
                                        width: 38, height: CGFloat(36 + 14 * (col.tiles.count - 1)),
                                        alignment: .topLeading)
                                    HStack(spacing: 4) {
                                        ForEach(col.tiles) { tile in
                                            let n =
                                                (model.workspaces[displayID]?.windowIDs.firstIndex(of: tile.id) ?? 0)
                                                + 1
                                            Text(n <= 9 ? "⌥\(n)" : "\(n)").font(.system(size: 7)).foregroundColor(
                                                .secondary)
                                        }
                                    }
                                }.frame(width: 40, height: CGFloat(49 + 14 * (col.tiles.count - 1)))
                            } else if let tile = col.tiles.first {
                                entry(tile.id, stacked: false)
                            }
                        }
                    }
                }.padding(.top, 10).frame(width: 48)
            }
            Button {
                model.toggleGuide(displayID)
            } label: {
                Image(systemName: model.guideDisplay == displayID ? "questionmark.circle.fill" : "questionmark.circle")
                    .font(.system(size: 14)).frame(width: 40, height: 24).contentShape(Rectangle())
            }.buttonStyle(.plain).foregroundColor(.secondary)
                .help("Guide: set up Kolom and learn the moves").accessibilityLabel("Open the Kolom guide")
            ResourceMonitorView { model.togglePerformance(displayID) }
            HStack(spacing: 1) {
                Button {
                    model.activeDisplay = displayID
                    model.navigate(-1)
                } label: {
                    Image(systemName: "chevron.left").frame(width: 20, height: 24)
                }.help("Previous column · Option Left").accessibilityLabel("Previous column")
                Button {
                    model.activeDisplay = displayID
                    model.navigate(1)
                } label: {
                    Image(systemName: "chevron.right").frame(width: 20, height: 24)
                }.help("Next column · Option Right").accessibilityLabel("Next column")
            }.font(.system(size: 11))

        }.buttonStyle(.plain).foregroundColor(theme == "Light" ? green : Color(red: 0.78, green: 0.92, blue: 0.67))
            .padding(.bottom, 12).frame(width: 48).background(KolomSurface(theme: theme)).overlay {
                if model.dropDisplay == displayID {
                    RoundedRectangle(cornerRadius: 5).stroke(Color.accentColor, lineWidth: 2).allowsHitTesting(false)
                }
            }.onDrop(of: [UTType.text], delegate: DisplayDrop(model: model, displayID: displayID)).preferredColorScheme(
                theme == "Light" ? .light : .dark)
    }
    @ViewBuilder func entry(_ id: String, stacked: Bool) -> some View {
        if let w = model.windows[id] {
            let selected = model.workspaces[displayID]?.focus == id
            let index = (model.workspaces[displayID]?.windowIDs.firstIndex(of: id) ?? 0) + 1
            VStack(spacing: 3) {
                WindowGlyph(window: w, size: stacked ? 23 : 26)
                    .padding(3).background(selected ? green.opacity(0.17) : Color.clear).cornerRadius(7)
                if !stacked {
                    Text(index <= 9 ? "⌥\(index)" : "\(index)").font(.system(size: 8)).foregroundColor(.secondary)
                }
            }.frame(width: stacked ? 30 : 40, height: stacked ? 40 : 47)
                .contentShape(Rectangle())
                .onTapGesture {
                    model.activeDisplay = displayID
                    model.focus(id)
                }
                .help(
                    "\(w.appName) · \(w.title)\n\(index<=9 ? "Option \(index) to focus. ":"")Option M for Kolom commands. Drag onto an icon to stack; top/bottom edge to reorder."
                )
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(w.appName), \(w.title), window \(index)")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { model.focus(id) }
                .onDrag {
                    model.draggedID = id
                    return NSItemProvider(object: id as NSString)
                }
                .onDrop(of: [UTType.text], delegate: RailDrop(model: model, target: id))
                .overlay(alignment: .top) {
                    if model.dropTarget == id && model.dropPlacement == .before {
                        Capsule().fill(green).frame(height: 3)
                    }
                }
                .overlay(alignment: .bottom) {
                    if model.dropTarget == id && model.dropPlacement == .after {
                        Capsule().fill(green).frame(height: 3)
                    }
                }
                .overlay {
                    if model.dropTarget == id && (model.dropPlacement == .below || model.dropPlacement == .above) {
                        RoundedRectangle(cornerRadius: 7).stroke(green, lineWidth: 2).background(green.opacity(0.15))
                    }
                }
                .contextMenu {
                    Text("\(w.appName) · \(w.title)")
                    Button("Focus window") { model.focus(id) }
                    Button("Move window…") {
                        model.focus(id)
                        model.showPalette?()
                    }
                    Button("Separate from stack") { model.unstack(id) }
                    Menu("Column width") {
                        ForEach([360, 520, 680, 900, 1200, 1600], id: \.self) { width in
                            Button("\(width) pt") { model.width(id, Double(width)) }
                        }
                        Button("Fill display") {
                            if let d = model.displays.first(where: { $0.id == displayID }) {
                                model.width(id, model.viewport(d).width)
                            }
                        }
                    }
                    Menu("Move to display") {
                        ForEach(model.displays) { display in
                            Button(display.name) { model.transfer(id, to: display.id) }.disabled(
                                display.id == displayID)
                        }
                    }
                    if !model.demo && !id.hasPrefix("desktop:") {
                        Button("Leave \(w.appName) unmanaged") { model.exclude(id) }
                    }
                    Divider()
                    Button("Close window") { model.close(id) }
                }
        }
    }
}
struct RailDrop: DropDelegate {
    let model: KolomController
    let target: String
    func validateDrop(info: DropInfo) -> Bool { model.draggedID != nil && model.draggedID != target }
    func dropEntered(info: DropInfo) { update(info) }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        update(info)
        return DropProposal(operation: .move)
    }
    func update(_ info: DropInfo) {
        model.dropTarget = target
        model.dropPlacement = info.location.y < 9 ? .before : info.location.y > 37 ? .after : .below
    }
    func dropExited(info: DropInfo) { if model.dropTarget == target { model.dropTarget = nil } }
    func performDrop(info: DropInfo) -> Bool {
        guard let source = model.draggedID else { return false }
        model.move(source, to: target, placement: model.dropPlacement)
        model.draggedID = nil
        model.dropTarget = nil
        return true
    }
}
struct CommandsView: View {
    @KolomPreference("kolomTheme") var theme = "Light"
    @ObservedObject var model: KolomController
    let displayID: String
    var focused: String? { model.workspaces[displayID]?.focus }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Kolom commands").font(.system(size: 13, weight: .medium))
                Spacer()
                Button {
                    model.toggleCommands(displayID)
                } label: {
                    Image(systemName: "sidebar.left")
                }.buttonStyle(.plain).help("Collapse · Option M")
            }.padding(16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    if let id = focused, let w = model.windows[id] {
                        HStack {
                            WindowGlyph(window: w, size: 23)
                            VStack(alignment: .leading) {
                                Text(w.appName).font(.system(size: 12, weight: .medium))
                                Text(w.title).font(.system(size: 10)).lineLimit(2).foregroundColor(.secondary)
                            }
                        }.padding(.bottom, 14)
                        caption("NAVIGATION")
                        command("Previous column", "⌥←") {
                            model.activeDisplay = displayID
                            model.navigate(-1)
                        }
                        command("Next column", "⌥→") {
                            model.activeDisplay = displayID
                            model.navigate(1)
                        }
                        command("Move window…", "⌃⌥K") {
                            model.activeDisplay = displayID
                            model.showPalette?()
                        }
                        caption("ARRANGE")
                        command("Separate from stack", "") { model.unstack(id) }
                        Text("Shared column width").font(.system(size: 11)).padding(.top, 8)
                        Slider(
                            value: Binding(
                                get: {
                                    model.workspaces[displayID]?.columns.first(where: {
                                        $0.tiles.contains(where: { $0.id == id })
                                    })?.width ?? 560
                                }, set: { model.width(id, $0) }),
                            in:
                                260...max(
                                    model.workspaces[displayID]?.columns.first(where: {
                                        $0.tiles.contains(where: { $0.id == id })
                                    })?.width ?? 260,
                                    model.displays.first(where: { $0.id == displayID }).map { model.viewport($0).width }
                                        ?? 1920), step: 20
                        ).accessibilityLabel("Shared column width")
                        if let c = model.workspaces[displayID]?.columnIndex(id),
                            (model.workspaces[displayID]?.columns[c].tiles.count ?? 0) > 1
                        {
                            Text("Window height").font(.system(size: 11)).padding(.top, 8)
                            Slider(
                                value: Binding(
                                    get: {
                                        // Look the column up again: the layout can change before
                                        // SwiftUI reads this binding.
                                        guard
                                            let col = model.workspaces[displayID]?.columns.first(where: {
                                                $0.tiles.contains(where: { $0.id == id })
                                            }), let tile = col.tiles.first(where: { $0.id == id })
                                        else { return 0.5 }
                                        let total = col.tiles.reduce(0) { $0 + $1.weight }
                                        return total > 0 ? min(0.8, max(0.2, tile.weight / total)) : 0.5
                                    },
                                    set: {
                                        if let d = model.displays.first(where: { $0.id == displayID }),
                                            let count = model.workspaces[displayID]?.columns.first(where: {
                                                $0.tiles.contains(where: { $0.id == id })
                                            })?.tiles.count
                                        {
                                            model.height(id, $0 * (model.viewport(d).height - Double(count - 1) * 16))
                                        }
                                    }), in: 0.2...0.8
                            ).accessibilityLabel("Window height within stack")
                        }
                        caption("WINDOW")
                        command("Close window", "") { model.close(id) }
                        if !model.demo { command("Leave this app unmanaged", "") { model.exclude(id) } }
                    }
                    caption("SESSION")
                    command(model.enabled ? "Pause and restore" : "Open settings", "") {
                        if model.enabled { model.pause() } else { model.pause() }
                    }
                    Text("App menus remain in the Mac menu bar. This shelf contains Kolom’s commands.").font(
                        .system(size: 10)
                    ).foregroundColor(.secondary).lineSpacing(4).padding(.top, 15)
                }.padding(14)
            }
        }.frame(width: 224).foregroundColor(.primary).background(KolomSurface(theme: theme)).preferredColorScheme(
            theme == "Light" ? .light : .dark
        ).overlay(alignment: .trailing) { Divider() }
    }
    func caption(_ text: String) -> some View {
        Text(text).font(.system(size: 9, weight: .medium)).tracking(1).foregroundColor(.secondary).padding(.top, 15)
            .padding(.bottom, 4)
    }
    func command(_ title: String, _ key: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                Text(key).foregroundColor(.secondary).font(.system(size: 10))
            }.font(.system(size: 11)).padding(.vertical, 7).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}
struct DisplayDrop: DropDelegate {
    let model: KolomController
    let displayID: String
    func validateDrop(info: DropInfo) -> Bool { model.draggedID != nil }
    func dropEntered(info: DropInfo) { model.dropDisplay = displayID }
    func dropExited(info: DropInfo) { if model.dropDisplay == displayID { model.dropDisplay = nil } }
    func performDrop(info: DropInfo) -> Bool {
        guard let source = model.draggedID else { return false }
        model.transfer(source, to: displayID)
        model.draggedID = nil
        model.dropDisplay = nil
        return true
    }
}
