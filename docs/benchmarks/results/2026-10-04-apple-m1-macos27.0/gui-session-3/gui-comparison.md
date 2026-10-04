# GUI-mode comparison

**Target** `/Applications` · **rounds** 5 per app, interleaved

Every app was given the same target and the same number of rounds. Launching the bundle through `open` makes launchd — not the terminal — the TCC-responsible process, so each app's own Full Disk Access grant applies.

**These rows are not all the same interval.** The source column says where each duration comes from; compare `app-reported` rows with each other, and treat the external row as an upper bound rather than an equal measurement.

**Memory** is the peak resident set size. For AppleTree it is the kernel's own high-water mark reported by the app itself. For the other apps it is sampled from outside every 50 ms while the scan runs, so it is a floor on the true peak and can miss a spike between samples. It covers each app's whole process, UI included — which is why it is far larger than the engine-tier figures, where RSS is measured in a process that never loads the UI.

| app | measure | peak memory | source | rounds | note |
|---|---:|---:|---|---:|---|
| AppleTree | **0.785 s** | **138.5 MB** | app-reported | 5 | min 0.735 s, max 0.852 s — app-written finish time |
| disktree | **2.748 s** | **156.6 MB** | external wall-clock | 5 | min 2.286 s, max 5.426 s — app prints no timing; timed until CPU idle, so not comparable to app-reported rows |
| GrandPerspective | **5.820 s** | **160.2 MB** | app-reported | 5 | min 5.230 s, max 7.030 s — app-written finish time |
| QDirStat | **5.951 s** | **214.2 MB** | app-reported | 5 | min 5.744 s, max 8.209 s — app-written finish time |
