import SwiftUI

/// How Performance groups and measures, opened from the (?) beside its title instead
/// of sitting under the table.
struct PerformanceHelp: View {
    let theme: String
    let unreadable: Int
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("How Performance works").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button(action: close) { Image(systemName: "xmark").font(.system(size: 11)).padding(6) }
                    .buttonStyle(.plain).foregroundColor(.secondary).help("Close · Escape")
                    .accessibilityLabel("Close help")
            }.padding(.horizontal, 20).padding(.vertical, 16).overlay(alignment: .bottom) { Divider() }
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    section(
                        "Rows", "square.stack.3d.up",
                        [
                            "**Apps** hold every process macOS holds them responsible for, as Activity Monitor groups them: a terminal’s shells and what they run, a browser’s tabs, AutoFill.",
                            "Unfold an app for its **sessions**, named by shell and folder (`zsh · kolom`), then a session for its **process tree**, with PIDs and folders.",
                            "**Left running**: programs whose terminal session has closed while they kept going, such as a forgotten dev server.",
                            "**Widgets & extensions**: macOS keeps them loaded even while their apps are closed (Stocks, Podcasts, Quick Look thumbnails).",
                            "**WindowServer, Spotlight indexing, Time Machine, Photo & media analysis** have rows of their own: the usual reasons a Mac feels slow. The rest of macOS shares one row.",
                            "**Web Content** processes are Safari’s tabs, frames and extensions; macOS does not say which tab each one is.",
                        ])
                    section(
                        "Numbers", "gauge.with.dots.needle.33percent",
                        [
                            "**CPU** is a share of the whole Mac: 100% is every core busy. Activity Monitor shows a share of one core, so its numbers are \(ProcessInfo.processInfo.activeProcessorCount)× these.",
                            "**GPU** is each app’s share of GPU time, as the GPU accounts it. Engines run side by side, so shares can add up past the GPU widget.",
                            "**Memory** is physical footprint; shared memory can be counted in more than one app.",
                            "**Network** per app is measured when you click its column, for a minute: Apple’s nettop, which counts it, uses about one CPU core while it runs. Processes without traffic show 0. The total in the NETWORK panel is always on and costs nothing.",
                            "**DisplayLink** screens cost work in DisplayLink’s own app and in WindowServer, which draws them; sort by GPU or CPU and read both.",
                            "Charts hold two minutes of real samples; a gap is a missing reading, never a guess.",
                        ])
                    section(
                        "Quitting and stopping", "stop.circle",
                        [
                            "Right-click a row. **Quit** asks an app to quit as its own menu would (it may ask to save); **Force Quit** ends it at once.",
                            "**Stop** asks a session, group or process to end (SIGTERM, as closing its terminal would); an interactive shell may ignore it. **Force Stop** ends it at once.",
                            "Every action asks first and lists what it stops. Only your own processes outside macOS are offered, never Kolom’s.",
                        ])
                    section(
                        "Storage", "internaldrive",
                        [
                            "The Storage panel shows the startup disk’s free space. Click it for every mounted disk; open one, or choose a folder, for the **Disk Map**: a treemap of what fills it.",
                            "In the map, colour is the kind of data and a hatch is space that can be had back (caches, build output, logs). Double-click or Enter goes in, Backspace goes up, arrows and Tab move, ⌘[ ⌘] go back and forward.",
                            "Space marks what is under the pointer (⌘-click too); **Review…** lists it, then **Move to Trash**. Your home, its standard folders and macOS can’t be marked.",
                            "A scan reads sizes only, never contents, on one disk, and never opens cloud-only folders. It runs only while the map is open; closing it frees what it held.",
                            "macOS may ask before Kolom looks inside Desktop, Documents, Downloads or a removable disk. Folders it protects (Mail, Messages, other apps’ data) count as unreadable unless Kolom has Full Disk Access.",
                        ])
                    section(
                        "Where the numbers come from", "lock.shield",
                        [
                            "Process counters (libproc), the GPU’s own statistics (IOKit), and Apple’s `ps` (for macOS’s own processes) while this panel is open; `nettop` only during a network measurement you start.",
                            "Nothing runs while Performance is closed, nothing needs administrator access, and nothing leaves the Mac.",
                            "The kernel (kernel_task, which also runs drivers such as USB and DisplayLink’s) cannot be read without administrator access."
                                + (unreadable > 0 ? " \(unreadable) processes exited before they could be read." : ""),
                        ])
                }.padding(20)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(KolomSurface(theme: theme))
        .overlay(alignment: .leading) { Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1) }
        .shadow(color: .black.opacity(0.18), radius: 18, x: -4)
    }

    private func section(_ title: String, _ symbol: String, _ points: [String]) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(title, systemImage: symbol).font(.system(size: 12, weight: .semibold))
            ForEach(points, id: \.self) { point in
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Circle().fill(Color.secondary.opacity(0.6)).frame(width: 3.5, height: 3.5).offset(y: -2)
                    Text(.init(point)).font(.system(size: 11)).foregroundColor(.primary.opacity(0.82))
                        .lineSpacing(2.5).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
