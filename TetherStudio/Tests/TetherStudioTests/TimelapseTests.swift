import XCTest
import AppKit
import AVFoundation
@testable import TetherStudio

final class TimelapseTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("tl-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)      // only this test's own temporary folder
    }

    func testThePlanSaysHowLongTheShootingAndTheMovieTake() {
        let plan = TimelapsePlan(interval: 5, frames: 250, fps: 25, lockFocus: true)
        XCTAssertEqual(plan.movieSeconds, 10)
        XCTAssertEqual(plan.shootingSeconds, 1245)
        XCTAssertEqual(plan.speedUp, 125)
        XCTAssertEqual(plan.summary, "250 photos every 5 s = 20 min 45 s of shooting, 10 s of movie at 25 fps (125× faster)")
        let start = Date(timeIntervalSince1970: 1000)
        XCTAssertEqual(plan.due(0, from: start), start)
        XCTAssertEqual(plan.due(3, from: start), start.addingTimeInterval(15))
    }

    func testAPlanTooFastForTheCameraIsSlowedToWhatItCanDo() {
        let plan = TimelapsePlan(interval: 1, frames: 1, fps: 0, lockFocus: false)
        XCTAssertEqual(plan.usable.interval, TimelapsePlan.minInterval)
        XCTAssertEqual(plan.usable.frames, 2)
        XCTAssertEqual(plan.usable.fps, 1)
        XCTAssertTrue(TimelapsePlan.intervals.allSatisfy { $0 >= TimelapsePlan.minInterval })
    }

    func testDurationsAreWrittenOut() {
        XCTAssertEqual(TimelapsePlan.clock(10), "10 s")
        XCTAssertEqual(TimelapsePlan.clock(120), "2 min")
        XCTAssertEqual(TimelapsePlan.clock(250), "4 min 10 s")
        XCTAssertEqual(TimelapsePlan.clock(3720), "1 h 02 min")
        XCTAssertEqual(TimelapsePlan.seconds(300), "5 min")
        XCTAssertEqual(TimelapsePlan.seconds(8), "8 s")
    }

    func testANameInUseIsNeverReplaced() throws {
        let movie = dir.appendingPathComponent("Timelapse 18-30-05.mp4")
        XCTAssertEqual(PhotoFolders.unique(movie), movie)
        try Data([1]).write(to: movie)
        XCTAssertEqual(PhotoFolders.unique(movie).lastPathComponent, "Timelapse 18-30-05 2.mp4")
        let folder = dir.appendingPathComponent("Timelapse 18-30-05", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        XCTAssertEqual(PhotoFolders.unique(folder).lastPathComponent, "Timelapse 18-30-05 2", "a folder name keeps its digits")
    }

    func testFramesGoUnderTheDayInTheDownloadFolder() {
        let root = URL(fileURLWithPath: "/tmp/ZV-E10", isDirectory: true)
        var parts = DateComponents()
        parts.year = 2026; parts.month = 11; parts.day = 21; parts.hour = 18; parts.minute = 30; parts.second = 5
        let date = Calendar.current.date(from: parts)!
        XCTAssertEqual(PhotoFolders.photos(root: root, date: date).path, "/tmp/ZV-E10/2026-11-21/Photos")
        XCTAssertEqual(PhotoFolders.timelapse(root: root, date: date).path, "/tmp/ZV-E10/2026-11-21/Timelapse 18-30-05")
    }

    func testTheMovieSizeIsEvenAndAtMost4K() {
        XCTAssertEqual(TimelapseMovie.size(for: CGSize(width: 1920, height: 1080)), CGSize(width: 1920, height: 1080))
        XCTAssertEqual(TimelapseMovie.size(for: CGSize(width: 6000, height: 3376)), CGSize(width: 3840, height: 2160))
        XCTAssertEqual(TimelapseMovie.size(for: CGSize(width: 1921, height: 1081)), CGSize(width: 1920, height: 1080))
        let fill = TimelapseMovie.aspectFill(CGSize(width: 400, height: 300), into: CGSize(width: 160, height: 90))
        XCTAssertEqual(fill.width, 160, accuracy: 0.01)
        XCTAssertEqual(fill.height, 120, accuracy: 0.01)
        XCTAssertEqual(fill.minY, -15, accuracy: 0.01)
    }

    private func jpeg(_ name: String, shade: CGFloat) throws -> URL {
        let w = 64, h = 36
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: shade, green: 0.5, blue: 1 - shade, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
        let url = dir.appendingPathComponent(name)
        try rep.representation(using: .jpeg, properties: [:])!.write(to: url)
        return url
    }

    func testPhotosBecomeAMovieOfTheRightLength() throws {
        var frames: [URL] = []
        for n in 0..<10 { frames.append(try jpeg("DSC\(n).JPG", shade: CGFloat(n) / 10)) }
        frames.insert(dir.appendingPathComponent("missing.JPG"), at: 5)   // unreadable: the one before stands in
        let movie = dir.appendingPathComponent("out.mp4")
        var last = 0.0
        try TimelapseMovie.make(frames: frames, fps: 25, to: movie) { last = $0 }
        XCTAssertEqual(last, 1, accuracy: 0.0001)
        let asset = AVURLAsset(url: movie)
        let seconds = CMTimeGetSeconds(asset.duration)
        XCTAssertEqual(seconds, 11.0 / 25.0, accuracy: 0.05)
        let track = try XCTUnwrap(asset.tracks(withMediaType: .video).first)
        XCTAssertEqual(track.naturalSize, CGSize(width: 64, height: 36))
    }

    func testNoPhotosNoMovie() {
        XCTAssertThrowsError(try TimelapseMovie.make(frames: [], fps: 25, to: dir.appendingPathComponent("x.mp4")) { _ in })
    }
}
