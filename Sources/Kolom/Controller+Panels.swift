import AppKit
import ApplicationServices
import SwiftUI
import KolomCore

/// Room beside the rail for Performance, the Disk Map, the guide and commands.
extension KolomController {
    /// As wide as leaves a usable column beside it, within 520–1200 points.
    func diskMapWidth(_ display: DisplayModel) -> Double {
        max(520, min(1200, display.frame.width - 48 - performanceWidth - 400))
    }
    func openDiskMap(_ target: DiskMapModel.Target) {
        if performanceDisplay == nil { togglePerformance() }
        diskMap = target
        if enabled, let id = performanceDisplay, let d = displays.first(where: { $0.id == id }),
            let focus = workspaces[id]?.focus
        {
            workspaces[id]?.reveal(focus, viewportWidth: viewport(d).width)
        }
        apply()
    }
    func closeDiskMap() {
        guard diskMap != nil else { return }
        diskMap = nil
        apply()
    }
    /// The widest column a display can show whole: its viewport without side panels,
    /// so opening the guide or Performance never narrows the remembered widths.
    func maxColumnWidth(_ display: DisplayModel) -> Double { max(260, display.frame.width - 48 - 32) }
    func viewport(_ display: DisplayModel) -> CGRect {
        var shelf: Double =
            performanceDisplay == display.id || guideDisplay == display.id
            ? performanceWidth : (commandDisplay == display.id ? 224 : 0)
        if diskMapShown, performanceDisplay == display.id { shelf += diskMapWidth(display) }
        return CGRect(
            x: display.frame.minX + 48 + shelf + 16, y: display.frame.minY + 16,
            width: max(260, display.frame.width - 48 - shelf - 32), height: max(160, display.frame.height - 32))
    }
    func togglePerformance(_ displayID: String? = nil) {
        let target = displayID ?? pointerDisplay()?.id ?? displays.first?.id
        guard let target else { return }
        performanceDisplay = performanceDisplay == target ? nil : target
        if performanceDisplay == nil { diskMap = nil }
        guideDisplay = nil
        commandDisplay = nil
        if enabled, let d = displays.first(where: { $0.id == target }), let id = workspaces[target]?.focus {
            workspaces[target]?.reveal(id, viewportWidth: viewport(d).width)
        }
        apply()
    }
    /// The guide shares Performance's place beside the rail; one of them shows at a time.
    func toggleGuide(_ displayID: String? = nil) {
        let target = displayID ?? pointerDisplay()?.id ?? displays.first?.id
        guard let target else { return }
        guideDisplay = guideDisplay == target ? nil : target
        performanceDisplay = nil
        diskMap = nil
        commandDisplay = nil
        if enabled, let d = displays.first(where: { $0.id == target }), let id = workspaces[target]?.focus {
            workspaces[target]?.reveal(id, viewportWidth: viewport(d).width)
        }
        apply()
    }
    func toggleCommands(_ displayID: String? = nil) {
        performanceDisplay = nil
        diskMap = nil
        guideDisplay = nil
        let d = displayID ?? activeDisplay
        commandDisplay = commandDisplay == d ? nil : d
        if let display = displays.first(where: { $0.id == d }), let id = workspaces[d]?.focus {
            workspaces[d]?.reveal(id, viewportWidth: viewport(display).width)
        }
        apply()
    }
}
