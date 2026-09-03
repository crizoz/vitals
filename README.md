<div align="center">

<img src="docs/icon.png" width="120" alt="Vitals">

# Vitals

**A native macOS menu bar app for your Mac's vitals and your *real* Claude usage limits.**

Built entirely without opening Xcode. No dependencies. ~45 MB of memory, 0% CPU at rest.

<img src="docs/panel.png" width="330" alt="The Vitals panel">

</div>

---

## What it does

The menu bar icon is a ring that fills as you burn your Claude **5-hour session**. Empty ring, fresh session. Full ring, you're done until it resets.

<img src="docs/menubar.png" width="420" alt="The menu bar ring">

Click it and you get:

- **System** — CPU, GPU and memory as arc gauges. The memory arc has a second, neutral segment for cached files: macOS keeps them for speed and releases them the moment anything needs the RAM, so they shouldn't count as "used".
- **Storage** — free space per volume.
- **Claude** — your three real limits: the 5-hour session, the weekly cap, and the weekly cap for the specific model. Each with a **pace mark**.
- **Three actions** — lock the keyboard to clean it, keep the Mac awake, or turn the screen off while your agents keep running.

## Install

Only needs Xcode **Command Line Tools** — `xcode-select --install`. Not Xcode itself.

```sh
git clone https://github.com/crizoz/vitals.git
cd vitals
./build.sh --install
```

That compiles it, signs it, drops it in `/Applications` and launches it. There's a "Open at login" toggle in the gear menu.

No Keychain dialog: Vitals reads the credentials the same way Claude Code writes them, through `/usr/bin/security` — see [Reading a Keychain item you don't own](#reading-a-keychain-item-you-dont-own).

---

## The parts worth stealing

### It reads Claude's real limits, not an estimate

Most Claude usage trackers — [ccusage](https://github.com/ryoppippi/ccusage) and everything built on it — parse the JSONL transcripts in `~/.claude/projects/`. That's clever and offline, but it can only ever give you **tokens and an estimated cost**. It cannot give you the number Anthropic actually enforces.

Vitals asks the source:

```
GET https://api.anthropic.com/api/oauth/usage
Authorization: Bearer <the token Claude Code already keeps in your Keychain>
anthropic-beta: oauth-2025-04-20
```

The response carries a `limits[]` array with `session`, `weekly_all` and `weekly_scoped` — the last one naming the model it applies to. Those are the same percentages `/usage` shows you inside Claude Code.

The token is read from the Keychain, kept in memory only until it expires, and never written anywhere. Claude Code rotates it, so the cached copy is dropped the moment the API answers 401.

### The pace mark

<img src="docs/panel.png" width="300" align="right" alt="Pace marks on the Claude bars">

A percentage alone doesn't tell you whether you're in trouble. 52% of your weekly cap is fine on day six and alarming on day two.

So every Claude bar carries a thin vertical mark at the point of the window that has already elapsed — 5 hours for the session, 7 days for the weekly ones.

**Fill behind the mark, you're comfortable. Fill past it, you're burning faster than the clock.**

<br clear="right">

### It polls almost never

The closest comparable app polls the usage endpoint every 5 to 120 seconds. That endpoint rate-limits hard — we found out by getting 429'd during development — and most of those requests are wasted anyway.

Vitals borrows the idea behind [CCSeva](https://github.com/Iamshankhadeep/ccseva) and takes it further:

- **An FSEvents watcher on `~/.claude/projects`.** If Claude Code hasn't written anything, your usage cannot have changed, so there is nothing to ask. When it does write, we refresh — with a 60-second floor so one long turn doesn't fire twenty requests.
- **A 10-minute fallback timer**, whose only job is catching the moment a window resets on its own.
- **Exponential backoff on 429**, from 60 seconds up to 15 minutes, honoring `retry-after`.
- **The last snapshot is persisted**, so a restart shows real numbers instead of dashes, and the app doesn't fire a request at launch if what it has is under two minutes old.
- **CPU, GPU and memory aren't sampled at all while the panel is closed.** Nothing on screen depends on them — the menu bar shows Claude, not the Mac.

With the panel closed, the whole app is one HTTPS request every few minutes and nothing else.

### Every metric, without a single privilege

| Metric | Source | Needs |
|---|---|---|
| CPU | `host_processor_info`, differential ticks | nothing |
| GPU | IORegistry → `IOAccelerator` → `Device Utilization %` | nothing |
| Memory | `host_statistics64` (app + wired + compressed) | nothing |
| Cached files | `external_page_count` | nothing |
| Storage | `volumeAvailableCapacityForImportantUsage` | nothing |
| Claude limits | OAuth usage endpoint | Keychain |

No `sudo`, no helper tool, no `powermetrics`. GPU utilization in particular is usually claimed to require root — it doesn't, if you read the IORegistry instead.

### No Xcode, and the icon is code

`build.sh` compiles ten Swift files with `swiftc`, assembles the `.app` bundle by hand, and signs it. There is no `.xcodeproj` in this repository and there never was.

The app icon isn't a binary asset either. `Tools/MakeIcon.swift` draws it with CoreGraphics — a real superellipse (the continuous curve Apple uses, not a rounded rectangle), a graphite gradient body, a warm glow behind the ring — and renders the ten iconset sizes. `build.sh` regenerates it whenever the generator changes.

### Signed with a stable identity, on purpose

Ad-hoc signing produces a new signature on every build, and anything bound to the signature — Keychain permissions, TCC grants, the login item — breaks every time you rebuild.

So `build.sh` creates a self-signed code-signing certificate the first time it runs, imports it into your login Keychain, and signs with that. The designated requirement becomes `identifier "cl.makana.vitals" and certificate leaf = H"…"`, which is stable. The private key only exists in your Keychain — the script deletes its temporary files.

### Reading a Keychain item you don't own

`Claude Code-credentials` belongs to Claude Code, which writes it through `/usr/bin/security`. That leaves the item with an ACL that trusts that tool and a **partition list** of `apple-tool:` — the partition covering Apple-signed tools, and nothing else.

Partitions are the part people miss. Clicking **Always Allow** adds your app to the item's trusted-application list, but not to its partition list, and every token rotation rewrites the item and resets the partitions. The result is the dialog coming back every few hours, forever — and it asks for your login password, which is the tell that it is a partition check and not a trusted-app check.

You can watch it happen:

```bash
security find-generic-password -s "Claude Code-credentials" | grep mdat   # rotates
```

So Vitals doesn't fight it. It asks `/usr/bin/security` for the secret, exactly like Claude Code does: the process requesting the item is one the item already authorizes, so no dialog appears. The direct `SecItemCopyMatching` path is still there as a fallback.

### The panel is not an NSPopover

An `NSPopover` has an arrow and its own vibrancy, and it does not look like the Wi-Fi or Battery panels. Those are windows. So this is an `NSPanel` with an `NSVisualEffectView` in `.menu` material, continuous 14 pt corners and a hairline border, positioned under the status item and resized with an animated frame change.

It closes the way a system panel does: click anywhere outside, press Escape, or click the icon again. That needs two mechanisms, not one — a global mouse monitor catches clicks that land in other apps, but the clock, Control Center and the other menu bar extras swallow the click inside their own tracking loop, and a Cmd-Tab isn't a click at all. What all of those *do* have in common is that the panel stops being the key window, so it also closes on losing focus — unless the focus went to one of its own menus, which is how the gear menu stays open.

One consequence worth knowing: the panel deliberately does **not** activate the app, so it never steals focus from what you're typing in. But macOS draws its own controls desaturated when the owning app isn't active, which silently greys out any accent color. That's why the bars here are drawn by hand instead of using `ProgressView`.

### Speaks your language

The app follows the system. macOS picks the `.lproj` that matches your language order — or whatever you pinned for Vitals in **System Settings → General → Language & Region → Applications** — and falls back to English for anything it doesn't have.

Adding a language is one file, no Swift:

```sh
cp -R Resources/en.lproj Resources/pt-BR.lproj
$EDITOR Resources/pt-BR.lproj/Localizable.strings
./build.sh
```

Three things make that safe rather than hopeful:

- **The build fails on a broken table.** `Tools/check_strings.py` reads the keys straight out of `Sources/Localization.swift` and diffs them against every `.strings` file — a missing key, a stale one, or a translation whose format placeholders don't match the English original stops the build instead of shipping a raw `section.storage` into the UI.
- **Numbers are the system's job, not ours.** Percentages go through `NumberFormatter`, sizes through `ByteCountFormatter`. That's why an English-language Mac set to Chile renders `58 %` with a space — exactly like the battery in its own menu bar — and a Spanish one renders `58%`.
- **The cached snapshot stores the kind, not the label.** The last known usage survives on disk between launches; if it had held the word "Session" the panel would have come back in the previous language after you switched. It holds `.session` and translates at draw time.

There's a way to see all of it without clicking anything:

```sh
Vitals.app/Contents/MacOS/Vitals --dump-strings -AppleLanguages "(es)"
```

It prints the localization macOS resolved, every key with its translation, and the phrases that take arguments already assembled — which is where a mis-numbered `%2$@` actually shows up.

### The menu bar icon is a template image

Drawing into the menu bar with a SwiftUI hosting view produces something that looks washed out over a busy wallpaper, because it misses the contrast treatment macOS gives its own icons. Vitals renders the ring into an `NSImage` with `isTemplate = true`, so the system paints it with the menu bar's own color — black on light, white on dark. Relative alpha survives, which is what lets a dim track and a solid fill coexist in one monochrome image. When you cross 80% of your session it drops out of template mode and goes orange, then red — the same trick the battery icon uses.

---

## The three actions

**Keyboard** — blocks the keys for 30 seconds with a full-screen countdown so you can wipe them. The trackpad stays live on purpose, so you're never locked out. With Accessibility permission it installs a `CGEventTap` and catches system shortcuts too; without it, the front window simply swallows what you type.

**Awake** — an `IOPMAssertionCreateWithName` with `PreventUserIdleSystemSleep`. The Mac won't sleep, but the display still can.

**Screen** — the previous one plus `pmset displaysleepnow`. This is the actual use case: you're leaving, you have agents or shells running, you want the screen dark and the work alive.

> Closing a MacBook lid still sleeps it. No assertion available without admin privileges prevents that.

---

## Performance

| | |
|---|---|
| Memory footprint | ~45 MB |
| CPU at rest | 0% |
| Network at rest | 1 request per ~10 min |
| Binary | ~550 KB |
| Dependencies | none |

---

## Caveats, honestly

- **Only English and Spanish ship today.** Any other system language falls back to English. Adding one is a `.strings` file away — see [Speaks your language](#speaks-your-language).
- **The usage endpoint is undocumented.** It's what Claude Code itself calls. It could change.
- **Requires a Claude subscription** signed in through Claude Code. Without it the Claude section stays empty and the rest still works.
- **macOS 14+**, Apple Silicon (`build.sh` targets `arm64`).

## Structure

```
Tools/
  MakeIcon.swift        draws the icon, builds the .icns
  check_strings.py      diffs the .strings tables against the code
Resources/
  en.lproj/             English, the base language
  es.lproj/             Spanish
Sources/
  main.swift            status item, panel window, login item
  VitalsModel.swift      state, cadence, formatting
  SystemMetrics.swift    CPU, GPU, memory, volumes
  ClaudeUsage.swift      Keychain, usage API, backoff
  StatusIcon.swift       the menu bar ring, as a template image
  PanelView.swift        the panel
  Localization.swift     every visible string, one key each
  SleepGuard.swift       power assertion and display sleep
  KeyboardLock.swift     keyboard lock with overlay
  ActivityWatcher.swift  FSEvents on ~/.claude/projects
```

## Prior art

- [ccusage](https://github.com/ryoppippi/ccusage) — the reference for parsing Claude Code's local transcripts
- [CCSeva](https://github.com/Iamshankhadeep/ccseva) — where the refresh-on-file-change idea comes from
- [Claude-Usage-Tracker](https://github.com/hamed-elfayome/Claude-Usage-Tracker) — the closest Swift analog
- [Claude-Code-Usage-Monitor](https://github.com/Maciek-roboblog/Claude-Code-Usage-Monitor) — burn-rate predictions

## License

MIT
