import AppKit

/// `TetherStudio --wifi-check [address]`: runs the Wi-Fi search, pairing and
/// connection once, as text, without opening the window. For diagnosing a
/// connection that the app cannot make.
enum WifiCheck {
    static func runIfRequested() {
        let args = CommandLine.arguments
        if args.contains("--board-ports") {
            // What USB says about each serial port; nothing is sent to the devices.
            for p in EspFlasher.ports() { print("\(p.path)\t\(p.label)") }
            exit(0)
        }
        if let port = argument(after: "--board-identify") {
            do {
                let found = try EspFlasher.identify(port: port)
                print("\(port): \(found.chip)\(found.mac.map { ", MAC \($0)" } ?? "")")
                exit(0)
            } catch {
                print("\(port): \(error.localizedDescription)")
                exit(1)
            }
        }
        if let port = argument(after: "--flash-board") {
            // `--flash-board PORT [--expect-mac AA:BB:…]`: writes the bridge program to an ESP32-C3.
            setvbuf(stdout, nil, _IOLBF, 0)
            do {
                let image = try EspFlasher.bundledImage()
                print("image: \(image.bytes.count) bytes, bridge version \(image.version), md5 \(image.md5)")
                var lastTenth = -1
                let out = try EspFlasher.flash(port: port, image: image, expectMAC: argument(after: "--expect-mac")) { step in
                    if case .writing(let f) = step {
                        let tenth = Int(f * 10)
                        if tenth != lastTenth { lastTenth = tenth; print("  writing \(tenth * 10) %") }
                    } else {
                        print("  \(step)")
                    }
                }
                print(String(format: "done: %@, %d bytes in %.1f s", out.mac, out.bytes, out.seconds))
                exit(0)
            } catch {
                print("not flashed: \(error.localizedDescription)")
                exit(1)
            }
        }
        if args.contains("--usb-check") {
            setvbuf(stdout, nil, _IOLBF, 0)
            let done = DispatchSemaphore(value: 0)
            var ok = false
            Task.detached {
                ok = await usbCheck()
                done.signal()
            }
            done.wait()
            exit(ok ? 0 : 1)
        }
        if let i = args.firstIndex(of: "--card-check") {
            setvbuf(stdout, nil, _IOLBF, 0)
            let host = args.count > i + 1 && !args[i + 1].hasPrefix("--") ? args[i + 1] : nil
            let done = DispatchSemaphore(value: 0)
            var ok = false
            Thread.detachNewThread {
                ok = cardCheck(host: host, download: argument(after: "--download"))
                done.signal()
            }
            done.wait()
            exit(ok ? 0 : 1)
        }
        guard let i = args.firstIndex(of: "--wifi-check") else { return }
        let host = args.count > i + 1 && !args[i + 1].hasPrefix("--") ? args[i + 1] : nil
        setvbuf(stdout, nil, _IOLBF, 0)
        let done = DispatchSemaphore(value: 0)
        var ok = false
        Task.detached {
            ok = await run(host: host)
            done.signal()
        }
        done.wait()
        exit(ok ? 0 : 1)
    }

    private static func argument(after flag: String) -> String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: flag), args.count > i + 1 else { return nil }
        return args[i + 1]
    }

    /// Starts the ESP32 bridge from the saved settings and waits until the
    /// board has joined the camera's network.
    private static func startBridge() -> Bool {
        guard !SingleInstance.windowIsOpen() else {
            print("Tether Studio is open and is using the ESP32 board. Close it first: two programs on the board take each other's answers.")
            return false
        }
        let settings = BridgeSettings.load()
        guard settings.usable else {
            print("The ESP32 bridge is not set up: enter the camera's network in the app first.")
            return false
        }
        var state = BridgeState.off
        for _ in 0..<8 {
            state = BridgeController.shared.step(settings)
            if state.isJoined { break }
            Thread.sleep(forTimeInterval: 2)
        }
        print("ESP32 bridge: \(state)")
        return state.isJoined
    }

    /// `TetherStudio --card-check [address[:port]] [--bridge] [--download FOLDER [--get NAME,NAME]] [--dump] [--trace]`:
    /// the card over the camera's phone service, without libgphoto2. One session lists the card;
    /// with --download a second session copies the newest clip (or the named files) into
    /// FOLDER/<clip's folder>/, through the same code the app's download buttons use.
    private static func cardCheck(host: String?, download: String?) -> Bool {
        if CommandLine.arguments.contains("--bridge"), !startBridge() { return false }
        let target = host ?? (CommandLine.arguments.contains("--bridge") ? BridgeController.localHost : EspBridge.cameraFallback)
        let identity = [UInt8](repeating: 0x5A, count: 16)
        var known: [UInt32: CardEntry] = [:]
        let cancel = CancelFlag()
        if CommandLine.arguments.contains("--trace") { PtpIpLink.trace = { print("    | \($0)") } }
        if CommandLine.arguments.contains("--no-read-spacing") { PhoneCard.readSpacing = 0 }    // to show the fault, never for real copies
        do {
            var t = Date()
            var clips: [ClipFile] = []
            do {
                let card = try PhoneCard(host: target, guid: identity, name: "Tether Studio check")
                defer { card.close() }
                print(String(format: "Card session at \(target): open, card showing after %.1f s", Date().timeIntervalSince(t)))
                if let text = argument(after: "--probe-info"), let handle = UInt32(text.replacingOccurrences(of: "0x", with: ""), radix: 16) {
                    // What the camera says about a file before its list has been asked for in this session.
                    do { print("  before listing: \(try card.info(handle))") } catch { print("  before listing: \(error.localizedDescription)") }
                }
                t = Date()
                let entries = try card.list(known: &known, progress: { _, _ in }, cancel: cancel)
                clips = CameraService.clips(from: entries)
                print(String(format: "  %d files, %d clips and stills, listed in %.1f s", entries.count, clips.count, Date().timeIntervalSince(t)))
                for clip in clips.prefix(5) { print("    \(clip.folder)/\(clip.name)  \(clip.sizeLabel)") }
                if CommandLine.arguments.contains("--dump") {       // everything the camera lists, folders included
                    for (handle, e) in known.sorted(by: { $0.key < $1.key }) {
                        print(String(format: "    0x%08X parent 0x%08X %@ %12@ \"%@\" %@", handle, e.parent, e.isFolder ? "folder" : "file  ",
                                     e.size.map(String.init) ?? "?", e.name, e.date))
                    }
                }
                t = Date()
                _ = try card.list(known: &known, progress: { _, _ in }, cancel: cancel)
                print(String(format: "  listed again with the files already known: %.1f s", Date().timeIntervalSince(t)))
                if let name = argument(after: "--probe-reads"), let local = argument(after: "--against"),
                   let clip = clips.first(where: { $0.name == name }), let handle = clip.cameraHandle {
                    try probeReads(card, handle: handle, truth: [UInt8](try Data(contentsOf: URL(fileURLWithPath: local))))
                }
                if let name = argument(after: "--probe-big"), let clip = clips.first(where: { $0.name == name }),
                   let handle = clip.cameraHandle {
                    try probeBig(card, handle: handle, name: name, listed: clip.sizeBytes)
                }
                if let folder = argument(after: "--compare-folder") {
                    compareFolder(clips, with: URL(fileURLWithPath: folder))
                }
                if let name = argument(after: "--compare"), let local = argument(after: "--against"),
                   let clip = clips.first(where: { $0.name == name }), let handle = clip.cameraHandle {
                    try comparePieces(card, handle: handle, size: clip.sizeBytes, local: URL(fileURLWithPath: local))
                }
            }
            guard let download else { return true }

            var wanted: [ClipFile] = []
            if let names = argument(after: "--get")?.split(separator: ",").map(String.init) {
                wanted = names.compactMap { name in clips.first { $0.name == name } }
                guard wanted.count == names.count else {
                    print("Not all of \(names) are on the card.")
                    return false
                }
            } else if let newest = CameraService.newestVideo(clips) {
                wanted = [newest]
            }
            Thread.sleep(forTimeInterval: 0.5)
            let card = try PhoneCard(host: target, guid: identity, name: "Tether Studio check")
            defer { card.close() }
            var done = 0, failed = 0
            var started = Date()
            try CameraService.perform(.download(wanted), on: card, known: &known, root: URL(fileURLWithPath: download),
                                      cancel: cancel) { event in
                switch event {
                case .started: started = Date()
                case .finished(let clip, let url):
                    done += 1
                    let seconds = Date().timeIntervalSince(started)
                    print(String(format: "  copied \(clip.name): \(clip.sizeLabel) in %.1f s = %.2f MB/s, saved to \(url.path)",
                                 seconds, Double(clip.sizeBytes) / 1_000_000 / max(seconds, 0.001)))
                case .failed(let clip, let why):
                    failed += 1
                    print("  NOT copied \(clip.name): \(why)")
                default: break
                }
            }
            return failed == 0 && done == wanted.count
        } catch {
            print("Card check failed: \(error.localizedDescription)")
            return false
        }
    }

    /// `--probe-reads NAME --against LOCALCOPY`: reads pieces of many sizes and positions and compares
    /// each with a copy of the file that is known to be right. Where a piece is wrong, says which part
    /// of the file the camera sent instead.
    private static func probeReads(_ card: PhoneCard, handle: UInt32, truth: [UInt8]) throws {
        func whereIs(_ piece: [UInt8]) -> String {
            guard piece.count >= 64 else { return "too short to place" }
            let needle = Data(piece.prefix(64))
            guard let found = Data(truth).range(of: needle) else { return "not in the file at all" }
            return "the file's bytes from \(found.lowerBound)"
        }
        let size = truth.count
        var wrong = 0, total = 0
        func check(_ offset: Int, _ length: Int, pause: Double = 0) throws {
            if pause > 0 { Thread.sleep(forTimeInterval: pause) }
            let got = try card.read(handle, offset: UInt64(offset), length: length)
            let want = Array(truth[offset..<min(size, offset + length)])
            total += 1
            if got != want {
                wrong += 1
                print("    WRONG: asked \(length) at \(offset): got \(got.count) bytes, \(got.count == want.count ? "" : "wanted \(want.count), ")it is \(whereIs(got))")
            }
        }
        let mb = 1024 * 1024
        if CommandLine.arguments.contains("--race2") {
            // Small reads at scattered positions, by gap between starts and by direction of the jump;
            // then the same hopping between this file and a second one.
            var other: (handle: UInt32, truth: [UInt8])?
            if let spec = argument(after: "--other")?.split(separator: ":", maxSplits: 1).map(String.init), spec.count == 2,
               let h = UInt32(spec[0].replacingOccurrences(of: "0x", with: ""), radix: 16) {
                other = (h, [UInt8](try Data(contentsOf: URL(fileURLWithPath: spec[1]))))
            }
            let piece = Int(argument(after: "--piece") ?? "") ?? 32 * 1024
            for spacing in [0.4, 0.8, 1.2, 2.0] {
                PhoneCard.readSpacing = spacing
                var seed: UInt64 = 0x9E3779B97F4A7C15
                func next(_ limit: Int) -> Int { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int((seed >> 33) % UInt64(limit)) }
                var last = 0, fwd = (0, 0), back = (0, 0), stale = 0
                for _ in 0..<30 {
                    let at = next(size - piece)
                    let ok = try card.read(handle, offset: UInt64(at), length: piece) == Array(truth[at..<(at + piece)])
                    if at >= last { fwd = (fwd.0 + (ok ? 1 : 0), fwd.1 + 1) } else { back = (back.0 + (ok ? 1 : 0), back.1 + 1) }
                    if !ok { stale += 1 }
                    last = at
                }
                var line = String(format: "    %d KB pieces every %.1f s, one file: forward jumps %d/%d right, backward jumps %d/%d right",
                                  piece / 1024, spacing, fwd.0, fwd.1, back.0, back.1)
                if let other {
                    var right = 0, fromOtherFile = 0, wrong = 0
                    var lastAt = 0
                    for i in 0..<30 {
                        let onOther = i % 2 == 1
                        let t = onOther ? other.truth : truth
                        let at = next(t.count - piece)
                        let got = try card.read(onOther ? other.handle : handle, offset: UInt64(at), length: piece)
                        if got == Array(t[at..<(at + piece)]) { right += 1 } else {
                            wrong += 1
                            let previous = onOther ? truth : other.truth
                            if lastAt + piece <= previous.count, got == Array(previous[lastAt..<(lastAt + piece)]) { fromOtherFile += 1 }
                        }
                        lastAt = at
                    }
                    line += String(format: "; hopping between two files %d/30 right", right) + (fromOtherFile > 0 ? " (\(fromOtherFile) were the previous file's data)" : "")
                }
                print(line)
            }
            return
        }
        if CommandLine.arguments.contains("--race") {
            PhoneCard.readSpacing = 0       // this measurement sets its own gaps
            // When is the second of two reads served from the first one's position? Vary the size of both
            // and the gap between the end of the first and the start of the second.
            print("  second read right, out of 12 tries (first size, second size, gap after the first):")
            for (first, second) in [(32 * 1024, 32 * 1024), (32 * 1024, 3 * mb), (3 * mb, 32 * 1024), (mb, mb), (3 * mb, 3 * mb)] {
                var line = "    \(first / 1024) KB then \(second / 1024) KB:"
                for gap in [0.0, 0.02, 0.05, 0.1, 0.2] {
                    var right = 0, stale = 0, other = 0
                    let tries = second >= 3 * mb ? 6 : 12
                    for i in 0..<tries {
                        let a = (i * 2_000_003) % (size - 4 * mb), b = (a + 7 * mb + i * 100_003) % (size - 4 * mb)
                        _ = try card.read(handle, offset: UInt64(a), length: first)
                        if gap > 0 { Thread.sleep(forTimeInterval: gap) }
                        let got = try card.read(handle, offset: UInt64(b), length: second)
                        if got == Array(truth[b..<(b + second)]) { right += 1 }
                        else if got == Array(truth[a..<(a + second)]) { stale += 1 }
                        else { other += 1 }
                        Thread.sleep(forTimeInterval: 0.4)      // a clean start for the next pair
                    }
                    line += String(format: "  %3.0f ms: %d/%d", gap * 1000, right, tries) + (stale > 0 ? " (\(stale) from the first read's position)" : "") + (other > 0 ? " (\(other) other)" : "")
                }
                print(line)
            }
            return
        }
        print("  comparing reads with the local copy (\(size) bytes):")
        for (label, lengths, pause) in [("32 KB pieces, back to back", [32 * 1024], 0.0), ("32 KB pieces, 0.3 s apart", [32 * 1024], 0.3),
                                        ("100 KB to 1 MB pieces", [100_000, 512 * 1024, mb], 0.0), ("3 MB pieces", [3 * mb], 0.0),
                                        ("odd sizes", [1, 511, 4097, 70_001, 2 * mb + 3], 0.0)] {
            let before = (wrong, total)
            for length in lengths {
                for offset in [0, 3 * mb, 1, 12_345_678, 5 * mb + 17, 3 * mb, size - length, 20 * mb, 9 * mb - 1, 0, size / 2] where offset >= 0 && offset < size {
                    try check(offset, length, pause: pause)
                }
            }
            print("    \(label): \(total - before.1 - (wrong - before.0)) of \(total - before.1) right")
        }
        print("  \(total - wrong) of \(total) reads right")
    }

    /// `--compare-folder FOLDER`: is every file the card lists in FOLDER/<its day folder>/, with the same size?
    private static func compareFolder(_ clips: [ClipFile], with root: URL) {
        var here = 0, bytes: UInt64 = 0
        for clip in clips {
            let url = root.appendingPathComponent(clip.dayFolder, isDirectory: true).appendingPathComponent(clip.name)
            let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.uint64Value
            if size == clip.sizeBytes { here += 1; bytes += clip.sizeBytes }
            else { print("    DIFFERENT: \(clip.dayFolder)/\(clip.name): card \(clip.sizeBytes) bytes, here \(size.map(String.init) ?? "missing")") }
        }
        print("  \(here) of \(clips.count) files are in \(root.path) with the size the card gives (\(bytes) bytes)")
    }

    /// `--compare NAME --against LOCALCOPY`: reads 3 MB pieces at places spread over the file (its start,
    /// both sides of 4 GB if it is that long, its end) and compares them with the copy on this Mac.
    /// Unlike `--probe-reads` it does not load the copy into memory, so it works for files of any size.
    private static func comparePieces(_ card: PhoneCard, handle: UInt32, size: UInt64, local: URL) throws {
        let file = try FileHandle(forReadingFrom: local)
        defer { try? file.close() }
        let piece: UInt64 = 3 * 1024 * 1024
        let line: UInt64 = 1 << 32
        var places: [UInt64] = (0..<8).map { size / 8 * $0 / piece * piece }
        if size > line + piece { places += [line - piece, line - piece / 2, line] }
        if size > 3 * piece { places += [size - 3 * piece, size - piece] }
        var right = 0
        for at in Array(Set(places)).sorted() {
            let length = Int(min(piece, size - at))
            let got = try card.read(handle, offset: at, length: length)
            try file.seek(toOffset: at)
            let want = [UInt8](try file.read(upToCount: length) ?? Data())
            if got == want { right += 1 } else { print("    DIFFERENT at \(at): the camera sent \(got.count) bytes, the copy has \(want.count)") }
            print(String(format: "    %12llu  %@", at, got == want ? "same" : "DIFFERENT"))
        }
        print("  \(right) pieces of 3 MB match the copy at \(local.path)")
    }

    /// `--probe-big NAME`: how the camera reports the size of a file and whether it serves pieces
    /// correctly on both sides of the 4 GB line (offsets that need more than 32 bits).
    private static func probeBig(_ card: PhoneCard, handle: UInt32, name: String, listed: UInt64) throws {
        let sizes = try card.sizesAsReported(handle)
        print(String(format: "  \(name): size in the description 0x%08X (%u), size property %@ (answer 0x%04X), size the app uses %llu",
                     sizes.description, sizes.description, sizes.property.map(String.init) ?? "none", sizes.code, listed))
        let size = sizes.property ?? listed
        func hex(_ bytes: [UInt8]) -> String { bytes.prefix(12).map { String(format: "%02x", $0) }.joined() }
        let k = 32 * 1024
        let head = try card.read(handle, offset: 0, length: k)
        print("    first 32 KB: \(head.count) bytes, starts \(hex(head))")
        let line: UInt64 = 1 << 32
        if size > line + UInt64(k) {
            let before = try card.read(handle, offset: line - UInt64(k), length: k)
            let after = try card.read(handle, offset: line, length: k)
            let across = try card.read(handle, offset: line - UInt64(k), length: 2 * k)
            print("    32 KB before 4 GB: \(before.count) bytes, starts \(hex(before))")
            print("    32 KB after 4 GB:  \(after.count) bytes, starts \(hex(after))")
            print("    one read across the line equals the two halves: \(across == before + after)")
            print("    the piece after 4 GB is not the start of the file again: \(after != head)")
        } else {
            print("    the file does not reach past 4 GB + 32 KB")
        }
        // Does the camera honour the offset everywhere? Two overlapping reads must agree, and a piece
        // far into the file must not be the start of the file again.
        let chunk: UInt64 = 3 * 1024 * 1024
        let half: UInt64 = 1 << 31
        var places: [(String, UInt64)] = [
            ("1 GB", 1 << 30), ("just under 2 GB", half - UInt64(k)), ("2 GB", half),
            ("first 3 MB step past 2 GB", (half / chunk + 1) * chunk), ("3 GB", 3 << 30),
            ("last 3 MB step before 4 GB", (line / chunk) * chunk), ("just under 4 GB", line - UInt64(k)),
            ("4 GB", line), ("first 3 MB step past 4 GB", (line / chunk + 1) * chunk),
        ]
        places = places.filter { $0.1 + UInt64(2 * k) < size }
        for (what, at) in places {
            let one = try card.read(handle, offset: at, length: k)
            let two = try card.read(handle, offset: at + UInt64(k / 2), length: k)
            let agree = one.count == k && two.count == k && Array(one.suffix(k / 2)) == Array(two.prefix(k / 2))
            print("    at \(what) (\(at)): \(one.count) bytes, starts \(hex(one)); overlapping reads agree: \(agree); is the file's start: \(one == head)")
        }
        let tail = try card.read(handle, offset: size - UInt64(k), length: k)
        let past = try card.read(handle, offset: size - 100, length: 4096)
        print("    last 32 KB: \(tail.count) bytes; asking for 4096 bytes from 100 before the end gives \(past.count)")
        print("    and those 100 match the end of the last piece: \(past == Array(tail.suffix(100)))")
    }

    /// The whole hand-over as the app does it: remote control → card (list,
    /// copy the newest clip) → remote control again.
    private static func cardTest(_ service: CameraService) async -> Bool {
        let folder = URL(fileURLWithPath: argument(after: "--card-test") ?? NSTemporaryDirectory() + "zve10-card-test")
        let started = Date()
        var copied = false
        do {
            for try await event in service.card(.catchUp(after: nil, count: 1), root: folder, cancel: CancelFlag()) {
                switch event {
                case .status(let text): print(String(format: "  %5.1f s  \(text)", Date().timeIntervalSince(started)))
                case .listed(let clips): print(String(format: "  %5.1f s  \(clips.count) clips and stills on the card", Date().timeIntervalSince(started)))
                case .started(let clip): print(String(format: "  %5.1f s  copying \(clip.name), \(clip.sizeLabel)", Date().timeIntervalSince(started)))
                case .progress: break
                case .finished(_, let url):
                    copied = true
                    print(String(format: "  %5.1f s  saved to \(url.path)", Date().timeIntervalSince(started)))
                case .failed(let clip, let why): print("  \(clip.name) failed: \(why)")
                }
            }
        } catch {
            print("  card job failed: \(error.localizedDescription)")
        }
        var status = ConnectionStatus()
        for attempt in 0..<6 where status.mode == .disconnected {
            if attempt > 0 { try? await Task.sleep(nanoseconds: 700_000_000) }
            status = await service.detect()
        }
        print(String(format: "  %5.1f s  back: \(status.mode.title)", Date().timeIntervalSince(started)))
        if let frame = try? await service.previewFrame() { print("  live view frame after the hand-over: \(frame.count) bytes") }
        return copied && status.mode == .pcRemote
    }

    /// `TetherStudio --usb-check [--bench]`: what the camera offers on the cable.
    private static func usbCheck() async -> Bool {
        let service = CameraService.shared
        let status = await service.detect()
        print("USB connection: \(status.mode.title), link \(String(describing: status.link))")
        guard status.mode != .disconnected else {
            print("No camera answers on USB (in Mass Storage mode it is a disk, not a camera: \(CardVolume.find()?.path ?? "no card volume mounted")).")
            return false
        }
        do {
            let t = Date()
            let files = try await service.listFiles()
            print(String(format: "  files listed through the camera: %d in %.1f s", files.count, Date().timeIntervalSince(t)))
            for f in files.prefix(3) { print("    \(f.folder)/\(f.name)  \(f.sizeLabel)") }
        } catch {
            print("  file listing: \(error.localizedDescription)")
        }
        if status.mode == .pcRemote, CommandLine.arguments.contains("--bench") { await bench(service) }
        return true
    }

    private static func run(host: String?) async -> Bool {
        let service = CameraService.shared
        let name = await service.wifiClientName()
        print("This Mac appears on the camera as: \(name)")

        var camera: WifiCamera?
        var host = host
        if CommandLine.arguments.contains("--bridge") {
            let up = await Task.detached { startBridge() }.value
            guard up else { return false }
            host = host ?? BridgeController.localHost
        }
        if let host {
            let p = WifiDiscovery.probe(host: host)
            camera = p.camera
            if camera == nil { print("Nothing answers at \(host) (errno \(p.sysErrno): \(String(cString: strerror(p.sysErrno))))") }
        } else {
            print("Searching the local network…")
            let result = WifiDiscovery.search()
            if let e = result.sendErrno {
                print("The search could not be sent (errno \(e): \(String(cString: strerror(e))))")
            }
            for c in result.cameras { print("  found \(c.model.isEmpty ? "?" : c.model) at \(c.host), service \(c.service)") }
            camera = result.cameras.first { $0.service != .smartphone } ?? result.cameras.first
            if result.cameras.isEmpty {
                print("No camera answered the search; trying every address on this network directly…")
                let scanned = WifiDiscovery.scan()
                for c in scanned { print("  found \(c.model.isEmpty ? "?" : c.model) at \(c.host), service \(c.service)") }
                camera = scanned.first { $0.service != .smartphone } ?? scanned.first
                if scanned.isEmpty { print("No camera found.") }
            }
        }
        guard let camera else { return false }
        print("Camera: \(camera.model.isEmpty ? "?" : camera.model) at \(camera.host), service \(camera.service)")
        if camera.service == .smartphone {
            print("It is running phone control (Ctrl w/ Smartphone): remote control and the card over one link.")
        }

        let phone = camera.service == .smartphone
        await service.setWifiTarget(camera.host, phone: phone)
        var status = await service.detect()
        if status.mode == .disconnected, phone {
            // The phone service has no pairing; a handshake would only hold a connection open for a minute.
            print("The camera's phone service did not open a session. If this stays so with the camera on its")
            print("Connection screen, switch the camera off and on.")
            return false
        }
        if status.mode == .disconnected {
            await service.setWifiTarget(nil)
            print("Session did not open directly; running the pairing handshake (waits up to 60 s).")
            print("If the camera is on its Pairing screen, confirm \(name) there now.")
            let result = await service.pairingHandshake(host: camera.host)
            print("Handshake: \(result)")
            guard result == .paired else {
                if result == .refused {
                    print("The camera does not know this Mac. Open MENU → Network → PC Remote Function → Pairing and run this again.")
                }
                return false
            }
            await service.setWifiTarget(camera.host, phone: phone)
            for attempt in 0..<4 where status.mode == .disconnected {
                if attempt > 0 { try? await Task.sleep(nanoseconds: 700_000_000) }
                status = await service.detect()
            }
        }
        print("Connection: \(status.mode.title), link \(String(describing: status.link))")
        guard status.mode == .pcRemote else { return false }

        if let cfg = try? await service.readConfigs(["/main/status/cameramodel", "/main/status/deviceversion",
                                                     "/main/status/batterylevel", "/main/capturesettings/expprogram",
                                                     "/main/imgsettings/iso"]) {
            for key in ["cameramodel", "deviceversion", "batterylevel", "expprogram", "iso"] {
                print("  \(key): \(cfg[key]?.current ?? "—")")
            }
        }
        do {
            let frame = try await service.previewFrame()
            print("  live view frame: \(frame.count) bytes")
        } catch {
            print("  live view frame failed: \(error.localizedDescription)")
        }
        if CommandLine.arguments.contains("--bench") { await bench(service) }
        if CommandLine.arguments.contains("--zoom-test") { await zoomTest(service) }
        if CommandLine.arguments.contains("--touch-test") { await touchTest(service) }
        if CommandLine.arguments.contains("--movie") { await movieSettings(service) }
        if CommandLine.arguments.contains("--controls") { await controls(service) }
        if CommandLine.arguments.contains("--all-controls") { await allControls(service) }
        if let i = CommandLine.arguments.firstIndex(of: "--set-clock") {
            // `--set-clock [SECONDS]`: sets the camera's clock to this Mac's time, plus SECONDS (for proving
            // that the camera takes it: a clip recorded afterwards carries the shifted time).
            let args = CommandLine.arguments
            let shift = args.count > i + 1 ? Double(args[i + 1]) ?? 0 : 0
            let when = Date().addingTimeInterval(shift)
            do {
                try await service.setClock(when)
                print("  camera clock: sent \(CameraClock.text(when))\(shift == 0 ? "" : " (this Mac's time shifted by \(Int(shift)) s)"), accepted")
            } catch {
                print("  camera clock: REFUSED: \(error.localizedDescription)")
            }
        }
        if let i = CommandLine.arguments.firstIndex(of: "--photo") {
            let args = CommandLine.arguments
            let count = args.count > i + 1 ? Int(args[i + 1]) ?? 1 : 1
            await photoTest(service, count: count)
        }
        if CommandLine.arguments.contains("--card-ops") {
            // Read-only: opens the card session, lists the card, prints what the camera offers there.
            do {
                for try await event in service.card(.list(fresh: false), root: URL(fileURLWithPath: NSTemporaryDirectory()), cancel: CancelFlag()) {
                    if case .listed(let clips) = event { print("  \(clips.count) files listed") }
                }
            } catch { print("  card session failed: \(error.localizedDescription)") }
            print("  operations offered in the card session: " + PhoneCard.lastAdvertised.map { String(format: "0x%04X", $0) }.joined(separator: " "))
        }
        if CommandLine.arguments.contains("--card-test") { return await cardTest(service) }
        return true
    }

    /// `--photo [N]`: takes N photos a few seconds apart and prints, before and after each, the
    /// settings that may count photos, to learn which one confirms that a photo was taken.
    private static func photoTest(_ service: CameraService, count: Int) async {
        let watch = ["expprogram", "imagesize", "pcsaveimgsize", "pcsaveimgformat", "shutterspeed", "focusmode", "d249", "d215"]
        let paths = ["/main/capturesettings/expprogram", "/main/imgsettings/imagesize", "/main/capturesettings/pcsaveimgsize",
                     "/main/capturesettings/pcsaveimgformat", "/main/capturesettings/shutterspeed", "/main/capturesettings/focusmode",
                     "/main/other/d249", "/main/other/d215"]
        func show(_ label: String) async {
            let cfg = (try? await service.readConfigs(paths)) ?? [:]
            print("  \(label): " + watch.map { "\($0)=\(cfg[$0]?.current ?? "—")" }.joined(separator: " "))
        }
        await show("before")
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("zve10-photo-test", isDirectory: true)
        for n in 1...max(1, count) {
            let start = Date()
            do {
                let files = try await service.takePhoto(preferredPhotoMode: "P", to: folder)
                print(String(format: "  photo %d: %.2f s", n, Date().timeIntervalSince(start)))
                for url in files {
                    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    let pixels = NSImage(contentsOf: url).flatMap { $0.representations.first }.map { "\($0.pixelsWide)x\($0.pixelsHigh)" } ?? "?"
                    print("    \(url.path)  \(size) bytes  \(pixels)")
                }
            } catch {
                print("  photo \(n): FAILED after \(String(format: "%.1f", Date().timeIntervalSince(start))) s: \(error.localizedDescription)")
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            await show("after \(n)")
        }
    }

    /// `--all-controls`: reads (never writes) every setting libgphoto2 listed for this camera in PC Remote
    /// mode, to see which of them the connection in use offers, with value, choices and whether it can be set.
    private static func allControls(_ service: CameraService) async {
        let paths = ["/main/status/serialnumber", "/main/status/manufacturer", "/main/status/cameramodel", "/main/status/deviceversion", "/main/status/vendorextension", "/main/status/batterylevel", "/main/status/focusindication", "/main/imgsettings/imagesize", "/main/imgsettings/iso", "/main/imgsettings/colortemperature", "/main/imgsettings/whitebalance", "/main/capturesettings/zoom", "/main/capturesettings/exposurecompensation", "/main/capturesettings/flashmode", "/main/capturesettings/f-number", "/main/capturesettings/imagequality", "/main/capturesettings/jpegquality", "/main/capturesettings/pcsaveimgsize", "/main/capturesettings/pcsaveimgformat", "/main/capturesettings/focalposition", "/main/capturesettings/focusmode", "/main/capturesettings/expprogram", "/main/capturesettings/aspectratio", "/main/capturesettings/capturemode", "/main/capturesettings/exposuremetermode", "/main/capturesettings/shutterspeed", "/main/capturesettings/liveviewsettingeffect", "/main/capturesettings/focusarea", "/main/capturesettings/dro", "/main/other/5005", "/main/other/5007", "/main/other/500a", "/main/other/500b", "/main/other/500c", "/main/other/500e", "/main/other/5010", "/main/other/5013", "/main/other/d200", "/main/other/d201", "/main/other/d203", "/main/other/d20d", "/main/other/d20e", "/main/other/d20f", "/main/other/d210", "/main/other/d211", "/main/other/d213", "/main/other/d214", "/main/other/d215", "/main/other/d217", "/main/other/d218", "/main/other/d21b", "/main/other/d21c", "/main/other/d21d", "/main/other/d21e", "/main/other/d21f", "/main/other/d221", "/main/other/d222", "/main/other/d223", "/main/other/d22a", "/main/other/d22c", "/main/other/d231", "/main/other/d235", "/main/other/d236", "/main/other/d23d", "/main/other/d23e", "/main/other/d23f", "/main/other/d240", "/main/other/d241", "/main/other/d242", "/main/other/d243", "/main/other/d244", "/main/other/d245", "/main/other/d246", "/main/other/d247", "/main/other/d248", "/main/other/d249", "/main/other/d24a", "/main/other/d24c", "/main/other/d24e", "/main/other/d24f", "/main/other/d250", "/main/other/d251", "/main/other/d252", "/main/other/d253", "/main/other/d254", "/main/other/d259", "/main/other/d25b", "/main/other/d25c", "/main/other/d25d", "/main/other/d25f", "/main/other/d260", "/main/other/d261", "/main/other/d262", "/main/other/d263", "/main/other/d264", "/main/other/d267", "/main/other/d268", "/main/other/d269", "/main/other/d26a", "/main/other/d26b", "/main/other/d26c", "/main/other/d26d", "/main/other/d26e", "/main/other/d26f", "/main/other/d270", "/main/other/d271", "/main/other/d272", "/main/other/d273", "/main/other/d274", "/main/other/d275", "/main/other/d276", "/main/other/d278", "/main/other/d27c", "/main/other/d27d", "/main/other/d27e", "/main/other/d27f", "/main/other/d280", "/main/other/d283", "/main/other/d284", "/main/other/d285", "/main/other/d295", "/main/other/d296", "/main/other/d2c1", "/main/other/d2c2", "/main/other/d2c3", "/main/other/d2c7", "/main/other/d2c8", "/main/other/d2c9", "/main/other/d2d1", "/main/other/d2d9", "/main/other/d2dc", "/main/other/d2dd"]
        let cfg = (try? await service.readConfigs(paths)) ?? [:]
        for path in paths {
            let leaf = CameraService.leaf(of: path)
            guard let c = cfg[leaf] else { print("  \(leaf): not offered"); continue }
            var line = "  \(leaf) \(c.type) = \(c.current ?? "?")\(c.readOnly ? "  (read-only now)" : "")"
            if c.isRange { line += "  range \(c.bottom ?? 0)…\(c.top ?? 0) step \(c.step ?? 0)" }
            else if !c.options.isEmpty {
                line += "  \(c.options.count) choices: " + c.options.prefix(40).map(\.value).joined(separator: " | ")
            }
            print(line)
        }
    }

    /// `--controls [--set LEAF=VALUE]...`: every control the window offers, as the camera reports it: value,
    /// whether it can be changed right now, and its choices. Each `--set` changes one control (a choice by its
    /// text, a slider by its number) through the same whitelisted call the window uses, then reads it back.
    private static func controls(_ service: CameraService) async {
        func read() async -> [String: CameraConfig] { (try? await service.readConfigs(CameraService.controlPaths)) ?? [:] }
        func show(_ cfg: [String: CameraConfig], only: String? = nil) {
            for path in CameraService.controlPaths {
                let leaf = CameraService.leaf(of: path)
                if let only, only != leaf { continue }
                guard let c = cfg[leaf] else { print("  \(leaf): not offered by the camera"); continue }
                var line = "  \(leaf) [\(c.label)] = \(c.current ?? "?")\(c.readOnly ? "  (read-only now)" : "")"
                if c.isRange { line += "  range \(c.bottom ?? 0)…\(c.top ?? 0) step \(c.step ?? 0)" }
                else if !c.options.isEmpty {
                    let shown = c.options.prefix(14).map(\.value).joined(separator: " | ")
                    line += "  \(c.options.count) choices: \(shown)\(c.options.count > 14 ? " | …" : "")"
                }
                print(line)
            }
        }
        var cfg = await read()
        show(cfg)
        let args = CommandLine.arguments
        for (i, arg) in args.enumerated() where arg == "--set" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2, let path = CameraService.controlPaths.first(where: { CameraService.leaf(of: $0) == parts[0] }),
                  let c = cfg[parts[0]] else { print("  --set \(args[i + 1]): no such control"); continue }
            let started = Date()
            do {
                if c.isRange, let v = Double(parts[1]) {
                    try await service.setConfig(path, rangeValue: Int(v))
                } else if let option = c.options.first(where: { $0.value == parts[1] }) {
                    try await service.setConfig(path, optionIndex: option.index)
                } else { print("  --set \(args[i + 1]): not one of its choices"); continue }
                var after = await read()
                var waited = 0.0
                while after[parts[0]]?.current != parts[1] && waited < 3 {       // the camera reports some changes a moment later
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    waited += 0.3
                    after = await read()
                }
                print(String(format: "  set \(parts[0]) to \(parts[1]): accepted, the camera now reports \(after[parts[0]]?.current ?? "?") (%.1f s)",
                             Date().timeIntervalSince(started)))
                cfg = after
            } catch {
                print("  set \(parts[0]) to \(parts[1]): REFUSED: \(error.localizedDescription)")
                cfg = await read()
            }
        }
        if args.contains("--set") { print("  afterwards:"); show(cfg) }
    }

    /// `--movie [4k|hd] [--quality VALUE]`: shows, and with an argument sets, the movie format and recording setting.
    private static func movieSettings(_ service: CameraService) async {
        func show(_ when: String) async -> [String: CameraConfig] {
            let cfg = (try? await service.readConfigs(["/main/other/d241", "/main/other/d242", "/main/other/d24a"])) ?? [:]
            func line(_ leaf: String, _ label: (String) -> String) -> String {
                guard let c = cfg[leaf] else { return "not offered" }
                return "\(c.current.map(label) ?? "?")\(c.readOnly ? " (read-only)" : "") of ["
                    + c.options.map { "\($0.value)=\(label($0.value))" }.joined(separator: ", ") + "]"
            }
            print("  \(when): format \(line("d241", MovieSettings.format))")
            print("  \(when): quality \(line("d242", MovieSettings.quality)); card time left \(cfg["d24a"]?.current ?? "?") s")
            return cfg
        }
        func set(_ leaf: String, to value: String, in cfg: [String: CameraConfig]) async {
            guard let option = cfg[leaf]?.options.first(where: { $0.value == value }) else {
                print("  \(leaf): the camera does not offer \(value) right now")
                return
            }
            do {
                try await service.setConfig("/main/other/\(leaf)", optionIndex: option.index)
            } catch {
                print("  \(leaf): \(error.localizedDescription)")
            }
            try? await Task.sleep(nanoseconds: 2_500_000_000)      // past the 2 s the camera library caches settings for
        }
        var cfg = await show("now")
        if let want = argument(after: "--movie"), ["4k", "hd"].contains(want.lowercased()) {
            await set("d241", to: want.lowercased() == "4k" ? MovieSettings.format4K : MovieSettings.formatHD, in: cfg)
            cfg = await show("after format")
        }
        if let quality = argument(after: "--quality") {
            await set("d242", to: quality, in: cfg)
            _ = await show("after quality")
        }
    }

    /// Zooms in for a moment and back out, with live view frames in between,
    /// and shows how soon the reported position follows.
    private static func zoomTest(_ service: CameraService) async {
        func position() async -> String {
            let cfg = try? await service.readConfigs(["/main/other/d25d", "/main/other/d25c", "/main/other/d21d"])
            let z = ZoomPosition(bar: cfg?["d25d"]?.current, scale: cfg?["d25c"]?.current)
            return "\(z?.label ?? "?") (bar \(cfg?["d25d"]?.current ?? "?"), rec state \(cfg?["d21d"]?.current ?? "?"))"
        }
        print("  zoom before: \(await position())")
        for (direction, hold) in [(1, 1.5), (-1, 3.0)] {
            do {
                let t = Date()
                try await service.zoom(direction)
                var frames = 0
                while Date().timeIntervalSince(t) < hold {
                    if (try? await service.previewFrame()) != nil { frames += 1 }
                }
                try await service.zoom(0)
                print("  zoom \(direction > 0 ? "in" : "out") held \(hold) s, \(frames) live view frames meanwhile, stop sent")
            } catch {
                print("  zoom failed: \(error.localizedDescription)")
                return
            }
            for wait in [0.2, 1.0, 1.5] {
                try? await Task.sleep(nanoseconds: UInt64(wait * 1e9))
                print("    +\(wait) s: \(await position())")
            }
        }
    }

    /// Touches two points of the picture and cancels, showing what the camera reports.
    private static func touchTest(_ service: CameraService) async {
        func state() async -> String {
            let cfg = try? await service.readConfigs(["/main/other/d283", "/main/other/d284", "/main/other/d285",
                                                      "/main/capturesettings/focusarea", "/main/status/focusindication"])
            return "touch function \(cfg?["d283"]?.current ?? "?"), touch allowed \(cfg?["d284"]?.current ?? "?"), "
                + "cancel allowed \(cfg?["d285"]?.current ?? "?"), focus area \(cfg?["focusarea"]?.current ?? "?"), "
                + "focus \(cfg?["focusindication"]?.current ?? "?")"
        }
        print("  touch before: \(await state())")
        do {
            for (x, y) in [(0.5, 0.5), (0.25, 0.3)] {
                try await service.touch(x: x, y: y)
                _ = try? await service.previewFrame()
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                print("  touched (\(x), \(y)): \(await state())")
            }
            try await service.cancelTouch()
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            print("  cancelled: \(await state())")
        } catch {
            print("  touch failed: \(error.localizedDescription)")
        }
    }

    /// Timings that decide how smooth the live monitor can be.
    private static func bench(_ service: CameraService) async {
        func ms(_ start: Date) -> Int { Int(Date().timeIntervalSince(start) * 1000) }
        for round in 1...3 {
            if round > 1 { try? await Task.sleep(nanoseconds: 3_000_000_000) }      // past libgphoto2's 2 s cache
            let t = Date()
            _ = try? await service.readConfigs(CameraService.controlPaths)
            print("  settings poll \(round) (\(CameraService.controlPaths.count) settings): \(ms(t)) ms")
        }
        for quality in [1, 0] {     // choice index: 1 = high ("2"), 0 = low ("1"); left on low only if asked
            try? await service.setConfig("/main/other/d26a", optionIndex: quality)
            try? await Task.sleep(nanoseconds: 600_000_000)
            var sizes = 0, frames = 0
            var last = Data()
            let t = Date()
            for _ in 0..<40 {
                if let f = try? await service.previewFrame() { sizes += f.count; frames += 1; last = f }
            }
            let total = Date().timeIntervalSince(t)
            print(String(format: "  live view quality %@: %d frames in %.2f s = %.1f frames/s, %.0f ms each, %d KB average",
                         quality == 1 ? "high" : "low", frames, total, Double(frames) / total,
                         total * 1000 / Double(max(frames, 1)), sizes / max(frames, 1) / 1024))
            if let dir = ProcessInfo.processInfo.environment["ZVE10_BENCH_DIR"] {
                try? last.write(to: URL(fileURLWithPath: dir).appendingPathComponent(quality == 1 ? "high.jpg" : "low.jpg"))
            }
        }
        try? await service.setConfig("/main/other/d26a", optionIndex: 1)
    }
}
