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
/// - `startAccessingSecurityScopedResource()` returns **false** for every plain
///   `URL(fileURLWithPath:)` inside a sandboxed process while a raw
///   `bookmarkData(options: .withSecurityScope)` on the *same* URL succeeds
///   (measured on a signed sandboxed probe: false for `/`, `/Applications`,
///   `/Users/…` and `/opt`, with 460–524 byte bookmarks for all of them). The
///   guard that asked the first question before attempting the second therefore
///   refused folders the app could bookmark and reach: that was B2, and it is
///   why `remember(_:)` attempts the bookmark directly.
///
/// The access is process-wide and must be *held* while a scan runs. That is the
/// whole contract of this type: `begin()` before, `end()` after, never leaked.
nonisolated enum ScopedAccess {
    /// The key the bookmark is stored under. One bookmark, because one scanned
    /// root is what the product offers; a second would need a second entry.
    static let bookmarkKey = "bz.scopedBookmark"

    /// The boot volume group's data volume — the path `ScanTargets.macintoshHD`
    /// scans and the subtree the panel's "Macintosh HD" row stands for.
    ///
    /// `ScanTargets` (app/Model.swift) owns the user-visible target and spells
    /// the same path; it is repeated here because this file is compiled on its
    /// own by `tests/swift/scoped-access.swift`, where `ScanTargets` does not
    /// exist. The two drifting apart is survivable rather than fatal: the plain
    /// subtree rule in `covers(_:)` matches the stored root exactly, so a
    /// renamed whole-disk target still covers itself — only the cross-spelling
    /// convenience below would be lost.
    static let bootVolumeDataPath = "/System/Volumes/Data"

    /// The path the stored bookmark resolves to, or nil when there is none.
    ///
    /// Resolved **without** starting access: this only inspects, and
    /// `startAccessingSecurityScopedResource()` outlives nothing here — the
    /// extension is not held by a resolution nobody released. Apple documents an
    /// implicit start on resolution unless `.withoutImplicitStartAccessing` is
    /// passed, so a plain resolve here would quietly take an extension that
    /// `isStale`/`covers` never drop. `Grant.hold()` is the one place that
    /// acquires, explicitly.
    static var grantedPath: String? {
        guard let bookmark = stored() else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark,
                                 options: [.withSecurityScope, .withoutImplicitStartAccessing],
                                 relativeTo: nil,
                                 bookmarkDataIsStale: &stale) else { return nil }
        return url.path
    }

    /// Whether a bookmark exists that can actually be used right now.
    ///
    /// "Is any grant stored", which is **not** the question the scan gate asks:
    /// a grant of `/Applications` used to satisfy this and let a Home or
    /// whole-disk scan start with no access to it, producing an empty tree
    /// instead of a request for the folder (B3). The gate uses `covers(_:)`;
    /// this stays for callers that genuinely want the weaker question, and for
    /// tests that assert the storage contract.
    static var hasUsableBookmark: Bool {
        guard let path = grantedPath, !path.isEmpty else { return false }
        return !isStale && FileManager.default.fileExists(atPath: path)
    }

    /// Whether the stored bookmark is still valid. A stale one must be re-picked
    /// by the user: only the panel can re-authorize a moved or replaced folder.
    ///
    /// Resolution is inspection only, so it passes
    /// `.withoutImplicitStartAccessing` for the same reason `grantedPath` does.
    static var isStale: Bool {
        guard let bookmark = stored() else { return false }
        var stale = false
        _ = try? URL(resolvingBookmarkData: bookmark,
                     options: [.withSecurityScope, .withoutImplicitStartAccessing],
                     relativeTo: nil, bookmarkDataIsStale: &stale)
        return stale
    }

    /// Stores a bookmark for a folder the user chose in the panel.
    ///
    /// The panel already extends this process's sandbox for the session, so the
    /// URL it returns can be bookmarked immediately. **No `startAccessing`
    /// guard**: measured inside a sandboxed process, that call returns false for
    /// every plain path while `bookmarkData` on the same URL succeeds, so asking
    /// it first refuses exactly the folders the user handed over (B2). The call
    /// below is attempted directly and only a real failure — missing
    /// entitlement, or a volume that went away mid-selection — reports false,
    /// after which the caller must not pretend the folder is remembered.
    @discardableResult
    static func remember(_ url: URL) -> Bool {
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

    /// Removes the stored bookmark. No UI caller yet: the picker overwrites the
    /// single stored bookmark rather than clearing it first, so forgetting is
    /// the tests' and a future "stop scanning my disk" control's operation.
    static func forget() {
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
    }

    // MARK: - Coverage

    /// The ways one subtree can be spelled, given the Data volume is a firmlink
    /// into `/`.
    ///
    /// Measured: `URL(fileURLWithPath: "/System/Volumes/Data/Users")
    /// .resolvingSymlinksInPath()` is `/Users`, so `/Users/me` and
    /// `/System/Volumes/Data/Users/me` are the same place. A grant of either
    /// spelling therefore authorizes the other, and a target reached by either
    /// path can be checked against a grant of either path.
    ///
    /// A mount under `/Volumes` is deliberately left alone: it *looks* like it
    /// lives in the Data volume's directory tree — `/Volumes` itself is a
    /// firmlink to `/System/Volumes/Data/Volumes` — but its bytes are on another
    /// device, so giving it the Data spelling would let a boot-volume grant
    /// match it through rule 1 and make the mounted-drive gate unreachable (B4).
    static func spellings(of path: String) -> [String] {
        if path == "/" || path == bootVolumeDataPath { return ["/", bootVolumeDataPath] }
        if isUnderVolumes(path) { return [path] }
        if path.hasPrefix(bootVolumeDataPath + "/") {
            return [path, String(path.dropFirst(bootVolumeDataPath.count))]
        }
        return [path, bootVolumeDataPath + path]
    }

    /// Every spelling of `path` that must count as the same place: the firmlink
    /// pair above, plus the symlink-resolved form.
    ///
    /// The second pass exists because macOS also spells directories by two
    /// names that are not firmlinks. Measured: an app-scoped bookmark for a
    /// temp directory resolves to `/private/var/folders/…`, while
    /// `NSTemporaryDirectory()` — and therefore the URL the panel would have
    /// handed over — is `/var/folders/…`. Comparing raw strings called the same
    /// directory two different places, so the grant covered nothing.
    /// `resolvingSymlinksInPath()` maps `/private/var/…` to `/var/…`, i.e. the
    /// opposite direction, which is why both sides are run through it rather
    /// than one.
    private static func equivalents(of path: String) -> Set<String> {
        var out = Set(spellings(of: path))
        out.formUnion(spellings(of: URL(fileURLWithPath: path).resolvingSymlinksInPath().path))
        return out
    }

    /// Whether the stored grant authorizes `target`.
    ///
    /// This — not "is any bookmark stored" — is the question the sandboxed scan
    /// gate asks. Two rules, in order:
    ///
    /// 1. The grant's own subtree, in any spelling `equivalents` recognizes:
    ///    `target` is the granted path or lies under it. Path-boundary exact
    ///    (`granted + "/"`), so `/ApplicationsOld` is not covered by a grant of
    ///    `/Applications`.
    /// 2. A grant of the boot volume group — `/` (which is what the panel's
    ///    "Macintosh HD" row yields) or the Data volume it stands for — covers
    ///    everything the app scans on that volume: the disk root, Home, and
    ///    `/Applications` (which is readable on the entitlements alone and is
    ///    never gated anyway).
    ///
    /// Rule 2 deliberately **stops at another device's mount**. `/Volumes/Foo`
    /// sits in the Data volume's directory tree, yet its bytes are not on the
    /// volume the user handed over: letting a boot-volume grant unlock every
    /// plugged-in disk would make the mounted-drive gate unreachable (B4), and
    /// the scan would then read an external volume the sandbox denies and come
    /// back empty. Only a grant of that drive, or of a folder containing it,
    /// covers it.
    static func covers(_ target: String) -> Bool {
        guard let granted = grantedPath, !granted.isEmpty else { return false }
        let targetEquivalents = equivalents(of: target)
        let grantedEquivalents = equivalents(of: granted)
        // Rule 2 first, and exclusively, for a boot-volume grant: its Data
        // spelling would otherwise satisfy rule 1 for a mount's Data-spelled
        // path (`/System/Volumes/Data/Volumes/External` does have the prefix
        // `/System/Volumes/Data/`), which is exactly the leak rule 2 exists to
        // close. For a whole-volume grant the two rules agree everywhere except
        // at a mount, and at a mount rule 2 wins.
        if grantedEquivalents.contains("/") || grantedEquivalents.contains(bootVolumeDataPath) {
            return !targetEquivalents.contains(where: isUnderVolumes)
        }
        for g in grantedEquivalents {
            for t in targetEquivalents where t == g || t.hasPrefix(g + "/") { return true }
        }
        return false
    }

    /// Whether a path names a mount under `/Volumes`, in either spelling.
    private static func isUnderVolumes(_ path: String) -> Bool {
        for prefix in ["/Volumes", bootVolumeDataPath + "/Volumes"] {
            if path == prefix || path.hasPrefix(prefix + "/") { return true }
        }
        return false
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
        /// The bookmark the held extension came from. Comparing it is how a
        /// re-pick is noticed: the extension must follow the new folder.
        private var heldBookmark: Data?

        /// Keeps access to the stored folder for the rest of the session.
        ///
        /// Idempotent for an unchanged bookmark: calling it again does not drop
        /// and re-acquire the extension, which would briefly close the window
        /// cleanup depends on.
        ///
        /// **A changed bookmark does re-acquire.** Re-picking another folder
        /// mid-session overwrites the stored bookmark; the old short-circuit
        /// (`if let url { return url.path }`) then kept returning the *old* root
        /// while the new extension was never started, so the folder the user
        /// just chose was not actually reachable (B8). The stored bookmark is
        /// compared, and a different one releases the old extension before
        /// acquiring the new.
        ///
        /// Returns the folder's path, or nil when there is nothing usable stored
        /// (never chosen, stale, or forgotten) — the caller then asks the user
        /// to pick.
        @discardableResult
        func hold() -> String? {
            guard let bookmark = ScopedAccess.stored() else {
                // Nothing stored: an extension held for a bookmark that has
                // since been forgotten must go, not linger as access the app
                // can no longer justify.
                release()
                return nil
            }
            if let url, heldBookmark == bookmark { return url.path }
            var stale = false
            // Resolve **without** implicit access and then start exactly one
            // extension explicitly. Apple documents an implicit
            // `startAccessingSecurityScopedResource()` on every plain resolve
            // unless `.withoutImplicitStartAccessing` is passed, and the two
            // modes are not equivalent in the other direction: an explicit start
            // after an implicit one returns *false*, but only one `stop` in
            // `release()` still ends the extension. So the plain form would leak
            // its implicit start the moment this code re-acquired. Only the
            // `.withSecurityScope` grant in the bookmark matters for reaching
            // the folder; the access itself is taken by the explicit call below.
            guard let fresh = try? URL(resolvingBookmarkData: bookmark,
                                       options: [.withSecurityScope, .withoutImplicitStartAccessing],
                                       relativeTo: nil,
                                       bookmarkDataIsStale: &stale), !stale else {
                release()
                return nil
            }
            // A re-pick (or a stale hold) drops the old extension first, so the
            // process never holds two roots it did not ask to keep.
            release()
            guard fresh.startAccessingSecurityScopedResource() else { return nil }
            url = fresh
            heldBookmark = bookmark
            return fresh.path
        }

        /// Releases the extension. Only for shutdown, and for tests: the access
        /// is what the whole session's cleanup depends on.
        func release() {
            url?.stopAccessingSecurityScopedResource()
            url = nil
            heldBookmark = nil
        }

        /// Whether access is currently held.
        var isHeld: Bool { url != nil }

        deinit { release() }
    }
}
