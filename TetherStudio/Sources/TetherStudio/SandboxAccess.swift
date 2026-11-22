import AppKit
import Foundation

/// The App Store build runs in the App Sandbox (see `Resources/appstore/TetherStudio.entitlements`).
/// There, the app may use `~/Movies` and its own container freely, but two things only after the
/// user has picked them in an Open panel: a download folder elsewhere, and the camera's card mounted
/// as a disk (the sandbox lets the app see that the card is there, not what is on it). The choice is
/// kept as a security-scoped bookmark, per card, so it is asked once. Outside the sandbox (the DMG
/// build) everything here passes straight through.
enum SandboxAccess {
    static var isSandboxed: Bool { ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil }

    private static let cardKey = "cardBookmarks"            // volume id → bookmark
    private static let folderKey = "downloadRootBookmark"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var accessing: Set<String> = []

    static func canRead(_ dir: URL) -> Bool {
        (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) != nil
    }

    // MARK: - the card

    /// True when the card can be read: always outside the sandbox, or with a permission given before.
    static func openCard(_ root: URL) -> Bool {
        if canRead(root) { return true }
        guard let id = volumeID(root),
              let data = (UserDefaults.standard.dictionary(forKey: cardKey) as? [String: Data])?[id],
              let url = resolve(data), samePath(url, root) else { return false }
        start(url)
        return canRead(root)
    }

    /// Asks for the card in an Open panel and remembers the answer for this card.
    @MainActor
    static func askForCard(_ root: URL) -> Bool {
        let panel = NSOpenPanel()
        panel.directoryURL = root
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "Allow"
        panel.message = "Tether Studio needs your permission to list, copy or erase the files on “\(root.lastPathComponent)”. "
            + "Click Allow (with the card itself open, nothing selected)."
        guard panel.runModal() == .OK, let url = panel.url, samePath(url, root) else { return false }
        if let id = volumeID(root), let data = try? url.bookmarkData(options: .withSecurityScope,
                                                                      includingResourceValuesForKeys: nil, relativeTo: nil) {
            var all = UserDefaults.standard.dictionary(forKey: cardKey) as? [String: Data] ?? [:]
            all[id] = data
            UserDefaults.standard.set(all, forKey: cardKey)
        }
        start(url)
        return canRead(root)
    }

    // MARK: - the download folder

    /// Remembers a folder the user chose, so it can be written to after the next launch too.
    static func rememberFolder(_ url: URL) {
        if let data = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(data, forKey: folderKey)
        }
        start(url)
    }

    /// Opens the remembered folder again at launch, when it is the one in use.
    static func openFolder(_ folder: URL) {
        guard isSandboxed, let data = UserDefaults.standard.data(forKey: folderKey),
              let url = resolve(data), samePath(url, folder) else { return }
        start(url)
    }

    // MARK: -

    private static func volumeID(_ root: URL) -> String? {
        let v = try? root.resourceValues(forKeys: [.volumeUUIDStringKey, .volumeNameKey])
        return v?.volumeUUIDString ?? v?.volumeName ?? root.lastPathComponent
    }

    private static func resolve(_ data: Data) -> URL? {
        var stale = false
        return try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
    }

    private static func samePath(_ a: URL, _ b: URL) -> Bool {
        a.standardizedFileURL.resolvingSymlinksInPath().path == b.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private static func start(_ url: URL) {
        lock.lock(); defer { lock.unlock() }
        if accessing.insert(url.path).inserted { _ = url.startAccessingSecurityScopedResource() }
    }
}
