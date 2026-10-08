import Foundation
import Security

// MARK: - Where the user's things are, and what this process may reach

/// The user's real home directory, and whether this process runs sandboxed.
///
/// Two facts about the process that every other owner used to read for itself
/// through `NSHomeDirectory()` — nine call sites across the app, each one
/// getting a different answer depending on how the app was launched.
///
/// Why this exists as one owner. `NSHomeDirectory()` is a *process* value: the
/// real home in the Developer-ID build, and `~/Library/Containers/<bundle-id>/
/// Data` in the App Store build. Measured on a sandboxed bundle signed with the
/// shipping entitlement set, that difference turns the app against itself:
///
///   - `CleanupGuard.home` became the container, so every real cache path was
///     judged `Outside your home folder` and refused — while the file grant was
///     letting the same process read and Trash those folders.
///   - the "Home" scan target scanned the container's empty `Data` directory,
///     so a Home scan found nothing at all.
///   - the planner was told "their home folder is …/Containers/…/Data".
///
/// So the file grant in `AppleTree.entitlements` and this accessor are one
/// change, not two: the grant makes the real home reachable, and this is what
/// makes the app look there. Reading the passwd entry instead is what gives the
/// same answer in both builds — `getpwuid` needs no entitlement and reports the
/// real home under the sandbox (measured), where `NSHomeDirectory()` does not.
///
/// A second, older divergence is closed at the same time: a caller that computed
/// `HOME` differently from the guard could display a path as `~/…` while the
/// guard judged it against another root. There is now one answer.
nonisolated enum AppEnvironment {
    /// The user's real home directory, always with no trailing slash.
    ///
    /// `getpwuid(getuid())` is the user database's answer. `NSHomeDirectory()` is
    /// the fallback for the case it cannot answer (no passwd entry), which keeps
    /// this total rather than optional — an app that cannot name the home folder
    /// cannot scan one.
    static let realHome: String = {
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir {
            let path = String(cString: dir)
            if !path.isEmpty {
                // Standardized so `path + "/" + rel` cannot double a slash, and
                // the guard's `home + "/"` prefix test stays exact.
                return (path as NSString).standardizingPath
            }
        }
        return (NSHomeDirectory() as NSString).standardizingPath
    }()

    /// Whether this process is sandboxed, read from its own signature.
    ///
    /// `com.apple.security.app-sandbox` in the code signing information is the
    /// authority — it is the key the kernel actually enforces, not a proxy for
    /// it. Measured true for a sandboxed bundle and false otherwise, both ways.
    ///
    /// `APP_SANDBOX_CONTAINER_ID` is a second, cheaper signal and was equally
    /// accurate, but it is an implementation detail of how the container is
    /// named. The signature is the fact, so it decides, and the environment
    /// variable is only used when the signature cannot be read at all.
    static let isSandboxed: Bool = {
        var selfCode: SecCode?
        guard SecCodeCopySelf([], &selfCode) == errSecSuccess, let code = selfCode else {
            return fallbackSandboxSignal
        }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let sc = staticCode else { return fallbackSandboxSignal }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(sc, SecCSFlags(rawValue: kSecCSSigningInformation),
                                           &information) == errSecSuccess,
              let entitlements = (information as? [String: Any])?["entitlements-dict"]
                as? [String: Any]
        else { return fallbackSandboxSignal }
        return entitlements["com.apple.security.app-sandbox"] as? Bool ?? false
    }()

    /// The environment signal, used only when the signature was unreadable.
    ///
    /// It can only ever say "sandboxed": an absent variable means the signature
    /// is the only evidence, and reading its absence as "not sandboxed" would be
    /// a guess with a permissive outcome. It is reached only on the unreadable
    /// path, where answering `false` would let a sandboxed build offer work it
    /// cannot do — the silent-failure this whole change exists to remove.
    private static var fallbackSandboxSignal: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }
}
