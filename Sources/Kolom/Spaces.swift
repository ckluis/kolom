import AppKit

/// Which Space each display shows. macOS has no public API for this; the
/// WindowServer's own (SkyLight, the one yabai and Amethyst read) is looked up at
/// run time. Without it Kolom keeps its older behaviour: a Space change pauses.
enum Spaces {
    struct Display {
        /// The Space it shows now.
        let current: UInt64
        /// Every Space it has, to tell "elsewhere" from "gone".
        let all: Set<UInt64>
    }

    private typealias Connection = @convention(c) () -> Int32
    private typealias CopySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private static let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    private static let connection: Connection? = symbol("SLSMainConnectionID") ?? symbol("CGSMainConnectionID")
    private static let copySpaces: CopySpaces? =
        symbol("SLSCopyManagedDisplaySpaces") ?? symbol("CGSCopyManagedDisplaySpaces")

    private static func symbol<T>(_ name: String) -> T? {
        guard let skyLight, let pointer = dlsym(skyLight, name) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }

    static var available: Bool { connection != nil && copySpaces != nil }

    /// By display UUID (the ids Kolom uses for displays); nil when unavailable.
    /// With "Displays have separate Spaces" off, every display reports the shared Space.
    static func current() -> [String: Display]? {
        guard let connection, let copySpaces,
            let list = copySpaces(connection())?.takeRetainedValue() as? [[String: Any]]
        else { return nil }
        var result: [String: Display] = [:]
        for entry in list {
            guard let id = entry["Display Identifier"] as? String,
                let current = ((entry["Current Space"] as? [String: Any])?["ManagedSpaceID"] as? NSNumber)?.uint64Value
            else { continue }
            let all = (entry["Spaces"] as? [[String: Any]] ?? []).compactMap {
                ($0["ManagedSpaceID"] as? NSNumber)?.uint64Value
            }
            result[id] = Display(current: current, all: Set(all).union([current]))
        }
        // "Main" stands for every display when Spaces are shared.
        if let shared = result["Main"] {
            for screen in NSScreen.screens {
                if let id = uuid(screen), result[id] == nil { result[id] = shared }
            }
        }
        return result.isEmpty ? nil : result
    }

    static func uuid(_ screen: NSScreen) -> String? {
        guard
            let number = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value,
            let uuid = CGDisplayCreateUUIDFromDisplayID(number)?.takeRetainedValue()
        else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }
}
