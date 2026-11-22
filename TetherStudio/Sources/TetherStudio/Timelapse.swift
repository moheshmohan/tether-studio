import AVFoundation
import AppKit

/// What a timelapse is to be: a photo every `interval` seconds, `frames` of them, played back at `fps`.
struct TimelapsePlan: Codable, Equatable {
    var interval: Double = 5
    var frames: Int = 250
    var fps: Int = 25
    /// Focus once on the first frame, then hold it (the camera is put on manual focus for the run and
    /// set back afterwards): focus that hunts between frames makes the movie pulse.
    var lockFocus = true

    /// A photo takes about 3 s from press to file on the Mac (measured over phone control, 21 Nov 2026).
    static let minInterval: Double = 4
    static let intervals: [Double] = [4, 5, 8, 10, 15, 20, 30, 60, 120, 300]
    static let frameChoices = [50, 100, 150, 250, 500, 750, 1000, 1500]
    static let fpsChoices = [24, 25, 30]

    var usable: TimelapsePlan {
        var p = self
        p.interval = max(Self.minInterval, interval)
        p.frames = max(2, frames)
        p.fps = max(1, fps)
        return p
    }

    /// Length of the finished movie.
    var movieSeconds: Double { Double(usable.frames) / Double(usable.fps) }
    /// Time the camera spends taking it.
    var shootingSeconds: Double { Double(usable.frames - 1) * usable.interval }
    /// How many times faster than real time the movie plays.
    var speedUp: Double { usable.interval * Double(usable.fps) }

    /// When frame `n` (from 0) is due.
    func due(_ n: Int, from start: Date) -> Date { start.addingTimeInterval(Double(n) * usable.interval) }

    var summary: String {
        "\(usable.frames) photos every \(Self.seconds(usable.interval)) = \(Self.clock(shootingSeconds)) of shooting, "
            + "\(Self.clock(movieSeconds)) of movie at \(usable.fps) fps (\(Int(speedUp.rounded()))× faster)"
    }

    static func seconds(_ s: Double) -> String {
        s >= 60 && s.truncatingRemainder(dividingBy: 60) == 0 ? "\(Int(s) / 60) min" : "\(Int(s)) s"
    }

    /// "1 h 02 min", "4 min 10 s", "10 s"
    static func clock(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s >= 3600 { return String(format: "%d h %02d min", s / 3600, (s % 3600) / 60) }
        if s >= 60 { return s % 60 == 0 ? "\(s / 60) min" : String(format: "%d min %02d s", s / 60, s % 60) }
        return "\(s) s"
    }

    static func load() -> TimelapsePlan {
        guard let data = UserDefaults.standard.data(forKey: "timelapsePlan"),
              let plan = try? JSONDecoder().decode(TimelapsePlan.self, from: data) else { return TimelapsePlan() }
        return plan
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: "timelapsePlan") }
    }
}

/// Where photos and timelapses go, inside the download folder, next to the day's clips.
enum PhotoFolders {
    private static func day(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    static func photos(root: URL, date: Date = Date()) -> URL {
        root.appendingPathComponent(day(date), isDirectory: true).appendingPathComponent("Photos", isDirectory: true)
    }

    /// A new folder for one timelapse's frames, "Timelapse 18-30-05"; never one that exists.
    static func timelapse(root: URL, date: Date = Date()) -> URL {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH-mm-ss"
        let base = root.appendingPathComponent(day(date), isDirectory: true)
        return unique(base.appendingPathComponent("Timelapse \(f.string(from: date))", isDirectory: true))
    }

    /// The URL itself if nothing is there, otherwise "name 2", "name 3"...: nothing is ever replaced.
    static func unique(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let ext = url.hasDirectoryPath ? "" : url.pathExtension
        let stem = ext.isEmpty ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
        let dir = url.deletingLastPathComponent()
        for n in 2... {
            let name = ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)"
            let candidate = dir.appendingPathComponent(name, isDirectory: url.hasDirectoryPath)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
        }
        return url
    }
}

/// Puts a timelapse's photos together into an H.264 movie.
enum TimelapseMovie {
    enum Failure: LocalizedError {
        case noFrames, unreadable(String), writer(String)
        var errorDescription: String? {
            switch self {
            case .noFrames: return "There are no photos to make a movie from"
            case .unreadable(let name): return "The photo \(name) could not be read"
            case .writer(let why): return "The movie could not be written: \(why)"
            }
        }
    }

    /// Movie size for frames of this size: the frame's own, at most 3840 wide, in even numbers (H.264 wants them).
    static func size(for frame: CGSize) -> CGSize {
        let scale = min(1, 3840 / max(frame.width, 1))
        func even(_ v: CGFloat) -> CGFloat { max(2, (v * scale / 2).rounded(.down) * 2) }
        return CGSize(width: even(frame.width), height: even(frame.height))
    }

    private static func image(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    /// Writes `frames` in the order given to `output` (which must not exist), `fps` frames a second.
    /// A photo that cannot be read is replaced by the one before it, so the timing stays right.
    static func make(frames: [URL], fps: Int, to output: URL, progress: @escaping (Double) -> Void) throws {
        guard let first = frames.first.flatMap(image) else { throw frames.isEmpty ? Failure.noFrames : Failure.unreadable(frames[0].lastPathComponent) }
        let size = size(for: CGSize(width: first.width, height: first.height))
        let writer: AVAssetWriter
        do { writer = try AVAssetWriter(outputURL: output, fileType: output.pathExtension.lowercased() == "mov" ? .mov : .mp4) }
        catch { throw Failure.writer(error.localizedDescription) }
        let bitsPerPixel = 0.25      // generous: a timelapse has a lot of detail that changes every frame
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: Int(size.width * size.height * Double(fps) * bitsPerPixel),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
        ])
        guard writer.canAdd(input) else { throw Failure.writer("the movie format was refused") }
        writer.add(input)
        guard writer.startWriting() else { throw Failure.writer(writer.error?.localizedDescription ?? "could not start") }
        writer.startSession(atSourceTime: .zero)

        var last = first
        for (n, url) in frames.enumerated() {
            let picture = n == 0 ? first : (image(url) ?? last)
            last = picture
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.005) }
            guard let pool = adaptor.pixelBufferPool else { throw Failure.writer("no picture buffer") }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { throw Failure.writer("no picture buffer") }
            CVPixelBufferLockBaseAddress(buffer, [])
            let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: Int(size.width), height: Int(size.height),
                                bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            ctx?.interpolationQuality = .high
            ctx?.draw(picture, in: aspectFill(CGSize(width: picture.width, height: picture.height), into: size))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(n), timescale: CMTimeScale(fps))) else {
                throw Failure.writer(writer.error?.localizedDescription ?? "a frame was refused")
            }
            progress(Double(n + 1) / Double(frames.count))
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        if writer.status != .completed { throw Failure.writer(writer.error?.localizedDescription ?? "not finished") }
    }

    /// Where a picture of `source` size is drawn to fill `target`, centred, cropping what sticks out.
    static func aspectFill(_ source: CGSize, into target: CGSize) -> CGRect {
        let scale = max(target.width / max(source.width, 1), target.height / max(source.height, 1))
        let w = source.width * scale, h = source.height * scale
        return CGRect(x: (target.width - w) / 2, y: (target.height - h) / 2, width: w, height: h)
    }
}

/// A timelapse as the window shows it.
struct TimelapseStatus: Equatable {
    enum Phase: Equatable {
        case shooting
        case stopping
        case making(Double)
        case finished(URL)
        case failed(String)
    }

    var phase: Phase
    var plan: TimelapsePlan
    var folder: URL
    var taken = 0
    var missed = 0
    var nextAt: Date?
    var lastFrame: URL?

    var running: Bool {
        switch phase {
        case .shooting, .stopping, .making: return true
        case .finished, .failed: return false
        }
    }
}
