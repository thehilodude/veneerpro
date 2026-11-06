import Foundation

/// Which edition this is. The Mac App Store edition (built with `-DAPPSTORE`, see build-app.sh) runs in
/// the App Sandbox and leaves out what the store doesn't allow or what needs a commercial license:
/// FBX import through Reality Converter's plugin, Substance rendering through `sbsrender`, the Poly
/// Haven browser, KeyShot folders, and the built-in RAL tables.
enum Distribution {
    #if APPSTORE
    static let isAppStore = true
    #else
    static let isAppStore = false
    #endif
}

/// Keeps access to files and folders the user picked across launches. In the App Sandbox, access to
/// anything outside the app's container lasts only until quit unless it's saved as a security-scoped
/// bookmark; outside the sandbox these calls do nothing.
enum FileAccess {
    private static let key = "SecurityScopedBookmarks"

    /// Saves access to `url` (a picked or dropped file or folder).
    static func remember(_ url: URL) {
        guard Distribution.isAppStore else { return }
        guard let data = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) else { return }
        var all = UserDefaults.standard.dictionary(forKey: key) as? [String: Data] ?? [:]
        all[url.standardizedFileURL.path] = data
        UserDefaults.standard.set(all, forKey: key)
    }

    /// Regains access to everything saved, at launch. Access is kept for the app's lifetime.
    static func restoreAll() {
        guard Distribution.isAppStore else { return }
        var all = UserDefaults.standard.dictionary(forKey: key) as? [String: Data] ?? [:]
        for (path, data) in all {
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale) else {
                all[path] = nil
                continue
            }
            _ = url.startAccessingSecurityScopedResource()
            if stale, let fresh = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
                all[path] = fresh
            }
        }
        UserDefaults.standard.set(all, forKey: key)
    }
}
