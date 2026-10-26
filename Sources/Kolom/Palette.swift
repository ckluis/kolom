import SwiftUI
import KolomCore
struct PlacementAction: Identifiable {
    let id: String
    let label: String
    let detail: String
    let target: String?
    let placement: Placement?
    let display: String?
}
struct PlacementPalette: View {
    @ObservedObject var model: KolomController
    let dismiss: () -> Void
    @KolomState private var query = ""
    @KolomState private var selected = 0
    @FocusState private var typing: Bool
    let source: String
    var actions: [PlacementAction] {
        var result: [PlacementAction] = []
        for d in model.displays {
            for id in model.workspaces[d.id]?.windowIDs ?? [] where id != source {
                guard let w = model.windows[id] else { continue }
                for edge in Placement.allCases {
                    if edge == .above || edge == .below,
                        let c = model.workspaces[d.id]?.columnIndex(id),
                        model.workspaces[d.id]!.columns[c].tiles.count >= 3,
                        model.workspaces[d.id]?.columns[c].tiles.contains(where: { $0.id == source }) != true
                    {
                        continue
                    }
                    result.append(
                        PlacementAction(
                            id: id + edge.rawValue,
                            label: "\(edge == .above || edge == .below ? "Stack":"Move") \(edge.rawValue) \(w.appName)",
                            detail: "\(w.title) · \(d.name)", target: id, placement: edge, display: nil))
                }
            }
            if model.displayForWindow(source)?.id != d.id {
                result.append(
                    PlacementAction(
                        id: "display" + d.id, label: "Move to \(d.name)",
                        detail: "New horizontal column on this display", target: nil, placement: nil, display: d.id))
            }
        }
        let words = query.lowercased().split(separator: " ")
        return result.filter { action in
            words.allSatisfy { (action.label + " " + action.detail).lowercased().contains($0) }
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "arrow.left.arrow.right").foregroundColor(.secondary)
                TextField("Move or stack this window…", text: $query).textFieldStyle(.plain).font(.system(size: 18))
                    .focused($typing).onSubmit(execute)
                Button("Esc", action: dismiss).buttonStyle(.plain).foregroundColor(.secondary)
            }.padding(20)
            Divider()
            HStack {
                Text("Moving \(model.windows[source]?.appName ?? "window") · \(model.windows[source]?.title ?? "")")
                    .lineLimit(1)
                Spacer()
            }.font(.system(size: 11)).foregroundColor(.secondary).padding(14)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(Array(actions.enumerated()), id: \.element.id) { i, action in
                            Button {
                                run(action)
                            } label: {
                                HStack(spacing: 12) {
                                    if let id = action.target, let w = model.windows[id] {
                                        WindowGlyph(window: w, size: 25)
                                    } else {
                                        Image(systemName: "display").frame(width: 25)
                                    }
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(action.label).font(.system(size: 13))
                                        Text(action.detail).font(.system(size: 10)).foregroundColor(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    if selected == i { Text("↵").foregroundColor(.secondary) }
                                }.padding(12).background(selected == i ? Color.green.opacity(0.13) : Color.clear)
                                    .cornerRadius(7).contentShape(Rectangle())
                            }.buttonStyle(.plain).id(action.id)
                        }
                        if actions.isEmpty {
                            Text("No matching destinations. Try ‘above Safari’ or ‘before Notes’.").font(
                                .system(size: 12)
                            ).foregroundColor(.secondary).padding(30)
                        }
                    }.padding(8)
                }.onChange(of: selected) { i in
                    if actions.indices.contains(i) { proxy.scrollTo(actions[i].id, anchor: .center) }
                }
            }
            Divider()
            HStack {
                Text("↑ ↓  Choose")
                Text("↵  Move")
                Spacer()
                Text("Typed placement · ⌥K asks in plain words")
            }.font(.system(size: 10)).foregroundColor(.secondary).padding(14)
        }.frame(width: 570, height: 480).background(Color(red: 0.96, green: 0.97, blue: 0.93))
            .foregroundColor(.primary).preferredColorScheme(.light)
            .onAppear { typing = true }.onChange(of: query) { _ in selected = 0 }
            .onMoveCommand { direction in
                if direction == .down { selected = min(max(0, actions.count - 1), selected + 1) }
                if direction == .up { selected = max(0, selected - 1) }
            }.onExitCommand(perform: dismiss)
    }
    func execute() {
        guard actions.indices.contains(selected) else { return }
        run(actions[selected])
    }
    func run(_ action: PlacementAction) {
        guard model.acting else {
            dismiss()
            return
        }
        if let d = action.display { model.transfer(source, to: d) }
        if let target = action.target, let edge = action.placement { model.move(source, to: target, placement: edge) }
        dismiss()
    }
}
