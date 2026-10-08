# AppleTree Support

AppleTree is a disk-space treemap for macOS: scan a drive, see what is filling it, and clean up the folders that tools rebuild on demand.

See also: **[Privacy Policy](https://github.com/emircanerkul/appletree/blob/main/docs/wiki/Privacy-Policy.md)** · **[Home](https://github.com/emircanerkul/appletree#readme)**

---

## Before you write in

Most questions are answered faster here than by email.

**The documentation ships with the app.** **Help → AppleTree README** opens it in a window. It needs no browser and no internet connection, because the file is bundled inside the app. It covers scanning, the treemap and rings views, navigation, the Clean Up panel, and the JSON command-line tool.

**The license is bundled too.** **Help → AppleTree License** opens it the same way.

---

## Requirements

| | |
|---|---|
| **macOS** | 14.0 (Sonoma) or later |
| **Chip** | Apple silicon (M-series) |
| **Disk space** | About 6 MB for the app itself |
| **Full Disk Access** | Needed to scan a whole disk; not needed to scan folders you pick |
| **Language** | English, Türkçe, Deutsch, Français, Español, 简体中文, 日本語 |

Intel Macs are not supported: the app and its scan engine are built for Apple silicon only.

---

## Getting help

| I want to… | Where to go |
|---|---|
| Report a bug | [Open a bug report](https://github.com/emircanerkul/appletree/issues/new?template=bug_report.yml) |
| Request a feature | [Open a feature request](https://github.com/emircanerkul/appletree/issues/new?template=feature_request.yml) |
| Ask a question | [Open a question](https://github.com/emircanerkul/appletree/issues/new?template=question.yml) |
| Report a security problem | **security@appletree.apps.erklab.com** — please do not use a public issue |
| Privacy questions or requests | **privacy@appletree.apps.erklab.com** |
| Anything else | **support@appletree.apps.erklab.com** |

All three addresses reach the same person, who also maintains the repository. If you would rather not use email, the issue forms above are public and just as good for anything that is not a security report.

The same links are in the app under **Help**.

---

## Frequently asked

### AppleTree found less space than Finder, or less than my disk's capacity

Expected, and not a bug. Four separate reasons, in order of how much they usually explain:

1. **"Macintosh HD" in System Settings is not one volume.** macOS splits the boot
   disk into a *volume group*: the sealed read-only **System** volume, your
   **Data** volume, and three more for boot staging, swap and recovery. AppleTree
   scans the Data volume — where your files actually are — and names it
   "Macintosh HD". The other four are separate volumes macOS keeps outside it, so
   they are not part of the scan:

   | Volume | Typical size |
   | --- | --- |
   | Macintosh HD - Data | yours — this is what AppleTree scans |
   | Preboot | 10–25 GB |
   | Macintosh HD (System) | ~14 GB |
   | VM (swap) | 5–15 GB, grows with memory pressure |
   | Recovery | ~3 GB |

   On a 245 GB Mac that is roughly **50 GB** the app never walks, and it is the
   single largest reason the numbers differ. `diskutil apfs list` lists all five
   with their sizes.
2. **Full Disk Access is not granted.** Root-only system data is invisible to *every* tool without it, not just AppleTree. Grant it in **System Settings → Privacy & Security → Full Disk Access** and rescan.
3. **APFS volume sharing.** Several volumes on one container report the same free space, because they draw on one shared pool. The app shows what the filesystem reports.
4. **Purgeable space and snapshots.** macOS does not count Time Machine local snapshots or purgeable space as free, and neither does AppleTree. `diskutil apfs listSnapshots /` shows the former.

**"Free space" in the panel includes purgeable space**, so it reads higher than
Finder's or `df`'s figure. Measured on one 245 GB Mac: the panel showed 35.27 GB
while the real available space was 25.91 GB. The panel answers "how much could
macOS free if it needed to"; Finder answers "how much is free right now".

The app is explicit about this: when a whole-disk scan cannot read everything, it
reports the coverage rather than quietly presenting a smaller number as the truth.

### Why does scanning my whole disk ask for Full Disk Access?

macOS gates the folders that make a whole-disk scan meaningful — other users' homes, system caches, some app containers. Without the permission the scan still runs, but it silently misses those, which would make the map wrong rather than merely incomplete. AppleTree asks instead of guessing.

You do not need it to scan your home folder, `/Applications`, or any folder you choose yourself.

### I revoked Full Disk Access but the app still seems to have it

That is how macOS behaves: it stops applying a revocation to a process that is already running. Quit AppleTree, remove its row in **System Settings → Privacy & Security → Full Disk Access**, then relaunch. See [Privacy Policy §3](https://github.com/emircanerkul/appletree/blob/main/docs/wiki/Privacy-Policy.md) for the related note about child processes.

### The Clean Up button is greyed out

It needs a finished scan. Scan a drive first — the panel lists reclaimable folders from that scan, so with no scan there is nothing to offer. If the drawer is already open the button stays usable so you can close it.

### The AI cleanup does nothing, or the button only offers to add a provider

The AI cleanup needs a model provider you configure. Open **Settings → Model
Providers** and add any OpenAI- or Anthropic-compatible endpoint — a relay, a
self-hosted server (Ollama, LM Studio) or a gateway — with its base URL,
protocol and model. A local endpoint keeps everything on your Mac.

Either way, the AI cleanup is optional. The Clean Up panel's own cache detection works with no provider configured at all — it has no AI dependency.

### Do I have to give the AI my files?

No. It receives a summary of the scan — paths, names, sizes and dates — never the contents of your files. The exact limits and what is included are in [Privacy Policy §5.2](https://github.com/emircanerkul/appletree/blob/main/docs/wiki/Privacy-Policy.md).

If you want the strongest option, configure a provider in **Settings → Model Providers** pointing at a model running on your own Mac (`Ollama`, `LM Studio`) or your own network. In that case nothing leaves your machine at all.

### I need to scan a network drive or a disk image

Those are excluded on purpose. AppleTree lists local storage volumes only — an external drive, a second internal partition — and excludes network volumes and mounted disk images by device properties rather than by name. Scanning an image file measures the image, not the disk it represents.

### How do I delete what AppleTree stores about me?

Everything is local and yours to remove: the app, `~/Library/Application Support/AppleTree`, the preferences, and your API keys in the Keychain. Step by step in [Privacy Policy §8.2](https://github.com/emircanerkul/appletree/blob/main/docs/wiki/Privacy-Policy.md). Reverting Full Disk Access is step 5 there.

### Is there a command-line version?

Yes, built from source. It is **not** bundled inside the Mac App Store app. From a checkout:

```sh
cargo build --locked --release --features cli --bin appletree
./target/release/appletree scan --root "$HOME/Downloads"
./target/release/appletree quick-wins --root "$HOME" --limit 20
```

`scan` prints the largest directories and files as JSON. `quick-wins` adds the Clean Up panel's folder candidates. Both are read-only and need no AI agent. See the README's "JSON CLI for agents and scripts" section.

### Can I use AppleTree at work, or in a commercial product?

Two different questions:

- **Using the app commercially.** Buy it on the [Mac App Store](https://apps.apple.com/app/id6819034229). A purchase grants that buyer commercial use of their own compiled copy. That is a personal permission and does not extend to anyone else.
- **Using the source code commercially.** Not permitted. The source is MIT for inherited portions and CC BY-NC-SA 4.0 for the rest, with no commercial grant. Buying the app does not license the code, and it does not allow redistribution, resale, or bundling AppleTree into another product.

The full text is in the [LICENSE](https://github.com/emircanerkul/appletree/blob/main/LICENSE).

### Something is wrong with the app itself

Quit and relaunch first — that clears most transient states. If it persists, [open a bug report](https://github.com/emircanerkul/appletree/issues/new?template=bug_report.yml) with your macOS version, your chip, and the steps that show it.

If the window is unresponsive, note that a scan of a very large or slow volume can take a while. The window stays interactive while it runs, and the Rescan button is disabled until the scan finishes — so if a scan seems stuck, quit and relaunch rather than waiting on a frozen window.

---

## Reporting a security problem

Please **do not** open a public issue. Use either:

- **GitHub private advisory** (preferred): <https://github.com/emircanerkul/appletree/security/advisories/new>
- **Email**: **security@appletree.apps.erklab.com**

A GitHub advisory stays visible only to the maintainer until a fix ships.

Include what you can of: what the problem is and what an attacker could do with it; your AppleTree version (**AppleTree → About AppleTree**) and macOS version; the smallest set of steps that shows it; and whether it needs a particular configuration, such as a custom model provider.

**Do not attach anything containing your own API keys or tokens.**
