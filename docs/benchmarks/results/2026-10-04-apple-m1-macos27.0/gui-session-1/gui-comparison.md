# GUI-mode comparison

**Target** `/Applications` · **rounds** 5 per app, interleaved

Every app was given the same target and the same number of rounds. Launching the bundle through `open` makes launchd — not the terminal — the TCC-responsible process, so each app's own Full Disk Access grant applies.

**These rows are not all the same interval.** The source column says where each duration comes from; compare `app-reported` rows with each other, and treat the external row as an upper bound rather than an equal measurement.

**Memory** is the peak resident set size. For AppleTree it is the kernel's own high-water mark reported by the app itself. For the other apps it is sampled from outside every 50 ms while the scan runs, so it is a floor on the true peak and can miss a spike between samples. It covers each app's whole process, UI included — which is why it is far larger than the engine-tier figures, where RSS is measured in a process that never loads the UI.

| app | measure | peak memory | source | rounds | note |
|---|---:|---:|---|---:|---|
| AppleTree | **0.852 s** | **138.2 MB** | app-reported | 5 | min 0.585 s, max 1.352 s — app-written finish time |
| disktree | **4.399 s** | **153.0 MB** | external wall-clock | 5 | min 2.309 s, max 5.122 s — app prints no timing; timed until CPU idle, so not comparable to app-reported rows |
| GrandPerspective | **5.210 s** | **154.7 MB** | app-reported | 5 | min 5.040 s, max 5.900 s — app-written finish time |
| QDirStat | **6.066 s** | **199.4 MB** | app-reported | 5 | min 5.190 s, max 7.387 s — app-written finish time |
