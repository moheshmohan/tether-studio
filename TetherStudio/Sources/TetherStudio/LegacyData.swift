import Foundation

/// The app was first called "ZVE10 Studio" (bundle `local.zve10.studio`). Its settings, presets,
/// board settings and MCP token are copied once into the new places, so nothing has to be set up
/// again. The old copies are left where they are.
enum LegacyData {
    static let oldDomain = "local.zve10.studio"
    static let oldFolderName = "ZVE10 Studio"
    private static let doneKey = "legacyDataCopied"

    static func migrate() {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let old = support.appendingPathComponent(oldFolderName, isDirectory: true)
        let new = BridgeSettings.url.deletingLastPathComponent()
        if old.standardizedFileURL != new.standardizedFileURL,
           fm.fileExists(atPath: old.path), !fm.fileExists(atPath: new.path) {
            try? fm.copyItem(at: old, to: new)
        }
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: doneKey) else { return }
        if Bundle.main.bundleIdentifier != oldDomain, let values = defaults.persistentDomain(forName: oldDomain) {
            for (key, value) in values where defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
            }
        }
        defaults.set(true, forKey: doneKey)
    }
}
