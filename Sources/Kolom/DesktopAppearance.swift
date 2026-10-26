import AppKit

/// Theme the real desktop, retaining a recovery record before the first change.
final class DesktopAppearance {
    struct Original: Codable {
        let url: String
        let fill: Bool?
        let scaling: Int?
        let color: [Double]?
    }
    let record = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Kolom/wallpaper-restore.json")
    var originals: [String: Original] = [:]
    /// The original each display was last restored to, for themed Spaces that
    /// share it but no longer have their own record.
    var lastRestored: [String: Original] = [:]
    var lastRecord: URL { record.deletingLastPathComponent().appendingPathComponent("wallpaper-last.json") }
    var applied: [String: String] = [:]
    static let fallbackWallpaper = URL(fileURLWithPath: "/System/Library/CoreServices/DefaultDesktop.heic")
    init() {
        lastRestored =
            (try? Data(contentsOf: lastRecord)).flatMap {
                try? JSONDecoder().decode([String: Original].self, from: $0)
            }?
            .filter { !isKolomTheme(URL(string: $0.value.url)) } ?? [:]
        if let data = try? Data(contentsOf: record),
            let saved = try? JSONDecoder().decode([String: Original].self, from: data)
        {
            // Earlier builds could record Kolom's own theme image as an "original".
            originals = saved.filter { !isKolomTheme(URL(string: $0.value.url)) }
            restore()
        }
    }
    /// Kolom's generated theme images live in its storage folder (or Ribbon's, before the rename).
    func isKolomTheme(_ url: URL?) -> Bool {
        guard let url, url.isFileURL else { return false }
        let path = url.standardizedFileURL.path
        return [record.deletingLastPathComponent(), RenameMigration.oldStorage].contains {
            path.hasPrefix($0.standardizedFileURL.path + "/")
        }
    }
    /// The display UUID survives reboots and reconnects; CGDirectDisplayID does not.
    func key(_ screen: NSScreen) -> String {
        guard
            let number = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value,
            let uuid = CGDisplayCreateUUIDFromDisplayID(number)?.takeRetainedValue()
        else { return legacyKey(screen) }
        return CFUUIDCreateString(nil, uuid) as String
    }
    func legacyKey(_ screen: NSScreen) -> String {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.stringValue
            ?? screen.localizedName
    }
    /// The record for a screen, migrating records keyed by an old display number.
    func original(for screen: NSScreen) -> Original? {
        let id = key(screen)
        if let value = originals[id] { return value }
        if let value = originals.removeValue(forKey: legacyKey(screen)) {
            originals[id] = value
            return value
        }
        return nil
    }
    func apply(_ theme: String) {
        if theme == "Wallpaper" {
            restore()
            return
        }
        let light = theme == "Light"
        let color =
            light
            ? NSColor(srgbRed: 0.95, green: 0.96, blue: 0.92, alpha: 1)
            : NSColor(srgbRed: 0.10, green: 0.14, blue: 0.12, alpha: 1)
        let url = record.deletingLastPathComponent().appendingPathComponent("theme-\(theme.lowercased()).png")
        if !FileManager.default.fileExists(atPath: url.path) {
            let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            for x in 0..<2 { for y in 0..<2 { bitmap.setColor(color, atX: x, y: y) } }
            guard let data = bitmap.representation(using: .png, properties: [:]) else { return }
            do {
                try FileManager.default.createDirectory(
                    at: record.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
            } catch { return }
        }
        for screen in NSScreen.screens {
            let id = key(screen)
            guard applied[id] != theme else { continue }
            let current = NSWorkspace.shared.desktopImageURL(for: screen)
            // Wallpapers are per Space, records per display. A record plus a different
            // real wallpaper means another Space (or a wallpaper the user changed):
            // theming it would later restore the wrong image onto it, so leave it.
            if let record = original(for: screen), !isKolomTheme(current), current?.absoluteString != record.url {
                continue
            }
            if original(for: screen) == nil, let old = current, !isKolomTheme(old) {
                let options = NSWorkspace.shared.desktopImageOptions(for: screen) ?? [:]
                let c = (options[.fillColor] as? NSColor)?.usingColorSpace(.sRGB)
                originals[id] = Original(
                    url: old.absoluteString, fill: options[.allowClipping] as? Bool,
                    scaling: (options[.imageScaling] as? NSNumber)?.intValue,
                    color: c.map { [$0.redComponent, $0.greenComponent, $0.blueComponent, $0.alphaComponent] })
                guard let data = try? JSONEncoder().encode(originals),
                    (try? data.write(to: record, options: .atomic)) != nil
                else {
                    originals.removeValue(forKey: id)
                    continue
                }
            }
            guard originals[id] != nil else { continue }
            do {
                try NSWorkspace.shared.setDesktopImageURL(
                    url, for: screen,
                    options: [
                        .imageScaling: NSImageScaling.scaleAxesIndependently.rawValue, .allowClipping: true,
                        .fillColor: color,
                    ])
                applied[id] = theme
            } catch {}
        }
    }
    func restore() {
        for screen in NSScreen.screens {
            let id = key(screen)
            // Only undo Kolom's own theme. A screen showing a real wallpaper is on
            // a Space Kolom did not theme (or the user changed it): never overwrite
            // it, and keep the record for when the themed Space is shown again.
            guard isKolomTheme(NSWorkspace.shared.desktopImageURL(for: screen)) else {
                applied.removeValue(forKey: id)
                continue
            }
            guard let old = original(for: screen), let url = URL(string: old.url) else {
                // Never leave a screen on Kolom's theme without a record to undo it:
                // use this display's last restored original, else the macOS default.
                if let last = lastRestored[id], let lastURL = URL(string: last.url) {
                    try? NSWorkspace.shared.setDesktopImageURL(lastURL, for: screen, options: options(last))
                } else {
                    try? NSWorkspace.shared.setDesktopImageURL(Self.fallbackWallpaper, for: screen, options: [:])
                }
                applied.removeValue(forKey: id)
                continue
            }
            let options = options(old)
            do {
                try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: options)
                originals.removeValue(forKey: id)
                applied.removeValue(forKey: id)
                // Another Space themed over the same wallpaper restores to this too.
                lastRestored[id] = old
            } catch {}
        }
        if originals.isEmpty {
            try? FileManager.default.removeItem(at: record)
        } else if let data = try? JSONEncoder().encode(originals) {
            try? data.write(to: record, options: .atomic)
        }
        if let data = try? JSONEncoder().encode(lastRestored) { try? data.write(to: lastRecord, options: .atomic) }
    }
    func options(_ original: Original) -> [NSWorkspace.DesktopImageOptionKey: Any] {
        var options: [NSWorkspace.DesktopImageOptionKey: Any] = [:]
        if let value = original.fill { options[.allowClipping] = value }
        if let value = original.scaling { options[.imageScaling] = value }
        if let c = original.color, c.count == 4 {
            options[.fillColor] = NSColor(srgbRed: c[0], green: c[1], blue: c[2], alpha: c[3])
        }
        return options
    }
}
