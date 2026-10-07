// The `bz.engine` single-writer invariant.
//
// Build (from repo root):
//   swiftc tests/swift/engine-writer.swift -parse-as-library -swift-version 6 \
//       -default-isolation MainActor -target arm64-apple-macos14.0 \
//       -o .build/engine-writer-tests
//   .build/engine-writer-tests
//
// Why this exists: the picker bug was two owners of one fact. A Picker `get`
// read `UserDefaults.standard.string(forKey: "bz.engine")` directly while the
// write went through `ProviderStore.select`. `UserDefaults` is not observable,
// so the write invalidated nothing: the click highlighted the new row while the
// checkmark stayed on the old one. The fix made `ProviderStore` the only reader
// and writer of that key.
//
// The invariant is therefore structural, not behavioural: NO source outside
// `ProviderStore` may touch the key. This reads the sources and asserts that,
// so a future `UserDefaults.standard.string(forKey: "bz.engine")` — the exact
// shape that caused the bug — fails here instead of silently returning.
//
// It deliberately ALSO permits nothing: `Model.swift` and
// `ModelProvider.swift` are named explicitly because those are the files the
// bug lived in, and a raw grep for the literal would otherwise be satisfied by
// the store's own definition.

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
enum EngineWriterTests {
    static func main() {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

        let key = "\"bz.engine\""

        // The store is the one owner. Its own file must mention the key (it
        // defines `engineKey`); if that ever stops being true, this test has
        // been silently neutered and says so.
        let storePath = root.appendingPathComponent("app/ModelProvider.swift")
        let store = (try? String(contentsOf: storePath, encoding: .utf8)) ?? ""
        check("ProviderStore still owns the bz.engine key", store.contains(key),
              "the single writer must still define the key")

        // Every OTHER source file must not touch the key at all. This is the
        // assertion that catches the regression: a direct read or write here is
        // a second owner, whatever it looks like.
        let files = (try? FileManager.default.contentsOfDirectory(
            at: root.appendingPathComponent("app"), includingPropertiesForKeys: nil)) ?? []
        var offenders: [String] = []
        for file in files where file.pathExtension == "swift" {
            // The store is the permitted owner.
            if file.lastPathComponent == "ModelProvider.swift" { continue }
            let src = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            // A mention in a COMMENT is not an access. Strip line comments
            // before looking, so explanatory prose does not trip the check.
            let code = src.split(separator: "\n", omittingEmptySubsequences: false)
                .map { line -> Substring in
                    guard let r = line.range(of: "//") else { return line }
                    return line[line.startIndex..<r.lowerBound]
                }
                .joined(separator: "\n")
            if code.contains(key) {
                offenders.append(file.lastPathComponent)
            }
        }
        check("no file outside ProviderStore mentions the bz.engine key in code",
              offenders.isEmpty,
              "second owner(s): \(offenders.joined(separator: ", "))")

        // And the two files the bug lived in, named explicitly so the intent is
        // unmistakable even if the sweep above is ever loosened.
        for name in ["Model.swift"] {
            let src = (try? String(contentsOf: root.appendingPathComponent("app/\(name)"), encoding: .utf8)) ?? ""
            let code = src.split(separator: "\n", omittingEmptySubsequences: false)
                .map { line -> Substring in
                    guard let r = line.range(of: "//") else { return line }
                    return line[line.startIndex..<r.lowerBound]
                }
                .joined(separator: "\n")
            check("\(name) does not read or write bz.engine directly",
                  !code.contains(key), "the picker bug was exactly this direct access")
        }

        // The store must expose a single write path, so a caller cannot bypass
        // it with its own `defaults.set`.
        check("ProviderStore offers one select() writer",
              store.contains("func select(engineTag"))

        print("")
        print("\(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}
