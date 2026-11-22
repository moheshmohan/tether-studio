import Foundation

/// Parsers for gphoto2's human-readable CLI output.
/// Formats verified live against a Sony ZV-E10, gphoto2 2.5.32.
enum GPhotoParser {

    /// `--auto-detect` table → connection mode.
    static func parseAutoDetect(_ text: String) -> CameraMode {
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("Model") || line.hasPrefix("-") { continue }
            if line.contains("(Control)") { return .pcRemote }
            if line.contains("usb:") { return .mtp }
        }
        return .disconnected
    }

    /// Parse concatenated `--get-config` blocks (each terminated by `END`),
    /// zipped positionally with the requested paths.
    static func parseConfigBlocks(_ text: String, paths: [String]) -> [String: CameraConfig] {
        var blocks: [[String]] = []
        var currentBlock: [String] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line == "END" {
                if !currentBlock.isEmpty { blocks.append(currentBlock) }
                currentBlock = []
            } else if !line.isEmpty {
                currentBlock.append(line)
            }
        }
        if !currentBlock.isEmpty { blocks.append(currentBlock) }

        var result: [String: CameraConfig] = [:]
        for (i, block) in blocks.enumerated() {
            guard i < paths.count else { break }
            if let cfg = parseConfig(block: block, path: paths[i]) {
                result[paths[i]] = cfg
                result[CameraService.leaf(of: paths[i])] = cfg
            }
        }
        return result
    }

    static func parseConfig(block: [String], path: String) -> CameraConfig? {
        var label = "", type = "", current: String?
        var readOnly = false
        var options: [ConfigOption] = []
        var bottom: Double?, top: Double?, step: Double?

        for line in block {
            if line.hasPrefix("Label:") { label = fieldValue(line) }
            else if line.hasPrefix("Readonly:") { readOnly = fieldValue(line) == "1" }
            else if line.hasPrefix("Type:") { type = fieldValue(line) }
            else if line.hasPrefix("Current:") { current = fieldValue(line) }
            else if line.hasPrefix("Bottom:") { bottom = Double(fieldValue(line)) }
            else if line.hasPrefix("Top:") { top = Double(fieldValue(line)) }
            else if line.hasPrefix("Step:") { step = Double(fieldValue(line)) }
            else if line.hasPrefix("Choice:") {
                let v = fieldValue(line)
                if let sp = v.firstIndex(of: " ") {
                    let idx = Int(v[..<sp]) ?? -1
                    let val = String(v[v.index(after: sp)...]).trimmingCharacters(in: .whitespaces)
                    if idx >= 0 { options.append(ConfigOption(index: idx, value: val)) }
                }
            }
        }
        guard !label.isEmpty, !type.isEmpty else { return nil }
        return CameraConfig(path: path, label: label, type: type, readOnly: readOnly,
                            current: current, options: options,
                            bottom: bottom, top: top, step: step)
    }

    /// `--list-files` → clips.
    static func parseListFiles(_ text: String) -> [ClipFile] {
        var clips: [ClipFile] = []
        var currentFolder = ""
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("There are"), let f = folder(in: line) {
                currentFolder = f
                continue
            }
            guard line.hasPrefix("#") else { continue }
            if let clip = parseFileLine(line, folder: currentFolder) { clips.append(clip) }
        }
        return clips
    }

    // MARK: - private helpers

    private static func fieldValue(_ line: String) -> String {
        guard let idx = line.firstIndex(of: ":") else { return "" }
        return String(line[line.index(after: idx)...]).trimmingCharacters(in: .whitespaces)
    }

    private static func folder(in line: String) -> String? {
        guard let open = line.firstIndex(of: "'"),
              let close = line.lastIndex(of: "'"), open < close else { return nil }
        return String(line[line.index(after: open)..<close])
    }

    /// Line shape: `#7     DSC00324.JPG   rd 9923 KB 6000x3376 image/jpeg 1695453566`
    private static func parseFileLine(_ line: String, folder: String) -> ClipFile? {
        let tokens = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard tokens.count >= 5, tokens[0].hasPrefix("#"),
              let number = Int(tokens[0].dropFirst()) else { return nil }
        let name = tokens[1]

        // tokens[2] = flags ("rd"); size starts at 3
        var size: UInt64 = 0
        var i = 3
        if i < tokens.count, let n = Double(tokens[i]) {
            var mult: Double = 1
            i += 1
            if i < tokens.count, ["B", "KB", "MB", "GB", "TB"].contains(tokens[i]) {
                switch tokens[i] {
                case "KB": mult = 1_024
                case "MB": mult = 1_048_576
                case "GB": mult = 1_073_741_824
                case "TB": mult = 1_099_511_627_776
                default: mult = 1
                }
                i += 1
            }
            size = UInt64(n * mult)
        }

        var width: Int?, height: Int?
        var mime = ""
        var unix: Int64 = 0
        if let ts = Int64(tokens.last ?? "") { unix = ts }
        for t in tokens[min(i, tokens.count)...] {
            let parts = t.split(separator: "x")
            if parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]) {
                width = w; height = h
            } else if t.contains("/") {
                mime = t
            }
        }
        return ClipFile(number: number, folder: folder, name: name, sizeBytes: size,
                        width: width, height: height, mime: mime, unixTime: unix)
    }
}
