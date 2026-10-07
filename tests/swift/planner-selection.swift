// Planner-selection harness.
//
// Build (from repo root):
//   swiftc tests/swift/planner-selection.swift app/ModelProvider.swift \
//       app/AgentSupport.swift app/PlanParsing.swift \
//       -parse-as-library -swift-version 6 -default-isolation MainActor \
//       -target arm64-apple-macos14.0 -framework Security -o .build/planner-selection-tests
//   .build/planner-selection-tests
//
// The bug this exists for: picking a second provider in Settings changed the
// stored `bz.engine` but the Picker's checkmark stayed put. Its `get` read
// `UserDefaults` directly, which is not observable, so writing the key
// invalidated nothing — the click highlighted the new row while the checkmark
// stayed on the old one, and the selection looked like it had not taken.
//
// The fix moved the tag onto `ProviderStore`, which is `@Observable`. These
// checks pin the properties that made the difference: the store publishes the
// tag, everything reads it from one place, and it cannot be left dangling.
//
// `ProviderStore` writes to `UserDefaults`, so the harness points the process
// at a scratch suite first: a test must never edit the user's real choice.

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

func provider(_ id: String, model: String) -> LLMProvider {
    LLMProvider(id: id, displayName: id,
                baseURL: URL(string: "https://\(id).example/v1")!,
                api: .openAIChat, model: model)
}

@main
enum PlannerSelectionTests {
    static func main() {
        // A scratch suite, injected into the store, so the run cannot disturb
        // the user's real choice: save/delete/select all write to whichever
        // defaults the store was built with.
        let suite = "com.erklab.appletree.tests.\(UUID().uuidString)"
        guard let scratch = UserDefaults(suiteName: suite) else {
            print("FAIL could not create a scratch defaults suite"); exit(1)
        }
        let realBefore = UserDefaults.standard.string(forKey: "bz.engine")

        let store = ProviderStore(defaults: scratch)
        let a = provider("alpha", model: "m-alpha")
        let b = provider("beta", model: "m-beta")
        store.save(a, key: nil)
        store.save(b, key: nil)

        // --- The tag is the store's, and selecting publishes it --------------
        check("the store starts with no explicit choice",
              store.engineTag == nil || store.engineTag!.hasPrefix("provider:"),
              "got \(store.engineTag ?? "nil")")

        store.select(engineTag: "provider:beta")
        check("selecting publishes the tag",
              store.engineTag == "provider:beta", "got \(store.engineTag ?? "nil")")

        // This is the regression itself: the resolver must return what was
        // selected, reading the SAME source the Picker's get uses. When the
        // get read UserDefaults and the set wrote it, these two disagreed.
        let choices = PlannerChoice.catalog(providers: store.providers)
        let resolvedAfterPick = PlannerChoice.preferredID(stored: store.engineTag, in: choices)
        check("the resolved planner follows the pick",
              resolvedAfterPick == "provider:beta", "got \(resolvedAfterPick ?? "nil")")

        // --- Switching back works too (not a one-way latch) -------------------
        store.select(engineTag: "provider:alpha")
        check("switching back re-resolves",
              PlannerChoice.preferredID(stored: store.engineTag, in: choices) == "provider:alpha",
              "got \(PlannerChoice.preferredID(stored: store.engineTag, in: choices) ?? "nil")")

        // --- The published value is the stored one ----------------------------
        // Two owners of the same fact is how this class of bug starts: the
        // store must be the only writer, so what it publishes and what a fresh
        // read of the defaults sees cannot drift.
        let fresh = scratch.string(forKey: "bz.engine")
        check("the stored tag matches the published one",
              fresh == store.engineTag, "stored \(fresh ?? "nil") vs published \(store.engineTag ?? "nil")")

        // --- Deleting the selected provider clears the choice -----------------
        // Otherwise the Picker's tag would match no row and render blank, and
        // the panel would run a provider that no longer exists.
        let choicesWithBeta = PlannerChoice.catalog(providers: store.providers)
        check("beta resolves while it exists",
              PlannerChoice.preferredID(stored: "provider:beta", in: choicesWithBeta) == "provider:beta")
        // Select beta FIRST: deleting a provider that is not the choice must
        // leave the choice alone, which is the separate case below.
        store.select(engineTag: "provider:beta")
        store.delete(b)
        check("deleting the selected provider clears the tag",
              store.engineTag == nil, "got \(store.engineTag ?? "nil")")
        let afterDelete = PlannerChoice.catalog(providers: store.providers)
        check("the remaining provider leads after the delete",
              PlannerChoice.preferredID(stored: store.engineTag, in: afterDelete) == "provider:alpha",
              "got \(PlannerChoice.preferredID(stored: store.engineTag, in: afterDelete) ?? "nil")")

        // Deleting a provider that was NOT selected must leave the choice alone.
        store.save(provider("gamma", model: "g"), key: nil)
        store.select(engineTag: "provider:alpha")
        store.delete(provider("gamma", model: "g"))
        check("deleting an unselected provider keeps the choice",
              store.engineTag == "provider:alpha", "got \(store.engineTag ?? "nil")")

        // --- A stale tag from an older install still resolves -----------------
        store.select(engineTag: "provider:deleted-long-ago")
        let final = PlannerChoice.catalog(providers: store.providers)
        check("a stale tag falls back to a configured provider",
              PlannerChoice.preferredID(stored: store.engineTag, in: final) == "provider:alpha",
              "got \(PlannerChoice.preferredID(stored: store.engineTag, in: final) ?? "nil")")

        // The real preference must be exactly as it was: this harness is not
        // allowed to change the user's planner choice.
        check("the user's real bz.engine was never touched",
              UserDefaults.standard.string(forKey: "bz.engine") == realBefore,
              "was \(realBefore ?? "nil"), now \(UserDefaults.standard.string(forKey: "bz.engine") ?? "nil")")
        UserDefaults.standard.removePersistentDomain(forName: suite)
        print("")
        print("\(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}
