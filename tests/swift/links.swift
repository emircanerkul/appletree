// Help-menu and About-panel link regression net.
//
// Build (from repo root):
//   swiftc tests/swift/links.swift app/AppMenu.swift \
//       -parse-as-library -swift-version 6 -default-isolation MainActor \
//       -target arm64-apple-macos14.0 -framework AppKit \
//       -o .build/link-tests
//
// Why this exists: the first cut of the Help menu pointed "Feature request" and
// "Question" at GitHub Discussions, which is NOT enabled on this repository —
// every reporter who clicked would have hit a 404. The destinations are data,
// so they can be asserted here rather than discovered by a user.
//
// These assertions are offline: they check the URLs the app will open, not that
// github.com is reachable. `make test-links` stays hermetic.

import Foundation

var failed = 0
var passed = 0

func check(_ name: String, _ condition: Bool, _ detail: String = "") {
    if condition {
        passed += 1
        print("PASS \(name)")
    } else {
        failed += 1
        print("FAIL \(name)\(detail.isEmpty ? "" : ": \(detail)")")
    }
}

@main
enum LinkTests {
    static func main() {
        let items = AppLinkItem.all

        // The Help menu lists the App Store listing, the destinations the
        // tracker offers, and the repo.
        check("Help menu has six rows", items.count == 6, "got \(items.count)")

        // One row per destination, no duplicates: a copy-paste slip that left two
        // rows pointing at the same page would otherwise ship silently.
        let ids = items.map(\.id)
        check("row ids are unique", Set(ids).count == ids.count, "\(ids)")
        let urls = items.map(\.url.absoluteString)
        check("row urls are unique", Set(urls).count == urls.count, "\(urls)")

        // Every row is https, and points at either this project on GitHub or the
        // public App Store listing. Nothing else may appear in the menu.
        for item in items {
            let onGitHub = item.url.host == "github.com"
                && item.url.path.hasPrefix("/emircanerkul/appletree")
            let onAppStore = item.url.host == "apps.apple.com"
            check("\(item.id) links to the project on https",
                  item.url.scheme == "https" && (onGitHub || onAppStore),
                  item.url.absoluteString)
            check("\(item.id) has a title", !item.title.isEmpty)
            check("\(item.id) has a detail line", !item.detail.isEmpty)
        }

        // The App Store row must open the PUBLIC listing, never App Store
        // Connect: the Connect distribution URL is a signed-in dashboard
        // (verified: it redirects to a login wall), so it would dead-end every
        // buyer who clicked it.
        let appStore = items.first { $0.id == "appstore" }
        check("the App Store row exists", appStore != nil)
        check("the App Store row uses the public listing",
              appStore?.url.host == "apps.apple.com",
              appStore?.url.absoluteString ?? "missing")
        for item in items {
            check("\(item.id) never points at App Store Connect",
                  item.url.host != "appstoreconnect.apple.com",
                  item.url.absoluteString)
        }

        // The specific regression: Discussions is disabled, so NO row may point
        // at it. If Discussions is ever enabled, this test is the place that
        // records the decision to move the rows.
        for item in items {
            check("\(item.id) does not point at Discussions",
                  !item.url.path.contains("/discussions"),
                  item.url.absoluteString)
        }

        // Feature requests and questions use the issue forms, so the template
        // chooser and the app name the same process.
        let feature = items.first { $0.id == "feature" }
        check("feature row opens the feature form",
              feature?.url.absoluteString.contains("template=feature_request.yml") == true,
              feature?.url.absoluteString ?? "missing")
        let question = items.first { $0.id == "question" }
        check("question row opens the question form",
              question?.url.absoluteString.contains("template=question.yml") == true,
              question?.url.absoluteString ?? "missing")

        // The bug row opens the chooser, so a reporter sees the forms.
        let bug = items.first { $0.id == "bug" }
        check("bug row opens the issue template chooser",
              bug?.url.absoluteString.hasSuffix("/issues/new/choose") == true,
              bug?.url.absoluteString ?? "missing")

        // Security points at the policy page, which is what the tracker's own
        // contact link uses, so the app and the tracker agree.
        let security = items.first { $0.id == "security" }
        check("security row opens the security policy",
              security?.url.absoluteString.hasSuffix("/security/policy") == true,
              security?.url.absoluteString ?? "missing")

        // A real ACTION row exists for the repo, because the About panel's
        // "open source" claim needs somewhere to go.
        let repo = items.first { $0.id == "repo" }
        check("repo row points at the project root",
              repo?.url.absoluteString == "https://github.com/emircanerkul/appletree",
              repo?.url.absoluteString ?? "missing")

        // The erklab mark in About links to the maker's site. It is not a Help
        // menu row, so it is asserted against AppLinks directly.
        check("the erklab link is https on erklab.com",
              AppLinks.erklab.scheme == "https" && AppLinks.erklab.host == "erklab.com",
              AppLinks.erklab.absoluteString)
        // Two-letter hosts are easy to typo, and a wrong one would 404 silently
        // from a button that looks correct.
        check("the erklab link is the bare host, not www",
              AppLinks.erklab.host == "erklab.com",
              AppLinks.erklab.absoluteString)

        // The About panel's version comes from the bundle, never a constant. A
        // test binary has no version key, so this asserts the reader is wired to
        // the bundle rather than to a literal — the real app's value is checked
        // by the deployed-bundle smoke step, not here.
        check("version reader is bundle-backed, not hardcoded",
              appVersion.isEmpty
              || Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") is String,
              "got \(appVersion.debugDescription)")

        print("\(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}
