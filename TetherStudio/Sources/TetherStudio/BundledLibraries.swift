import Foundation

/// In the downloadable app, libgphoto2 and its plug-ins (the camera driver `ptp2.so` and the
/// connection drivers `ptpip.so`, `usb1.so`, …) travel inside the bundle, in
/// `Contents/Frameworks/libgphoto2/camlibs` and `…/iolibs` (see `scripts/make_dmg.sh`).
/// libgphoto2 finds its plug-ins through the CAMLIBS and IOLIBS environment variables, which must be
/// set before it first loads them. A build run from the source tree has no such folders and uses
/// the library as installed by Homebrew.
enum BundledLibraries {
    static func configure() {
        guard let frameworks = Bundle.main.privateFrameworksURL else { return }
        let base = frameworks.appendingPathComponent("libgphoto2", isDirectory: true)
        let camlibs = base.appendingPathComponent("camlibs").path
        let iolibs = base.appendingPathComponent("iolibs").path
        let fm = FileManager.default
        guard fm.fileExists(atPath: camlibs), fm.fileExists(atPath: iolibs) else { return }
        setenv("CAMLIBS", camlibs, 1)
        setenv("IOLIBS", iolibs, 1)
    }
}
