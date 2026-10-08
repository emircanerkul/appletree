import Foundation

// MARK: - Reaching folders the sandbox would otherwise deny

/// One selected folder, remembered across launches, and the sandbox extension
/// that comes with it.
///
/// Why this exists. A sandboxed app cannot reach anything the user did not hand
/// it. The entitlements cover this app's own caches (`AppleTree.entitlements`),
/// but a *whole-disk* scan needs `/Users`, `/private/var` and `/opt`, and no
/// entitlement can grant those: measured, Full Disk Access does **not** lift App
/// Sandbox, so a sandboxed build that asks for it is asking for something it can
/// never receive. The sanctioned route — Apple documents it as
/// "Persist file access with security-scoped URL bookmarks" — is for the user to
/// choose the folder once and for the app to store a bookmark.
///
/// Measured on this machine, and the reason each part of this type exists:
///
/// - Creating such a bookmark **fails without**
///   `com.apple.security.files.bookmarks.app-scope` (error 256), so that key is
///   in the entitlement set.
/// - An app-scoped bookmark is bound to the **creating bundle identifier**: one
///   created by `dev.bm2.mk` and resolved by `dev.bm2.use` failed with error 259,
///   and resolved cleanly once both shared an identifier.
/// - Resolving one genuinely extends the sandbox. With no grant at all, `~/`,
///   `~/Documents`, `~/Downloads` and `~/Projects` were all DENIED; after
///   `startAccessingSecurityScopedResource()` all four were readable, and after
///   `stopAccessingSecurityScopedResource()` they were denied again — so the
///   access is the bookmark's, not ambient. It **recurses into subfolders**,
///   which is what lets one chosen root cover a whole scan.
///
/// The access is process-wide and must be *held* while a scan runs. That is the
/// whole contract of this type: `begin()` before, `end()` after, never leaked.
nonisolated enum ScopedAccess {
    /// The key the bookmark is stored under. One bookmark, because one scanned
    /// root is what the product offers; a second would need a second entry.
    static let bookmarkKey = "bz.scopedBookmark"

    /// The path the stored bookmark resolves to, or nil when there is none.
    ///
    /// Read without starting access, so a caller can decide whether the stored
    /// root is still usable before paying for the extension.
    static var grantedPath: String? {
        guard let bookmark = stored() else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark,
                                 options: [.withSecurityScope],
                                 relativeTo: nil,
                                 bookmarkDataIsStale: &stale) else { return nil }
        return url.path
    }

    /// Whether a bookmark exists that can actually be used right now.
    ///
    /// Distinct from `grantedPath != nil && !isStale` at the call sites: this is
    /// the one question the scan path asks ("may I scan a place the entitlements
    /// do not cover?"), so it lives here rather than being reassembled from two
    /// properties at each caller — where one of them would eventually be
    /// forgotten and the card would reappear for a user who already chose.
    static var hasUsableBookmark: Bool {
        guard let path = grantedPath, !path.isEmpty else { return false }
        return !isStale && FileManager.default.fileExists(atPath: path)
    }

    /// Whether the stored bookmark is still valid. A stale one must be re-picked
    /// by the user: only the panel can re-authorize a moved or replaced folder.
    static var isStale: Bool {
        guard let bookmark = stored() else { return false }
        var stale = false
        _ = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope],
                     relativeTo: nil, bookmarkDataIsStale: &stale)
        return stale
    }

    /// Stores a bookmark for a folder the user chose in the panel.
    ///
    /// The panel already extends this process's sandbox for the session, so the
    /// URL it returns can be bookmarked immediately. Returns false when the
    /// bookmark could not be created — the entitlement is missing, or the volume
    /// went away mid-selection — and the caller must then not pretend the folder
    /// is remembered.
    @discardableResult
    static func remember(_ url: URL) -> Bool {
        guard url.startAccessingSecurityScopedResource() else { return false }
        defer { url.stopAccessingSecurityScopedResource() }
        do {
            let data = try url.bookmarkData(options: [.withSecurityScope],
                                            includingResourceValuesForKeys: nil,
                                            relativeTo: nil)
            UserDefaults.standard.set(data, forKey: bookmarkKey)
            return true
        } catch {
            NSLog("[bz] could not bookmark \(url.path): \(error.localizedDescription)")
            return false
        }
    }

    static func forget() {
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
    }

    private static func stored() -> Data? {
        UserDefaults.standard.data(forKey: bookmarkKey)
    }

    /// Holds the sandbox extension for the stored folder.
    ///
    /// This is now the app's **only** route to the user's files. The
    /// home-relative temporary exception was retired (see
    /// `AppleTree.entitlements`), so without a held extension a sandboxed build
    /// cannot read the home at all — measured: `~/` is DENIED on a build with
    /// only the sandbox, picker and bookmark entitlements.
    ///
    /// **Held for the session, not for one scan.** Cleanup happens after a scan:
    /// the plan is built from the tree, and `Move to Trash` then reaches the
    /// very paths the scan just read. Releasing at the end of the walk would
    /// leave cleanup with no access, so every cleanup on a chosen folder would
    /// fail. `hold()` is therefore idempotent and lives until the app exits —
    /// the standard lifetime for a security-scoped resource the user has
    /// deliberately handed over.
    final class Grant {
        private var url: URL?

        /// Keeps access to the stored folder for the rest of the session.
        ///
        /// Idempotent: calling it again does not drop and re-acquire the
        /// extension, which would briefly close the window cleanup depends on.
        /// Returns the folder's path, or nil when there is nothing usable stored
        /// (never chosen, or stale) — the caller then asks the user to pick.
        @discardableResult
        func hold() -> String? {
            if let url { return url.path }
            guard let bookmark = ScopedAccess.stored() else { return nil }
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: bookmark,
                                     options: [.withSecurityScope],
                                     relativeTo: nil,
                                     bookmarkDataIsStale: &stale), !stale else { return nil }
            guard url.startAccessingSecurityScopedResource() else { return nil }
            self.url = url
            return url.path
        }

        /// Releases the extension. Only for shutdown, and for tests: the access
        /// is what the whole session's cleanup depends on.
        func release() {
            url?.stopAccessingSecurityScopedResource()
            url = nil
        }

        /// Whether access is currently held.
        var isHeld: Bool { url != nil }

        deinit { release() }
    }
}
