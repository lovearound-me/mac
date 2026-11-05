import Foundation

/// The app was "app.needed.mac" up to 0.1.48. On the first launch under the
/// new bundle id the old settings are copied over and the session moves to the
/// new folder, so an update keeps everything without signing in again.
enum Migration {
    static let oldBundleID = "app.needed.mac"
    static let supportFolder = "Love Around"
    private static let oldSupportFolder = "Needed"
    private static let doneKey = "migratedFromNeeded"

    static func run() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: doneKey) else { return }
        defaults.set(true, forKey: doneKey)

        if let old = UserDefaults.standard.persistentDomain(forName: oldBundleID) {
            // Not "loginItemSetUp": the login item belongs to the old bundle,
            // so the new one registers itself as on a first install.
            for (key, value) in old where key != "loginItemSetUp" && defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
            }
        }

        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let from = support.appendingPathComponent(oldSupportFolder, isDirectory: true)
        let to = support.appendingPathComponent(supportFolder, isDirectory: true)
        if fm.fileExists(atPath: from.path), !fm.fileExists(atPath: to.path) {
            try? fm.moveItem(at: from, to: to)
        }
    }
}
