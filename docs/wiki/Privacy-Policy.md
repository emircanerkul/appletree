# AppleTree Privacy Policy

**Bundle ID:** `com.erklab.apps.appletree`
**Published at:** https://github.com/emircanerkul/appletree/wiki/Privacy-Policy
**Last updated:** 5 October 2026
**Effective date:** 5 October 2026

This policy covers the AppleTree application for macOS and the optional `appletree` command-line tool built from the same source. It does not cover any other software or website.

See also: **[Support](https://github.com/emircanerkul/appletree/wiki/Support)** · **[Home](https://github.com/emircanerkul/appletree/wiki/Home)**

---

## The short version

AppleTree is a disk-space tool. Scanning, drawing the treemap, browsing folders and moving things to the Trash are all done on your Mac and never touch the network.

AppleTree has no accounts, no analytics, no crash reporting, no advertising SDK, no tracking, no iCloud sync and no servers of its own. It does not sell, rent or trade your data, and it never has.

There is exactly one situation in which anything leaves your Mac: when **you** start an AI cleanup. AppleTree then sends a summary of the scan — folder and file paths with their sizes — to the planner you chose. You trigger it deliberately, every single time, and you can use the app fully without it.

---

## 1. Who we are

AppleTree is developed and published by **Emircan ERKUL**, who is the data controller for the processing described in this policy.

For any privacy question, request or complaint: **privacy@appletree.apps.erklab.com**

---

## 2. What AppleTree does not do

Verified against the shipped binary:

- **No analytics or telemetry.** The app contains no analytics, crash-reporting, metrics or telemetry code of any kind. Nothing about your usage is counted, profiled, or transmitted to us or to anyone else. The local error and timing entries described in §4.5 are the only things ever written, and they never leave your Mac.
- **No advertising or tracking.** No ad SDK, no IDFA (Identifier for Advertisers), and no cross-app tracking. An App Tracking Transparency prompt is never shown, because no tracking occurs and the app does not request that permission.
- **No account.** There is no sign-up, no login, no user profile, no subscription and no server-side record of you.
- **No background sync.** No data is uploaded when you are not using the app, and nothing is uploaded when you close it.
- **No sale or sharing of data.** Your data is never sold, rented, licensed or shared with anyone for their own purposes.
- **No profiling.** AppleTree does not build a profile of you, your habits or your files beyond what is needed to draw the map you asked for.
- **No automatic updates.** AppleTree contains no auto-update or phone-home component. It contacts the network only in the situations listed in §5.

---

## 3. Full Disk Access

To scan a whole disk, AppleTree needs macOS **Full Disk Access**, which you grant yourself in **System Settings → Privacy & Security → Full Disk Access**.

This is a blanket read permission to your disk while it is granted. AppleTree uses it for one thing only: reading folder and file names, sizes and timestamps so it can draw the map. AppleTree does not ask for camera, microphone, location, contacts, photos, calendar or Bluetooth access, and it does not read the contents of your documents.

A whole-disk scan is never started without Full Disk Access. If you decline it, AppleTree still scans the folders you pick yourself, and every other feature works.

Reading your disk is local. Granting Full Disk Access does not cause anything to be uploaded.

**Two consequences worth knowing about, both of which are properties of macOS rather than of AppleTree:**

- **You can only remove the permission while the app is closed.** macOS stops applying a revocation to a process that is already running. To take Full Disk Access away, quit AppleTree, remove its row in **System Settings → Privacy & Security → Full Disk Access**, and relaunch.
- **Anything AppleTree launches inherits the grant for as long as it runs.** When you run an AI cleanup, the planner CLI — and any cleanup command AppleTree executes — runs as a child of AppleTree and therefore sees everything Full Disk Access allows. AppleTree limits what it hands them and which commands it will run (§5.8), but an operating-system permission cannot be handed to a child process in a reduced form. This is one reason the AI cleanup is entirely optional.

---

## 4. What AppleTree stores on your Mac

Everything AppleTree remembers is stored locally in two macOS-provided places, plus one file an AI cleanup run needs. None of it is transmitted to us, because we have no server to receive it.

### 4.1 Preferences (`UserDefaults`, domain `com.erklab.apps.appletree`)

| Preference | What it holds |
|---|---|
| `bz.autoScan` | Whether to scan automatically on launch |
| `bz.autoScanSet` | Whether you have answered the launch-scan question at all |
| `bz.showFree` | Whether to show the free-space block |
| `bz.mapStyle` | Treemap or rings view |
| `bz.listWidth` | Width of the outline list |
| `bz.scanRoot` | The folder you last scanned |
| `bz.trail`, `bz.trailIndex` | Your folder history and your position in it |
| `bz.showCleanup` | Whether the Clean Up panel is open |
| `bz.engine`, `bz.agent` | Which AI planner you selected |
| `bz.claudeModel` | Which Claude model to use |
| `bz.providers` | The model providers you configured: a name you typed, the base URL you typed, the API protocol, and the model ID |
| `AppleLanguages` | The interface language you chose |

**API keys are never stored in preferences.** `bz.providers` holds the base URL and model name only.

**Two of these record paths, which are the most personal things AppleTree keeps.** `bz.scanRoot` is the folder you last scanned, and `bz.trail` is your folder history — kept as up to **200 absolute paths**, oldest first, so the back and forward buttons survive a relaunch. Both can include your account name and the names of your folders, and a folder name can reveal what a project or client is. They are used for nothing but restoring your place, and they are covered by the deletion steps in §8.2. If you would rather they were not kept, deleting them costs you only the restored history.

### 4.2 Keychain

If you connect your own model provider, your API key is stored as a macOS **Keychain generic-password item** under the service name `com.erklab.apps.appletree.<provider id>`, account `api-key`. It is held by macOS, encrypted, protected by your login, and never written to a preference file, a log or a cache.

Keychain items are readable by AppleTree without a prompt. If you add or edit a provider while **Settings → Model Providers** is open, the key you type is written to the Keychain when you save. The deletion steps are in §8.2.

### 4.3 Application Support folder

AppleTree creates `~/Library/Application Support/AppleTree/` and writes only:

- `tools/package.json`, containing `{"name":"appletree-cleanup","private":true}` — an empty stand-in project so tools that expect one can run. It contains no data about you.

The agent process and AppleTree's own cleanup commands are started in this folder so that they load no project settings, hooks or memory from your own projects.

### 4.4 Developer benchmark hook

Three preferences (`bz.benchTiming`, `bz.benchResult`, `bz.benchExit`) exist for benchmarking the app by hand. They are **off unless you set them yourself** with the `defaults` command, are not exposed in the interface, and when enabled they write one JSON line containing the scan root path, elapsed seconds, file count, byte count, error count and memory figures to a file path you choose. Ordinary use of AppleTree never touches them.

### 4.5 Diagnostics

AppleTree has no crash reporter and uploads no logs. Three residual cases are worth stating explicitly, because "no telemetry" should not be taken to mean "nothing is ever written":

- **The optional `appletree` command-line tool writes nothing of its own.** It reports scan failures as a JSON error object on standard output with a non-zero exit code, in the manner of a normal Unix tool, and writes to standard error only if it cannot write its output at all. It keeps no log file. Note that if you redirect its output to a file, that file is yours and contains whatever JSON you asked for.
- **A failed AI request** is recorded in the local **system log** as `[bz] provider <name> failed: <message>`, where the message is the diagnostic text returned by the endpoint you configured. These entries stay on your Mac and are handled under Apple's own system-log policy; AppleTree has no access to them.
- **Developer timing traces** are measured into memory and printed to the local log **only** when a developer switch (`BZ_TIMING` in the environment, or the `bz.benchTiming` preference described in §4.4) is set. Neither is set in normal use.

None of these is transmitted anywhere.

---

## 5. What leaves your Mac — only when you ask

Nothing in this section happens unless you click a button. Each run is a separate, deliberate choice, and you can decline all of them and still use AppleTree completely.

The whole of §5.1 and §5.2 describes acts **you** perform — configuring a provider, choosing a planner, clicking "Clean up". AppleTree does not decide to transmit anything on its own.

### 5.1 AI cleanup, in general

AppleTree offers three planners: a model provider you configure, Claude Code, or Codex. Whichever you pick, the same thing happens first — AppleTree builds a text summary of your scan and hands it to that planner.

### 5.2 What is in that summary

Built from the scan you are looking at. It contains **paths, names, sizes, counts and dates only — never the contents of your files.**

| Included | Limit |
|---|---|
| Your home folder path (for example `/Users/yourname`) | — |
| The folder you scanned, or "whole disk" | — |
| Largest folder paths, each with allocated size and file count | up to 250 |
| Largest file paths, each with allocated size | up to 80 |
| Folders AppleTree recognises as rebuildable caches, with path and kind | up to 120 |
| Names and bundle identifiers of the apps currently running | all regular apps |
| Xcode simulator runtimes: identifier, platform and version, size, last-used date, path | 100 MB and over |
| Xcode simulator devices: name, state, size, last-used date, UDID, folder path | 100 MB and over |
| Codex chat folders: size, path, last-used date, the names and sizes of up to three subfolders | up to 40 |

The lists are **truncated by size and by count**. Folders smaller than about 100 MB and files smaller than about 250 MB do not appear, so a summary describes the big things on your disk rather than an inventory of it. At most roughly 490 paths can be involved.

Because this is a list of paths, it necessarily includes **folder and file names**, and those can themselves be personal information — the name of a client folder, a project, a photo export. That is a deliberate part of the feature: an AI planner cannot suggest what to remove without being told what is there.

Three details worth stating plainly:

**Running apps.** The list of running applications exists so AppleTree skips the caches of apps you currently have open, rather than cleaning under them. It is included in the summary so the planner makes the same judgement. A list of running apps is fairly revealing on its own; it is included because without it the planner would propose removals that break something you are using.

**Codex session logs.** To tell whether a Codex chat folder was used recently, AppleTree reads the first 8 KB of each `.jsonl` file in `~/.codex/sessions` and extracts only the working-directory path recorded there, along with the file's modification date. It does not read or send the content of those conversations. This happens on your Mac, when a cleanup is prepared; the extracted paths are what can then appear in the summary.

**Xcode simulator details.** Runtime identifiers, device names, UDIDs and folder paths are read from Xcode's own `simctl` tool and are only gathered when Xcode is installed with simulators present.

### 5.3 With a model provider you configure yourself

AppleTree sends one HTTPS request to the base URL you typed, containing the summary above and nothing else. Depending on the protocol you selected, this is `/chat/completions`, `/responses` or Anthropic's `/v1/messages`.

That endpoint runs no tools and is never given access to your disk. This is the option that keeps file contents local, and it is especially suitable when the endpoint is a model running on your own Mac or network — nothing leaves your machine in that case.

AppleTree sends your API key in the request header (`Authorization: Bearer …` or `x-api-key`) as that provider's API requires. AppleTree does not keep a copy.

### 5.4 With Claude Code or Codex

AppleTree launches the command-line agent you already have installed and gives it the same summary. That agent then runs on your Mac and may look further.

- **Claude Code** is invoked with `--tools Bash,Read`, `--permission-mode dontAsk`, `--no-session-persistence`, and a command allowlist limited to the read-only commands `du`, `ls`, `stat`, `docker system df`, `xcrun simctl list` and `ollama list`. It has no write or edit tool.
- **Codex** is started in a sandbox the app sets to **read-only**, with approvals disabled and no session persisted, so it cannot write to your disk either.

**Be clear about what this does and does not mean.** Read-only describes the *tools* and *sandbox* the app hands the agent; it does not restrict what the agent may read. Because these processes inherit Full Disk Access (§3), an agent can read files anywhere your account can reach, and whatever it reads may become part of its conversation with **Anthropic** or **OpenAI** and be handled under their terms, not ours. AppleTree cannot restrict what the agent chooses to read, and it cannot see what the agent read.

### 5.5 Fetching a model list

Only when you click **Fetch available models** in Settings → Model Providers, AppleTree sends `GET <base URL>/models` to the provider you are configuring, with your API key if you have entered one, so it can list the models available. Nothing is requested merely by opening the settings window. This is a convenience: an endpoint without that route simply leaves the model name to be typed in.

### 5.6 Installing an agent

Only when you click "Install":

- **Claude Code** runs Anthropic's own installer, fetched from `https://claude.ai/install.sh`. The script is downloaded at that moment, and what it does is decided by Anthropic, not by AppleTree.
- **Codex** downloads a pinned release tarball from `github.com/openai/codex/releases` and verifies its SHA-256 against a value compiled into AppleTree before installing anything. If the checksum does not match, nothing is installed.

Both install into `~/.local/bin` under your own account; no administrator password is requested and no privileged helper is installed. The Codex download is the Apple-silicon build, so Codex installation is offered on Apple-silicon Macs only; Claude Code is installed through Anthropic's own script.

### 5.7 Signing in to an agent

Only when you click "Sign in": AppleTree opens your default browser to the agent's own sign-in page. **AppleTree never sees your Anthropic or OpenAI password.** The CLI stores its own credential on your Mac, and AppleTree only runs the CLI's own `status` command to check whether a sign-in exists, so it can tell you whether the agent still needs one. Signing out likewise runs only the CLI's own logout command.

### 5.8 Cleanup commands run on your Mac, not by any server

The AI planner returns a proposed plan; it does not execute anything. AppleTree checks every proposed command against a fixed allowlist of **30** permitted forms, compiled into the app: **27** tool-specific cleanups that must match to the letter — `uv cache clean`, `brew cleanup`, `docker system prune`, `pod cache clean --all` and the like — plus **three** that accept exactly one trailing argument, with no flags: `ollama rm <model>`, `xcrun simctl runtime delete <id>` and `xcrun simctl erase <udid>`. Anything else is refused rather than run. AppleTree executes the permitted commands locally, as your user, in the stand-in folder described in §4.3.

These commands **delete cache and build output**, not documents. AppleTree blocks any path under your Documents, Desktop, Pictures, Movies, Music, `.ssh`, `.gnupg`, Keychain, Mail, Messages, Photos and cloud-storage folders, and it refuses any command containing a shell metacharacter, so a command cannot be chained into something else.

Everything the planner proposes appears in the Clean Up panel before anything happens, split into **"Safe to remove"** and **"Your call"**. Items the planner marks for your judgement are not removed until you approve them, and you can deselect any item. Nothing in this section runs without that approval.

---

## 6. Everything that stays local

For completeness, the following involve no network access at all, and send nothing anywhere:

- Scanning any drive, including whole-disk scans.
- Drawing and navigating the treemap, the rings and the outline list.
- Revealing in Finder, copying a path, selecting an enclosing folder.
- Moving files or folders to the Trash — from the map, the rings, the list or the Clean Up panel.
- Running the Clean Up panel's rebuildable-cache detection, and deleting what it moved.
- Changing your interface language.
- The optional Rust command-line tool, which reads the disk and prints JSON to standard output without opening the GUI or contacting the network.

---

## 7. Third parties

AppleTree talks to third parties only in the situations in §5, and only with data you deliberately sent.

| Third party | When | Their policy |
|---|---|---|
| **Anthropic** (Claude Code) | You run an AI cleanup with Claude Code, or install or sign in to it | [anthropic.com/legal/privacy](https://www.anthropic.com/legal/privacy) |
| **OpenAI** (Codex) | You run an AI cleanup with Codex, or install or sign in to it | [openai.com/policies/privacy-policy](https://openai.com/policies/privacy-policy/) |
| **GitHub** | You install Codex (one pinned download, checksum-verified) | [docs.github.com/privacy](https://docs.github.com/en/site-policy/privacy-policies/github-general-privacy-statement) |
| **Any provider you configure** | You run an AI cleanup, or fetch a model list, against it | **You choose this destination.** Review its policy before you use it. |

**On third-party protection (Apple Guideline 5.1.1(i)).** Any third party with which AppleTree shares user data is held to protections at least equal to those stated in this policy and to the standards Apple requires. Anthropic, OpenAI and GitHub are established services with published policies, linked above. For a model provider you configure yourself, you select the endpoint and control that relationship directly, so we ask you to satisfy yourself that its protections match yours; if they do not, do not use that endpoint, and use a local model instead.

---

## 8. How long data is kept, and how to delete it

**We keep no data, because we have no server.** There is no AppleTree account, no cloud copy and no backup of anything in this policy.

### 8.1 Withdrawing consent

Every network action in §5 is opt-in and must be triggered by you each time. You withdraw consent simply by not clicking. Declining costs you nothing: the treemap, rings, Clean Up panel and local Trash actions all work with no AI planner configured at all.

If you have already run a cleanup, removing the provider in **Settings → Model Providers** stops future requests to it. It cannot recall what was already sent; for that, see §8.3.

### 8.2 Deleting what AppleTree stores

All of it is on your Mac, and all of it is yours to remove:

1. **Delete the app.** Drag AppleTree to the Trash and empty it.
2. **Delete the working folder:**
   ```sh
   rm -rf ~/Library/Application\ Support/AppleTree
   ```
3. **Delete the preferences** — this also removes the scanned-folder path and your 200-entry folder history described in §4.1:
   ```sh
   defaults delete com.erklab.apps.appletree
   ```
4. **Delete your API keys** from Keychain: open **Keychain Access**, search for `com.erklab.apps.appletree`, and delete the matching `api-key` items — or remove the provider in **Settings → Model Providers** and delete its key.
5. **Revoke Full Disk Access** if you no longer want the app to have it: quit AppleTree first, then **System Settings → Privacy & Security → Full Disk Access** (§3).

### 8.3 Data held by third parties

AppleTree cannot delete transcripts from Anthropic or OpenAI, because it has no access to your account there. To exercise your rights over those, contact the provider directly and delete the conversation in your account with them. Claude Code is run with `--no-session-persistence`, so it does not keep a local session log of the cleanup run.

---

## 9. Your rights

### 9.1 Everyone

Because everything is stored locally on your Mac, you already have full access to all of it: it is either visible in the app, in the files named in §4, or in the Keychain item named there. You can read, export, correct or delete any of it at any time using the steps in §8.

You will never be charged more, given a worse experience, or locked out of a feature because you declined to share something. There is no paid tier that depends on it.

### 9.2 If you are in the EU, EEA, UK or Switzerland (GDPR)

Where AppleTree is the controller, we process personal data on the following bases:

- **Consent** — for the AI cleanup features in §5. You may withdraw it at any time by not using them, or by removing the provider; withdrawal does not affect anything already processed.
- **Legitimate interest** — relied on only for the local, on-device handling described in §4, which involves no transmission of your data to us or to anyone else. No legitimate-interest basis is relied on for any transmission of your data.
- **Legal obligation** — if we are ever required to retain something by law, which has not occurred to date.

You have the right to request access, rectification, erasure, restriction of processing, data portability and objection, and to lodge a complaint with your national data protection authority. Because we hold no data ourselves, requests about data AppleTree sent onward should be directed at the provider named in §7; we can help you identify which provider a given cleanup used on request.

### 9.3 If you are in California (CCPA/CPRA)

In the twelve months before this policy's effective date, AppleTree has not sold or shared personal information for cross-context behavioural advertising, and has not used or disclosed sensitive personal information for any purpose other than providing the service. You have the right to know what personal information is collected, to access, correct and delete it, to opt out of any sale or sharing, to limit use of sensitive personal information, and not to be discriminated against for exercising these rights.

Because AppleTree stores everything locally and holds nothing centrally, the information described in §4 is already available to you on your own Mac, and §8 explains how to delete it. We have no personal information to disclose to anyone else.

To make a request, contact **privacy@appletree.apps.erklab.com**. We will not discriminate against you for asking.

---

## 10. Children

AppleTree is a general-purpose utility and is not directed at children. We do not knowingly collect personal information from children under 13, or under the equivalent age in your jurisdiction. Because AppleTree has no accounts and transmits data only when the operator explicitly runs an AI cleanup, there is no mechanism by which a child's information would be collected by us. If you believe a child has sent us personal information, contact us at the address above and we will delete it.

---

## 11. Security

- **API keys** are stored only in the macOS Keychain, never in preference files, logs or caches, and are never written to disk in plain text by AppleTree.
- **Network requests** use Apple's App Transport Security, so connections to endpoints you configure must be protected by TLS. AppleTree declares `NSAllowsLocalNetworking` and nothing broader: plain HTTP is permitted to local addresses, so a model on your own Mac or LAN works without a certificate, while requests to public hosts remain HTTPS-only. AppleTree does not disable certificate validation.
- **The Codex download** is pinned to a specific release and verified against a SHA-256 checksum compiled into the app before anything is installed.
- **Agent launches** use an empty working folder and, for Codex, a read-only sandbox, so an agent does not load project settings, hooks or memory from your own projects.
- **No remote content is loaded into the interface.** AppleTree's UI is built from your local disk; there is no update feed, no remote-configuration channel and no web view.

No security measure is perfect. If you believe you have found a vulnerability, please report it to **security@appletree.apps.erklab.com** rather than opening a public issue. We aim to acknowledge reports within five working days.

---

## 12. International transfers

AppleTree is distributed through the Mac App Store and runs entirely on your device; we do not operate a server that receives your data.

If you configure an AI provider or run an AI cleanup, the summary in §5.2 is transmitted to the endpoint you chose, which may be outside your country. You choose that destination and the transfer is initiated by your own action. For a provider running on your own Mac or network, no transfer outside your machine occurs.

---

## 13. Changes to this policy

If AppleTree's behaviour changes in a way that affects this policy, the policy will be updated here before or at the same time as the change ships, and the "Last updated" date above will change. Material changes, including any new category of data leaving your Mac, will also be described in the app's release notes. Where a change requires your consent under applicable law, it will be requested before the change takes effect rather than assumed from continued use.

---

## 14. Contact

**Emircan ERKUL**

| | |
|---|---|
| Privacy questions and requests | privacy@appletree.apps.erklab.com |
| Security reports | security@appletree.apps.erklab.com |
| General support | support@appletree.apps.erklab.com |
| Bug reports and features | [Open an issue](https://github.com/emircanerkul/appletree/issues/new/choose) |
