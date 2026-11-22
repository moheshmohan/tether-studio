import Foundation

/// Erasing the camera's memory card: every file on it, for good.
///
/// Only a card mounted as a disk can be erased (the camera on a USB cable in Mass Storage mode, or the
/// card in a reader). Over phone control the camera offers no way to delete: its card session lists
/// no DeleteObject (0x100B) or FormatStore (0x100F) (checked 22 Nov 2026), and the camera's own
/// "format" control (0xD2CA) stays unused, since what it does over this link is not known.
///
/// An erase needs a plan first (what is on the card, and what of it is not on this Mac), shown to a
/// person who types `confirmWord`; it then deletes only what the plan listed at the top of the card,
/// after checking the disk again. Nothing on the Mac's own disks is ever touched.
enum CardWipe {
    static let confirmWord = "ERASE"
    /// Made by macOS on any disk it mounts; it manages them itself.
    static let systemNames: Set<String> = [".Spotlight-V100", ".fseventsd", ".Trashes", ".TemporaryItems", ".DS_Store"]
    /// A camera card is far smaller; anything larger is not taken for one.
    static let largestCard: Int64 = 2_000_000_000_000

    /// What is known about a disk, from macOS.
    struct VolumeFacts: Equatable {
        /// Unknown for a disk image; true for a card in a Mac's own SD slot (removable media there).
        var isInternal: Bool?
        var isRemovableMedia: Bool
        var isEjectableOrRemovable: Bool
        var isRootVolume: Bool
        var capacity: Int64?
        var name: String

        static func read(_ volume: URL) -> VolumeFacts {
            let keys: Set<URLResourceKey> = [.volumeIsInternalKey, .volumeIsEjectableKey, .volumeIsRemovableKey,
                                             .volumeIsRootFileSystemKey, .volumeTotalCapacityKey, .volumeNameKey]
            let v = try? volume.resourceValues(forKeys: keys)
            return VolumeFacts(isInternal: v?.volumeIsInternal,
                               isRemovableMedia: v?.volumeIsRemovable ?? false,
                               isEjectableOrRemovable: (v?.volumeIsEjectable ?? false) || (v?.volumeIsRemovable ?? false),
                               isRootVolume: v?.volumeIsRootFileSystem ?? true,
                               capacity: v?.volumeTotalCapacity.map(Int64.init),
                               name: v?.volumeName ?? volume.lastPathComponent)
        }
    }

    enum Refusal: LocalizedError, Equatable {
        case phoneControl
        case noCard
        case notACard(String)
        case changed

        var errorDescription: String? {
            switch self {
            case .phoneControl:
                return "The camera does not allow deleting over Wi-Fi. To erase the card: connect the USB cable with the camera in Mass Storage mode, or put the card in a card reader. On the camera itself: MENU → Setup → Format."
            case .noCard:
                return "No camera card is mounted on this Mac."
            case .notACard(let why):
                return "This disk is not taken for the camera's card (\(why)); nothing was deleted."
            case .changed:
                return "The card changed since the erase was confirmed; nothing more was deleted."
            }
        }
    }

    /// What an erase would delete.
    struct Plan: Equatable, Identifiable {
        let volume: URL
        let volumeName: String
        /// The items at the top of the card that are deleted (folders with all they hold, and files).
        let items: [URL]
        let files: Int
        let bytes: Int64
        let clips: Int
        let photos: Int
        /// Clips and photos on the card with no copy of the same name and size on this Mac.
        let notOnMac: [String]

        var id: String { volume.path }

        var summary: String {
            let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            return "\(files) files (\(size)) on “\(volumeName)”: \(clips) clips, \(photos) photos and the camera's own index files"
        }
    }

    /// Refuses anything that does not look like a camera card mounted from outside this Mac.
    static func check(_ volume: URL, facts: VolumeFacts, volumes: URL = URL(fileURLWithPath: "/Volumes")) throws {
        let parent = volume.standardizedFileURL.deletingLastPathComponent().path
        guard parent == volumes.standardizedFileURL.path, volume.standardizedFileURL.lastPathComponent != "" else {
            throw Refusal.notACard("not a disk mounted under \(volumes.path)")
        }
        guard !facts.isRootVolume else { throw Refusal.notACard("it is this Mac's start-up disk") }
        guard facts.isEjectableOrRemovable else { throw Refusal.notACard("it cannot be ejected") }
        guard facts.isInternal != true || facts.isRemovableMedia else { throw Refusal.notACard("it is a fixed disk inside this Mac") }
        if let capacity = facts.capacity, capacity > largestCard { throw Refusal.notACard("it is larger than any camera card") }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: volume.appendingPathComponent(CardVolume.clipFolder).path, isDirectory: &isDir),
              isDir.boolValue else {
            throw Refusal.notACard("it has no \(CardVolume.clipFolder) folder")
        }
    }

    /// Looks at the card and lists what an erase would delete. `isOnMac` says whether a clip or photo
    /// has a copy here.
    static func plan(_ volume: URL, facts: VolumeFacts, volumes: URL = URL(fileURLWithPath: "/Volumes"),
                     isOnMac: (ClipFile) -> Bool) throws -> Plan {
        try check(volume, facts: facts, volumes: volumes)
        let fm = FileManager.default
        let top = try fm.contentsOfDirectory(at: volume, includingPropertiesForKeys: nil)
            .filter { !systemNames.contains($0.lastPathComponent) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var files = 0
        var bytes: Int64 = 0
        for item in top {
            let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            if values?.isDirectory == true {
                let walker = fm.enumerator(at: item, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey])
                while let url = walker?.nextObject() as? URL {
                    let v = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                    if v?.isRegularFile == true { files += 1; bytes += Int64(v?.fileSize ?? 0) }
                }
            } else {
                files += 1
                bytes += Int64(values?.fileSize ?? 0)
            }
        }
        let media = CardVolume.list(volume)
        return Plan(volume: volume, volumeName: facts.name, items: top, files: files, bytes: bytes,
                    clips: media.filter(\.isVideo).count, photos: media.filter { !$0.isVideo }.count,
                    notOnMac: media.filter { !isOnMac($0) }.map(\.name))
    }

    /// Deletes what `plan` listed, after checking the disk again. Returns how many items went and
    /// the ones that could not be deleted.
    static func erase(_ plan: Plan, facts: VolumeFacts, typed: String, volumes: URL = URL(fileURLWithPath: "/Volumes"),
                      progress: (Int, Int) -> Void) throws -> (deleted: Int, failed: [String]) {
        guard typed.trimmingCharacters(in: .whitespacesAndNewlines) == confirmWord else {
            throw Refusal.notACard("the confirmation was not typed")
        }
        try check(plan.volume, facts: facts, volumes: volumes)
        let fm = FileManager.default
        var deleted = 0
        var failed: [String] = []
        for (n, item) in plan.items.enumerated() {
            // Only what sits directly on this card, as listed when the erase was confirmed.
            guard item.deletingLastPathComponent().standardizedFileURL.path == plan.volume.standardizedFileURL.path else {
                throw Refusal.changed
            }
            progress(n, plan.items.count)
            guard fm.fileExists(atPath: item.path) else { continue }
            do {
                try fm.removeItem(at: item)
                deleted += 1
            } catch {
                failed.append("\(item.lastPathComponent): \(error.localizedDescription)")
            }
        }
        progress(plan.items.count, plan.items.count)
        return (deleted, failed)
    }
}
