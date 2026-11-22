import Foundation

/// The camera's memory card when it is mounted as a disk: the camera on a USB
/// data cable in Mass Storage mode (which is what a ZV-E10 does when PC Remote
/// is set to Wi-Fi), or the card in a reader. Copying from the disk is the
/// fast way to get clips (about 37 MB/s measured on the camera's own USB).
enum CardVolume {
    /// Sony's folder for XAVC S clips, relative to the card's root.
    static let clipFolder = "PRIVATE/M4ROOT/CLIP"
    static let stillFolder = "DCIM"
    private static let videoTypes: Set<String> = ["mp4", "mxf", "mts", "mov"]
    private static let stillTypes: Set<String> = ["jpg", "jpeg", "arw", "hif"]

    /// First mounted volume that has the camera's clip folder.
    static func find(under volumes: URL = URL(fileURLWithPath: "/Volumes")) -> URL? {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: volumes.path) else { return nil }
        for name in names.sorted() {
            let root = volumes.appendingPathComponent(name, isDirectory: true)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: root.appendingPathComponent(clipFolder).path, isDirectory: &isDir), isDir.boolValue {
                return root
            }
        }
        return nil
    }

    /// Clips and stills on the card, newest first.
    static func list(_ root: URL) -> [ClipFile] {
        let fm = FileManager.default
        var found: [ClipFile] = []

        func add(_ url: URL, types: Set<String>, mime: String) {
            guard types.contains(url.pathExtension.lowercased()), !url.lastPathComponent.hasPrefix("."),
                  let attrs = try? fm.attributesOfItem(atPath: url.path) else { return }
            let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
            let modified = (attrs[.modificationDate] as? Date) ?? Date(timeIntervalSince1970: 0)
            found.append(ClipFile(number: 0, folder: url.deletingLastPathComponent().path, name: url.lastPathComponent,
                                  sizeBytes: size, width: nil, height: nil, mime: mime,
                                  unixTime: Int64(modified.timeIntervalSince1970), diskURL: url))
        }

        let clips = root.appendingPathComponent(clipFolder, isDirectory: true)
        for url in (try? fm.contentsOfDirectory(at: clips, includingPropertiesForKeys: nil)) ?? [] {
            add(url, types: videoTypes, mime: "video/mp4")
        }
        let dcim = root.appendingPathComponent(stillFolder, isDirectory: true)
        for folder in (try? fm.contentsOfDirectory(at: dcim, includingPropertiesForKeys: nil)) ?? [] {
            for url in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
                add(url, types: stillTypes, mime: url.pathExtension.lowercased() == "arw" ? "image/x-sony-arw" : "image/jpeg")
            }
        }
        // By time, and by name within the same second: the camera's clock may be unset.
        return found.sorted { ($0.unixTime, $0.name) > ($1.unixTime, $1.name) }
    }

    /// Copies one file; an existing copy of the same size is kept as it is.
    static func copy(_ clip: ClipFile, to directory: URL) throws -> URL {
        guard let source = clip.diskURL else { throw CameraError.failed("not a file on a mounted card") }
        // Nothing that is already here is deleted or overwritten (see CopyTarget); the copy is
        // made under a temporary name so an interrupted one never looks complete.
        let dest: URL, partial: URL
        switch try CopyTarget.plan(name: clip.name, size: clip.sizeBytes, in: directory) {
        case .alreadyHere(let url): return url
        case .copy(let to, let part): (dest, partial) = (to, part)
        }
        try CopyTarget.ensureRoom(for: clip.sizeBytes, name: clip.name, in: directory)
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        if fm.fileExists(atPath: partial.path, isDirectory: &isDirectory) {
            // Only ever this app's own unfinished copy of this very file.
            guard !isDirectory.boolValue, partial.lastPathComponent.hasPrefix("."), partial.pathExtension == "part" else {
                throw CameraError.failed("\(partial.path) is in the way")
            }
            try fm.removeItem(at: partial)
        }
        try fm.copyItem(at: source, to: partial)
        try CopyTarget.finish(partial: partial, dest: dest)
        return dest
    }
}
