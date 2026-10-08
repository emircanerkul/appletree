// Shell-environment and ShellRunner regression net.
//
// Build (from repo root):
//   swiftc tests/swift/shellenv.swift app/AgentSupport.swift app/PlanParsing.swift \
//       -parse-as-library -swift-version 6 -default-isolation MainActor \
//       -target arm64-apple-macos14.0 -o .build/shellenv-tests
//   .build/shellenv-tests
//
// Two defects this exists for, both measured on the target host:
//
// 1. A login shell that fails or times out prints no `BZPATH=`, and `find()`
//    silently kept the bare Apple default (`/usr/bin:/bin:/usr/sbin:/sbin`).
//    That PATH contains neither `/opt/homebrew/bin` (brew) nor `~/.local/bin`
//    (uv), so every allowlisted cleanup-command row failed with "command not
//    found" while the tool was installed. The fix added an explicit augmented
//    fallback; these checks pin it so the bare default cannot come back.
//
// 2. `ShellRunner.run` collapsed "could not start", "timed out" and "exited"
//    into one sentinel status, and DISCARDED the output of a shell it timed
//    out — a shell that printed `BZPATH=` and then hung lost it. The outcome
//    type separates the cases and keeps partial output.
//
// A live process is used only for the timeout checks; everything about the
// PATH decision runs against literal shell output, so it is deterministic.

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
enum ShellEnvironmentTests {
    static func main() {
        // The home the fallback names must be the one owner's answer, not the
        // process home: under the sandbox `NSHomeDirectory()` is the container,
        // so a `~/.local/bin` built from it pointed at an empty directory (Task 4).
        let home = AppEnvironment.realHome

        // --- B2: a failed login shell must NOT leave the bare Apple default ---
        //
        // This is the exact measured failure: no `BZPATH=` line at all.
        let none = ShellRunner.environment(fromShellOutput: "")
        check("no BZPATH falls back rather than keeping the Apple default",
              none.source == .fallback, "source was \(none.source)")
        check("the fallback is not the bare Apple default",
              none.path != "/usr/bin:/bin:/usr/sbin:/sbin",
              "got \(none.path)")
        check("the fallback carries ~/.local/bin (uv and friends)",
              none.contains(directory: "\(home)/.local/bin"), "got \(none.path)")
        check("the fallback carries /opt/homebrew/bin (brew)",
              none.contains(directory: "/opt/homebrew/bin"), "got \(none.path)")
        check("the fallback carries /usr/local/bin (Intel Homebrew)",
              none.contains(directory: "/usr/local/bin"), "got \(none.path)")
        // The fallback must still be a usable PATH, not a replacement for one.
        check("the fallback keeps the system directories",
              none.contains(directory: "/usr/bin") && none.contains(directory: "/bin"),
              "got \(none.path)")

        // A timed-out shell's partial output is the other route to "no PATH":
        // it must take the same fallback, not a different one.
        let partialNoPath = ShellRunner.environment(fromShellOutput: "some profile noise\n")
        check("garbage without BZPATH also falls back",
              partialNoPath.source == .fallback && partialNoPath.contains(directory: "/opt/homebrew/bin"),
              "got \(partialNoPath.source) \(partialNoPath.path)")

        // --- A real answer is used verbatim --------------------------------
        let real = "/opt/homebrew/bin:/usr/bin:/bin:\(home)/.local/bin"
        let fromShell = ShellRunner.environment(fromShellOutput: "BZPATH=\(real)\n")
        check("a BZPATH answer is used as-is",
              fromShell.path == real, "got \(fromShell.path)")
        check("a BZPATH answer is marked as coming from the login shell",
              fromShell.source == .loginShell, "source was \(fromShell.source)")
        // The const: the fallback must never leak into a measured path, and the
        // measured path must never be silently augmented.
        check("a measured path is not silently altered",
              !fromShell.contains(directory: "/usr/local/bin"),
              "the shell's answer must be what is used")

        // A profile may echo more than one; the last one is the live one (an
        // earlier `echo` of a saved value must not win).
        let twoEchoes = "BZPATH=/first/bin\nmore\nBZPATH=/last/bin\n"
        check("the last BZPATH wins when a profile echoes several",
              ShellRunner.environment(fromShellOutput: twoEchoes).path == "/last/bin",
              "got \(ShellRunner.environment(fromShellOutput: twoEchoes).path)")

        // An empty value is not a PATH: it must not be taken as the answer.
        check("an empty BZPATH is treated as no answer",
              ShellRunner.environment(fromShellOutput: "BZPATH=\n").source == .fallback,
              "an empty path would find nothing at all")

        // A directory test must be segment-wise: a prefix must not count.
        let env = ShellEnvironment(loginShellPath: "/opt/homebrew/bin2:/usr/bin")
        check("contains is segment-wise, not a substring match",
              !env.contains(directory: "/opt/homebrew/bin"),
              "a substring test would call /opt/homebrew/bin2 a match")

        // --- B4: the three outcomes are distinct ----------------------------
        let finished = ShellRunner.run("/bin/sh", ["-c", "echo hi; exit 3"])
        check("a completed process reports finished with its status",
              finished == .finished(status: 3, output: "hi\n"),
              "got \(finished)")
        check("finished output is readable through .output",
              finished.output == "hi\n", "got \(finished.output.debugDescription)")

        let missing = ShellRunner.run("/definitely/not/here/bz", [])
        check("an executable that cannot start reports notStarted",
              missing == .notStarted, "got \(missing)")
        check("notStarted yields no output",
              missing.output.isEmpty, "got \(missing.output.debugDescription)")

        // --- B4: a timed-out shell KEEPS its partial output -----------------
        // `echo` first, then hang: the PATH line is written before the timeout,
        // so discarding it (the old behaviour) is exactly the B2 regression.
        let started = Date()
        let timedOut = ShellRunner.run("/bin/sh", ["-c", "echo BZPATH=/partial/bin; sleep 30"],
                                       timeout: 0.5)
        let elapsed = Date().timeIntervalSince(started)
        switch timedOut {
        case .timedOut(let output):
            check("a timed-out shell reports timedOut", true)
            check("timed-out output is KEPT, not discarded",
                  output.contains("BZPATH=/partial/bin"), "got \(output.debugDescription)")
            // The partial output must actually feed the PATH decision.
            check("a timed-out shell's BZPATH still resolves",
                  ShellRunner.environment(fromShellOutput: output).path == "/partial/bin",
                  "the whole point of keeping partial output")
        default:
            check("a timed-out shell reports timedOut", false, "got \(timedOut)")
            check("timed-out output is KEPT, not discarded", false, "case was not timedOut")
            check("a timed-out shell's BZPATH still resolves", false, "case was not timedOut")
        }
        // The escalation must be quick and bounded, not another full wait.
        check("the timeout is honoured promptly (bounded SIGTERM grace)",
              elapsed < 8, "took \(String(format: "%.2f", elapsed))s")

        // --- B4: no child of `run` survives it -------------------------------
        // A process that IGNORES SIGTERM must be SIGKILLed. `perl` is used
        // because it can ignore TERM portably and ships with macOS; if it is
        // absent the check is skipped rather than falsely passed.
        //
        // The invariant is about the process `run` STARTED — the direct child.
        // A grandchild it spawned is not something `run` can reasonably reach,
        // so this tags the child with a unique argv token and looks for it in
        // the process table.
        if FileManager.default.isExecutableFile(atPath: "/usr/bin/perl") {
            let token = "bzshellenv-\(UUID().uuidString)"
            let script = "$SIG{TERM}='IGNORE'; $0='\(token)'; sleep 30;"
            let outcome = ShellRunner.run("/usr/bin/perl", ["-e", script], timeout: 0.6)
            if case .timedOut = outcome {
                check("a SIGTERM-ignoring child times out", true)
            } else {
                check("a SIGTERM-ignoring child times out", false, "got \(outcome)")
            }
            // Read the process table by argv. `ps` output is the evidence; the
            // token is unique, so any hit is the child `run` left behind.
            let ps = ShellRunner.run("/bin/ps", ["-ax", "-o", "command="]).output
            check("the killed child is gone from the process table",
                  !ps.contains(token), "a survivor holds the stdout pipe open forever")
        } else {
            print("SKIP perl is unavailable; SIGTERM-ignore escalation not exercised live")
        }

        print("")
        print("\(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}
