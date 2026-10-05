import AppKit
import SwiftUI

// MARK: - Where the app sends people

/// Every external destination the interface offers, in one place.
///
/// These were previously nowhere: the Help menu fell through to AppKit's
/// "Help isn't available for AppleTree", and About carried no link to the
/// project at all. One owner means the menu and the About panel cannot point
/// at two different repositories.
nonisolated enum AppLinks {
    static let repo = URL(string: "https://github.com/emircanerkul/appletree")!
    /// The template chooser, so a reporter picks a form instead of a blank box.
    static let newIssue = URL(string: "https://github.com/emircanerkul/appletree/issues/new/choose")!
    static let security = URL(string: "https://github.com/emircanerkul/appletree/security/policy")!
    static let license = URL(string: "https://github.com/emircanerkul/appletree/blob/main/LICENSE")!

    static func open(_ url: URL) { NSWorkspace.shared.open(url) }
}

/// One row the Help menu and the About panel both offer.
nonisolated struct AppLinkItem: Identifiable, Sendable {
    let id: String
    /// Menu row and, lowercased in copy, the About panel's action.
    let title: String
    /// One line describing where the link goes, menu tooltips included.
    let detail: String
    let url: URL

    /// What the Help menu lists, in the same order as the repository's template
    /// chooser so the app and the tracker name the same destinations.
    ///
    /// Feature requests and questions open their own issue forms rather than
    /// Discussions: Discussions is not enabled on this repository, so a link
    /// there would 404 for everyone who clicked it.
    static let all: [AppLinkItem] = [
        AppLinkItem(id: "bug", title: String(localized: "Bug Report"),
                    detail: String(localized: "Report a bug in AppleTree"),
                    url: AppLinks.newIssue),
        AppLinkItem(id: "security", title: String(localized: "Report a security vulnerability"),
                    detail: String(localized: "Please review our security policy for more details"),
                    url: AppLinks.security),
        AppLinkItem(id: "feature", title: String(localized: "Feature request"),
                    detail: String(localized: "Propose a feature in the issue tracker"),
                    url: URL(string: "https://github.com/emircanerkul/appletree/issues/new?template=feature_request.yml")!),
        AppLinkItem(id: "question", title: String(localized: "Question"),
                    detail: String(localized: "Ask a question in the issue tracker"),
                    url: URL(string: "https://github.com/emircanerkul/appletree/issues/new?template=question.yml")!),
        AppLinkItem(id: "repo", title: String(localized: "AppleTree on GitHub"),
                    detail: String(localized: "Browse the source, releases and issues"),
                    url: AppLinks.repo),
    ]
}

// MARK: - About

/// The running app's version, read from the bundle the window actually came
/// from — never a constant, which would drift from `CFBundleShortVersionString`
/// the moment a release bumped it. Empty only when the process has no bundle
/// (a test host), in which case the panel omits the line rather than showing a
/// stray dash.
nonisolated var appVersion: String {
    (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? ""
}

/// Replaces AppKit's stock About panel.
///
/// The stock panel shows a name, a version and a copyright line, which leaves
/// the one thing worth saying unsaid: AppleTree is open source, and here is
/// where it lives. SwiftUI has no About scene, so this hosts the view in a
/// small window of its own.
@MainActor
final class AboutWindow {
    /// Held because an NSWindow released on close would be gone the second
    /// time the menu item is used.
    private static var controller: NSWindowController?

    static func show() {
        if let controller {
            controller.showWindow(nil)
            controller.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        // A real panel: titled, closable, not resizable, and centred. The
        // window keeps its content alive across close/reopen.
        let window = NSWindow(contentViewController: NSHostingController(rootView: AboutView()))
        window.title = String(localized: "About AppleTree")
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        let controller = NSWindowController(window: window)
        Self.controller = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct AboutView: View {
    var body: some View {
        // The main window is dark-only (see AppleTreeApp), so the About panel
        // follows it rather than opening light beside a dark app.
        content.preferredColorScheme(.dark)
    }

    private var content: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)

            VStack(spacing: 2) {
                Text("AppleTree")
                    .font(.title2.weight(.semibold))
                // Omitted rather than dashed when the host has no bundle.
                if !appVersion.isEmpty {
                    Text(String(localized: "Version \(appVersion)"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            Text("AppleTree shows you what is filling your disk, and cleans up the folders tools rebuild on demand. Nothing is removed without your say-so.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 6) {
                Button(String(localized: "Open source on GitHub")) { AppLinks.open(AppLinks.repo) }
                    .buttonStyle(.borderedProminent)
                Button(String(localized: "View license")) { AppLinks.open(AppLinks.license) }
                    .buttonStyle(.link)
            }

            // Precise on purpose: the commercial grant covers running a
            // purchased copy, not the source code. See LICENSE.
            Text("Free for non-commercial use. Buy it on the App Store to use the app commercially.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Text("© 2026 Emircan ERKUL")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.top, 2)
        }
        .padding(24)
        .frame(width: 420)
    }
}
