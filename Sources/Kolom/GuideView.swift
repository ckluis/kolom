import AppKit
import KolomCore
import SwiftUI

/// What the guide can ask the app to do.
struct GuideActions {
    var requestAccess: () -> Void
    var checkAccess: () -> Void
    var start: () -> Void
    var ask: (String) -> Void
    var toggleAgent: () -> Void
    var agentEnabled: () -> Bool
    var close: () -> Void
}

/// The built-in setup and usage guide: a sidebar beside the rail, toggled by
/// the rail's (?) button like Performance. Also opens on first launch.
struct GuideView: View {
    enum Section: String, CaseIterable, Identifiable {
        case start = "Start", ask = "Ask", moves = "Moves", displays = "Displays", agents = "Agents", help = "Help"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .start: "checklist"
            case .ask: "sparkles"
            case .moves: "hand.draw"
            case .displays: "display.2"
            case .agents: "terminal"
            case .help: "lifepreserver"
            }
        }
    }
    @ObservedObject var model: KolomController
    let actions: GuideActions
    @KolomPreference("kolomTheme") private var theme = "Light"
    @KolomState var section: Section = .start
    @KolomState var agentEnabled = false
    @KolomState var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 16) { content }
                    .padding(22).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(KolomSurface(theme: theme)).foregroundColor(.primary)
        .preferredColorScheme(theme == "Light" ? .light : .dark)
        .overlay(alignment: .trailing) { Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1) }
        .onAppear { agentEnabled = actions.agentEnabled() }
        .onExitCommand(perform: actions.close)
    }

    var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Guide").font(.system(size: 22, weight: .semibold, design: .rounded))
                    Text("Set up Kolom and learn the moves.").font(.system(size: 11)).foregroundColor(.secondary)
                }
                Spacer()
                Button(action: actions.close) { Image(systemName: "sidebar.left").font(.system(size: 15)).padding(7) }
                    .buttonStyle(.plain).help("Close guide · Escape").accessibilityLabel("Close guide")
            }
            HStack(spacing: 4) {
                ForEach(Section.allCases) { item in
                    Button {
                        section = item
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: item.symbol).font(.system(size: 14))
                            Text(item.rawValue).font(.system(size: 11, weight: section == item ? .semibold : .regular))
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 9).fill(
                                section == item ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.04)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(item.rawValue)
                }
            }
        }
        .padding(20)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 1) }
    }

    @ViewBuilder var content: some View {
        switch section {
        case .start: start
        case .ask: ask
        case .moves: moves
        case .displays: displays
        case .agents: agents
        case .help: help
        }
    }

    // MARK: Sections

    @ViewBuilder var start: some View {
        title("Welcome to Kolom", "Your windows, in columns: a strip that scrolls sideways, one per display.")
        step(1, "Allow window control", done: model.permissionGranted,
            detail: model.permissionGranted
                ? "Kolom can move and resize windows."
                : "Turn on Kolom in System Settings → Privacy & Security → Accessibility.") {
            if !model.permissionGranted {
                Button("Open Privacy & Security") { actions.requestAccess() }.buttonStyle(GuideButton(prominent: true))
                Button("Check again") { actions.checkAccess() }.buttonStyle(GuideButton())
            }
        }
        step(2, "Start managing windows", done: model.enabled,
            detail: model.enabled
                ? "Kolom is arranging \(model.windows.count) windows on \(model.displays.count) display\(model.displays.count == 1 ? "" : "s")."
                : "Kolom starts by itself once it has access, or start it here.") {
            if !model.enabled {
                Button("Start") { actions.start() }.buttonStyle(GuideButton(prominent: true)).disabled(!model.permissionGranted)
            }
        }
        step(3, "Ask for what you want · ⌥K", done: false,
            detail: AskInterpreter.unavailableReason
                ?? "Type “3×2 terminals” or “focus Safari”. Apple's on-device model understands it.") {
            if AskInterpreter.unavailableReason == nil {
                Button("Try “3×2 terminals”") { actions.ask("3×2 terminals") }.buttonStyle(GuideButton(prominent: true))
            }
            Button("More examples") { section = .ask }.buttonStyle(GuideButton())
        }
        step(4, "Learn the moves", done: false,
            detail: "Swipe two fingers sideways to scroll. ⌥← ⌥→ step between columns. ⌥D shows the desktop.") {
            Button("All shortcuts") { section = .moves }.buttonStyle(GuideButton())
        }
        note("Reopen this guide with the ? above the readings in any rail, or from the menu bar icon.")
    }

    @ViewBuilder var ask: some View {
        title("Ask Kolom · ⌥K", "Say what you want in plain words. Apple's on-device model turns it into one Kolom action. Nothing leaves this Mac; no account or subscription.")
        if let reason = AskInterpreter.unavailableReason {
            card("Not available on this Mac", symbol: "exclamationmark.triangle") {
                Text(reason)
                Text("Everything else in Kolom works without it.").foregroundStyle(.secondary)
            }
        }
        card("Try one", symbol: "sparkles") {
            examples([
                "3×2 terminals on screen \(screens.count > 1 ? 2 : 1)", "8 terminals", "show the desktop",
                "focus Safari", "next column", "move this window to screen 1", "dark theme", "undo that grid",
            ])
        }
        card("Your screens", symbol: "display.2") {
            Text("Screens are numbered left to right as they stand on your desk.").foregroundStyle(.secondary)
            ForEach(Array(screens.enumerated()), id: \.offset) { index, name in
                Text("\(index + 1)  \(name)").font(.system(size: 13, weight: .medium))
            }
        }
        note("Kolom checks every answer before it runs: sizes you type are kept exactly, grids stop at 60 windows, and anything it is unsure of is explained instead of guessed.")
    }

    @ViewBuilder var moves: some View {
        title("Moves", "The strip scrolls; your windows stay where you put them.")
        subheading("Get around")
        keys([
            ("Two-finger swipe", "scroll the strip under the pointer"),
            ("⌥ or ⇧ + wheel", "scroll with a mouse"),
            ("⌥← / ⌥→", "previous / next column"),
            ("⌥1 … ⌥9", "focus a window"),
            ("⌥D", "the desktop (or scroll past the end)"),
            ("⌥K", "Ask Kolom"),
        ])
        subheading("Arrange")
        keys([
            ("Drag an icon onto another", "stack them in one column (up to three); drop on the top or bottom edge to place before or after"),
            ("Drag an icon to another rail", "move the window to that display"),
            ("Drag a column edge", "change its width; drag a divider for heights"),
            ("Right-click a rail icon", "widths, Fill display, Separate, Leave unmanaged, Close"),
            ("⌃⌥K", "arrange the focused window"),
            ("⌥M", "Kolom commands"),
        ])
        note("The readings at the bottom of each rail are CPU, memory and network; click them for Performance.")
    }

    @ViewBuilder var displays: some View {
        title("Displays", "Every monitor keeps its own columns, focus and scroll position.")
        card("Clean edges", symbol: "stairs") {
            Text("While Kolom manages windows it moves your displays corner to corner, so columns slide cleanly off every edge. The pointer still crosses between monitors as on your desk, and your arrangement returns when Kolom pauses or quits (macOS restores it even after a crash).")
            Toggle("Keep displays apart while managing", isOn: Binding(
                get: { model.isolateDisplays }, set: { model.isolateDisplays = $0 }))
        }
        card("Plugging in and out", symbol: "cable.connector") {
            Text("Unplug a monitor and its windows join your main display. Plug it back in and they return.")
        }
        card("Look", symbol: "paintpalette") {
            ThemePicker()
            Text("Wallpaper keeps your picture with clear rails; Light and Dark tint the desktop. Your wallpaper always comes back.")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder var agents: some View {
        title("Agents", "Let Claude Code, Codex or any MCP client read your layout and build it.")
        card("1 · Connect", symbol: "link") {
            Text("Run once in Terminal. Other agents: add the same command as an MCP server.")
            HStack {
                Text(mcpCommand).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
                Button(copied ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(mcpCommand, forType: .string)
                    copied = true
                }
                .buttonStyle(GuideButton())
            }
        }
        card("2 · Allow changes", symbol: "hand.raised") {
            Text("Reading the layout always works. Creating or moving windows needs your OK for this session; it ends when you turn it off or quit Kolom. No shell commands, no network listener.")
            Button(agentEnabled ? "Turn off agent commands" : "Allow agent commands…") {
                actions.toggleAgent()
                agentEnabled = actions.agentEnabled()
            }
            .buttonStyle(GuideButton())
        }
        card("3 · Ask your agent", symbol: "text.bubble") {
            Text("“Make me a 6×3 Terminal grid on my left monitor.”  “What's on my second display?”  “Undo that grid.”")
                .italic()
        }
    }

    @ViewBuilder var help: some View {
        title("Help", "Kolom is alpha software, built so your windows are never stranded.")
        keys([
            ("Pause and Restore", "menu bar icon; every window goes back"),
            ("Quit Kolom", "restores windows, displays and wallpaper"),
            ("If Kolom crashes", "a watchdog restores windows and wallpaper"),
            ("Recover windows", "menu bar icon, after an interrupted session"),
        ])
        note("Public macOS APIs only. No screen capture, no telemetry; Ask Kolom runs on this Mac.")
        link("Kolom on GitHub", "https://github.com/ckluis/kolom", symbol: "star")
        link("Report a problem", "https://github.com/ckluis/kolom/issues/new?template=bug_report.yml", symbol: "ladybug")
        link("Technical guide", "https://github.com/ckluis/kolom/blob/main/docs/GUIDE.md", symbol: "book")
    }

    // MARK: Building blocks

    var mcpCommand: String {
        let linked = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/kolomctl")
        let tool =
            FileManager.default.isExecutableFile(atPath: linked.path)
            ? "~/.local/bin/kolomctl" : Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/kolomctl").path
        return "claude mcp add --scope user kolom -- \(tool) mcp"
    }
    /// Display names in Ask Kolom's numbering.
    var screens: [String] {
        askDisplayOrder(model.displays.map { (id: $0.id, frame: model.deskFrame($0.frame)) }).map { id in
            let name = model.displays.first { $0.id == id }?.name ?? id
            return id == model.displays.first?.id ? "\(name) (main)" : name
        }
    }
    func examples(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(items, id: \.self) { example in
                Button {
                    actions.ask(example)
                } label: {
                    HStack {
                        Text("“\(example)”").font(.system(size: 13))
                        Spacer()
                        Image(systemName: "arrow.up.right").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.05)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).disabled(AskInterpreter.unavailableReason != nil)
            }
        }
    }
    func subheading(_ text: String) -> some View {
        Text(text.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).padding(.top, 4)
    }
    func title(_ heading: String, _ lede: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(heading).font(.system(size: 26, weight: .bold))
            Text(lede).font(.system(size: 14)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 6)
    }
    func step<Buttons: View>(
        _ number: Int, _ heading: String, done: Bool, detail: String, @ViewBuilder buttons: () -> Buttons
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle().fill(done ? Color.green.opacity(0.2) : Color.primary.opacity(0.07)).frame(width: 30, height: 30)
                if done {
                    Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)).foregroundStyle(.green)
                } else {
                    Text("\(number)").font(.system(size: 13, weight: .semibold))
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(heading).font(.system(size: 15, weight: .semibold))
                Text(detail).font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack { buttons() }.controlSize(.regular)
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.035)))
    }
    func card<Body: View>(_ heading: String, symbol: String, @ViewBuilder body: () -> Body) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(heading, systemImage: symbol).font(.system(size: 15, weight: .semibold))
            VStack(alignment: .leading, spacing: 10) { body() }
                .font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.035)))
    }
    func keys(_ rows: [(String, String)]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    Text(row.0).font(.system(size: 13, weight: .semibold)).frame(width: 170, alignment: .leading)
                    Text(row.1).font(.system(size: 13)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 9).padding(.horizontal, 14)
                .background(index % 2 == 0 ? Color.primary.opacity(0.035) : .clear)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
    func note(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
    func link(_ label: String, _ url: String, symbol: String) -> some View {
        Button {
            if let target = URL(string: url) { NSWorkspace.shared.open(target) }
        } label: {
            Label(label, systemImage: symbol).font(.system(size: 14, weight: .medium))
                .padding(.horizontal, 14).padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The guide lives in a panel that never becomes key, where system button
/// styles draw as inactive grey; this keeps the primary action visible.
struct GuideButton: ButtonStyle {
    var prominent = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: prominent ? .semibold : .regular))
            .foregroundColor(prominent ? .white : .primary)
            .padding(.horizontal, 11).padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7).fill(
                    prominent ? Color.accentColor : Color.primary.opacity(configuration.isPressed ? 0.16 : 0.09)))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

/// Writes the same preference as the menu bar's Appearance submenu.
struct ThemePicker: View {
    @KolomPreference("kolomTheme") var theme = "Light"
    var body: some View {
        Picker("Theme", selection: $theme) {
            ForEach(["Light", "Dark", "Wallpaper"], id: \.self) { Text($0) }
        }
        .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 360)
    }
}
