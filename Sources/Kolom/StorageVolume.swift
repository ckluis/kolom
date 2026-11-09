import AppKit
import DiskArbitration
import Darwin
import KolomCore

/// A mounted disk as the storage view lists it.
struct StorageVolume: Identifiable, Equatable {
    let url: URL
    let name: String
    let total: UInt64
    /// Available for important use, as Finder counts it (purgeable space included).
    let available: UInt64
    let kind: String
    let startup: Bool
    var id: String { url.path }
    var used: UInt64 { total > available ? total - available : 0 }
    var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }

    static func mounted() -> [StorageVolume] {
        let keys: [URLResourceKey] = [
            .volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey, .volumeIsInternalKey, .volumeIsLocalKey,
            .volumeIsRootFileSystemKey, .volumeIsRemovableKey,
        ]
        let session = DASessionCreate(kCFAllocatorDefault)
        let volumes = (FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [
            .skipHiddenVolumes
        ]) ?? []).compactMap { url -> StorageVolume? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                let total = values.volumeTotalCapacity, total > 0
            else { return nil }
            let available =
                values.volumeAvailableCapacityForImportantUsage.map { UInt64(max(0, $0)) }
                ?? UInt64(max(0, values.volumeAvailableCapacity ?? 0))
            let startup = values.volumeIsRootFileSystem ?? (url.path == "/")
            return StorageVolume(
                url: url, name: values.volumeName ?? url.lastPathComponent, total: UInt64(total),
                available: min(available, UInt64(total)),
                kind: kind(of: url, session: session, isInternal: values.volumeIsInternal, local: values.volumeIsLocal,
                    removable: values.volumeIsRemovable, startup: startup),
                startup: startup)
        }
        // The startup disk first, then the rest by name.
        return volumes.sorted { ($0.startup ? 0 : 1, $0.name) < ($1.startup ? 0 : 1, $1.name) }
    }

    private static func kind(
        of url: URL, session: DASession?, isInternal: Bool?, local: Bool?, removable: Bool?, startup: Bool
    ) -> String {
        if startup { return "Startup disk" }
        if local == false { return "Network" }
        if let session, let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url as CFURL),
            let description = DADiskCopyDescription(disk) as? [String: Any]
        {
            let model = description[kDADiskDescriptionDeviceModelKey as String] as? String ?? ""
            let transport = description[kDADiskDescriptionDeviceProtocolKey as String] as? String ?? ""
            if model.localizedCaseInsensitiveContains("disk image") || transport == "Virtual Interface" {
                return "Disk image"
            }
            if !transport.isEmpty, isInternal != true { return "External · \(transport)" }
        }
        if isInternal == true { return "Internal" }
        return removable == true ? "Removable" : "External"
    }
}
