# Changelog — LED OCD macOS app

## 0.9.2 — 2026-07-05

First round of real-hardware testing: a stuck-board bug, a guided Send/Save
workflow, GI Live Mode, and table polish.

- **Fixed: exiting Manual Test (or Live Mode) could leave the board stuck in
  manual mode with all lamps off.** The return-to-normal command was queued
  with a weak reference to the serial session, which the app released
  immediately — when the race lost, the command silently never got sent (the
  board only recovered when some later action sent its own normal-mode
  command). Both cleanup paths now hold the session until the command is on
  the wire.
- **Guided Send/Save workflow (regular mode):** Send turns green whenever the
  app holds changes the board hasn't received; after a successful Send, Save
  turns red until pressed (the board's Save can only persist what it was last
  sent). Dirty tracking compares against a fingerprint of the last
  sent/read state — so a field re-committing an identical value doesn't
  trigger it, and manually reverting an edit turns Send back off.
- **Live Mode: Commit Changes.** Save is renamed Commit Changes in Live Mode
  and does send + save in one press THROUGH the live session — the board never
  leaves manual mode, so you keep tuning; the button glows red while there are
  uncommitted edits. Send is disabled in Live Mode to remove the ambiguity.
- **Connect now auto-reads the board's settings** after detection, so the app
  immediately mirrors the machine and the button colors start truthful.
- **GI page Live Mode reworked to match the LED page:** a string's lamp button
  lights it steadily (no more fade loop); clicking any Normal/Active B box
  shows that brightness on the string with the yellow highlight; editable
  boxes drive the string live as you type.
- **Lamp table renames:** "Profile" → "Profile Name", "Select" → "Profile",
  "Live" → "Brightness". Fixed a long-standing header misalignment visible
  with "always show scroll bars": the scroller steals ~16pt from the rows but
  not the pinned header — the header now insets to match.
- Per-lamp Profile/Brightness dropdowns slimmed: narrower, and the chunky
  system double-arrow replaced with a light-weight chevron.
- **Return/Enter now commits and unfocuses a text field**, and clicking
  anywhere outside a field drops focus — implemented as pass-through AppKit
  event monitors, NOT a window-wide SwiftUI gesture (which is what froze all
  buttons in 0.9.0's bug).
- Manual and README updated for all of the above.

## 0.9.1 — 2026-07-05

Made the repo public-ready: no personal credentials or contact info anywhere.

- `build.sh` no longer hardcodes the signing identity. It auto-detects a
  "Developer ID Application" certificate in the building Mac's keychain (the
  maintainer's machine signs properly with zero configuration) and falls back
  to ad-hoc signing so anyone can build and run locally without an Apple
  Developer account. Override with `LEDOCD_SIGN_ID`.
- `notarize.sh` no longer contains an Apple ID or team ID. It uses a
  `notarytool` keychain profile ("LEDOCD", one-time `store-credentials` setup)
  and falls back to `AC_APPLE_ID`/`AC_PASSWORD`/`AC_TEAM` env vars; with
  neither present it prints the setup instructions.
- README notarize/build sections rewritten accordingly (placeholder email).
- Project pushed to GitHub (private for now): `.gitignore` excludes build
  artifacts, `dist/`, and the retired original sources in `delete me/`.

## 0.9.0 — 2026-07-05

Menus, custom-game management, tooltips, Live Mode polish, and one serious bug hunt.

- **Fixed: every button in the app went dead after the first state change**
  (clicking a pill or toggling Simulate froze all SwiftUI buttons while native
  dropdowns/text fields kept working). Root cause: the menu-bar pruning ran
  synchronously inside SwiftUI's own render pass whenever it rebuilt the menu
  bar, corrupting event handling. Removed the whole "hide native menus" fight —
  the app now keeps the standard File/Edit/View/Window/Help menus.
- **Help menu** now carries "LED OCD Help…" (a full in-app manual window,
  `Help.swift` — user-facing walkthrough of every feature: connecting, games,
  profiles, Live Mode vs Manual Test, saving, GI, custom games) and
  "LED OCD website". The manual was rewritten twice for plain language and kept
  in sync with UI changes.
- **Custom games are now first-class**: they save to their own folder
  (`~/Library/Application Support/LED OCD/custom/`) so Refresh Machine Data can
  never overwrite them, and can even share a name with a default game. The Game
  Select dropdown groups into "Custom Games" / "Default Games" (section headers
  in the native popup). With a custom game selected: pencil icon = rename,
  trashcan = delete (with confirmation).
- **Hover-hint area** under the Manual Test button: every clickable control in
  the app (header pickers, Connect/Scan, pills, game select + its icons, action
  buttons, Advanced boxes, sort headers, per-lamp Select/Live chevrons, profile
  lamps, GI controls) shows a plain-language description there on hover. Fixed
  size so the layout never shifts; sized per page so it can't clip on GI.
- **Live Mode**: with a profile's 💡 on, editing its brightness values drives
  the real lamps instantly — dial in the look, then just Save (no send-check
  loops, no remembering levels). Clicking any B1–B8 box highlights it yellow
  and shows that step on the lamps (fixed a one-render-behind highlight bug by
  reading focus state directly). Profile 💡s grey out properly when unusable
  (Live Mode off, or no lamps assigned). Removed the red "LIVE" overlay text.
- **Matrix pills**: fully manual clicking restored (see bug above); Connect/
  Read auto-light the detected matrix green again; Simulate no longer guesses.
- **Simulate Board** moved from a header button to the Advanced menu; a red
  "SIMULATED" label sits right-aligned in the header while active.
- **Matrix override** returned as Advanced ▸ Show Matrix Override (hidden by
  default) after removing the always-visible Matrix dropdown.
- `build.sh` no longer kills Finder/Dock on every build (the icon-cache refresh
  step is gone).
- **Repo restructured**: everything moved from `mac/` to the repo root; machine
  CSVs now live in `data/` (bundled from there); original C CLIs, web GUI, and
  old README parked in `delete me/`. README rewritten user-first with proper
  credit to Harold Toler for the boards, firmware, protocol, and original
  software.

_Spent half the day hunting a bug that killed every button after one click.
The murderer was our own code, hiding menus nobody had asked to see twice._

## 0.8.x — 2026-07-04

App identity, macOS 12 support, Live Mode, game editing, and layout precision.

- **About panel**: native layout, copyright under the version, credits
  "Entirely built on the foundation of Harold Toler's LED & GI OCD."
- **App icon**: pinball artwork via a compiled asset catalog (the only way
  Finder reliably renders it), reshaped to the macOS squircle template by
  `makeicon.swift` at build time.
- **macOS 12 support**: deployment target lowered 13 → 12 so the Intel build
  runs on 12.6; version-gated SF Symbols; fixed a macOS 12 bug where header
  dropdowns went 100% width.
- **`ChevronPicker` rewritten around `NSPopUpButton`** — SwiftUI `Menu` ignores
  explicit widths, so equal-width dropdowns (COM Select / Board, both 230)
  required the AppKit control. Also fixed the log window not auto-scrolling.
- **Live Mode** (replaces the old fade-preview buttons): one persistent
  manual-mode serial session; a Live column with per-lamp 0–8 brightness
  chevrons; per-profile 💡 lights every lamp on that profile with click-to-set
  B levels. Any Send/Read/Save drops Live Mode first and returns the board to
  normal.
- **Fixed serial close truncating final commands** (`tcdrain` before close) —
  exiting Manual Test now reliably returns the board to demo mode.
- **Manual Test**: 3-column grid sorted column-major, everything off on open,
  a Profiles row driving all lamps per profile, and return-to-normal on any
  exit path.
- **Manufacturer filter pills** above Game Select (WPC / Stern / Capcom with
  A/B sub-pills): filter the game list; green = board's detected matrix,
  amber = manually enabled, red = selected game conflicts with the board.
- **Add Game**: New (blank template per matrix) / Clone inline editor — name
  field, matrix picker, editable Insert column in the lamp table; saves as a
  user CSV. Lamp table keeps identical columns/sizing while editing.
- **Sortable lamp table** (Lamp / Insert / Select headers, click to reverse);
  Game Select placeholder "- Select game -"; last game remembered across
  launches; Read now also captures the matrix from the firmware frame.
- Advanced-menu cleanup: Checkerboard and "Show Extra Controls" removed; GI
  Out freq moved beside 50 Hz (small 1-digit dropdown); many pixel-precision
  alignment fixes (Advanced checkbox aligned to the Delay column edge, equal
  action-button widths, fixed game-row height).

## 0.8.0 — 2026-07-04

- Added LED Import/Export (Advanced menu, ⌘⇧I / ⌘⇧E) in the Windows app's
  `<settings>` XML format — `ConfigIO.swift`. Export is byte-identical to the
  Windows app (UTF-8 BOM, CRLF, no trailing newline); verified round-trip against
  a real Windows export. Import loads profiles/lamp-map/advanced and auto-selects
  the machine by `<title>`. Moved the LED `advanced` flag into `LEDConfig` so it's
  part of the exported/imported state. GI import/export pending a sample file.

## 0.7.x — 2026-07-04

- Modes (Manual Test / Passthrough / Checkerboard) are now green toggles; press
  again returns to Normal. Active mode shown in red at top-right. Removed the
  standalone Normal button.
- Action buttons moved from the bottom bar into the 2nd column (below the
  content) on both pages; equal-width via label-frame. Passthrough, Checkerboard,
  and Log moved to the Advanced menu.
- Refresh Machine Data made incremental (manifest of per-file dates; only
  downloads changed files).

## 0.7.0 — 2026-07-03

- Refresh Machine Data is now incremental. `DataSync` parses each file's
  last-modified date from the Apache listing, caches it in a `sync-manifest.json`,
  and only downloads new/changed games. A refresh with nothing new does one
  listing fetch and zero file downloads ("already up to date").

## 0.6.x — 2026-07-03

- Moved Refresh Machine Data into the Advanced menu-bar menu (⌘⇧R); removed the
  header button/status. Menu-bar action bridged to the Controller via a
  notification.
- Removed the File and Edit menus from the menu bar.
- Header cleanup: title moved to the window title bar ("LED/GI OCD Configuration
  vX.Y.Z"); "Port" → "COM Select"; buttons reordered/renamed to Connect · Scan;
  action-bar "Read from Board" → "Read".
- Esc and click-on-empty-space now drop text-field focus; no field auto-focuses
  on launch.

## 0.6.0 — 2026-07-03

- Added an "Advanced" menu-bar menu with "Show Extra Controls" (persisted via
  @AppStorage). When off (default), the Matrix override dropdown and the GI
  Output frequency are hidden — matching what the original Windows app exposes.
  Matrix still auto-sets from the selected game while hidden.

## 0.5.0 — 2026-07-03

Reworked the GI OCD editor to match the LED profiles table layout.

- Strings are now a table with Min/Brightness/Max headers over B1–B8 and `NumBox`
  fields, instead of stacked slider blocks. Each string is two rows (Normal /
  Active); the top row carries the string label, the "Controlled by" dropdown,
  and the Activity toggle.
- Added the same Advanced checkbox + B2–B7 auto-calc (same truncated-linear rule
  as LED). GI factory defaults are hand-authored curves, so they're preserved on
  load and only re-derived when you edit an endpoint.
- Globals (fade min/max, activity duration, 50 Hz, output freq) condensed into a
  top row; big 0–250 steppers replaced with typed NumBox fields.

## 0.4.7 — 2026-07-03

- Selecting a game now auto-sets the Matrix from the game's CSV (authoritative,
  incl. Capcom A/B). Fixes wrong lamp col/row mapping when matrix didn't match
  the chosen game. Game-list filtering intentionally left out pending decision.

## 0.4.3 — 2026-07-03

Implemented the Advanced / auto-calculated brightness behavior from the usage docs.

- Added an **Advanced** checkbox. When off (default), B2–B7 are auto-derived from
  B1 and B8 via `Bn = B1 + (B8-B1)*(n-1)/7` (integer division — verified to
  reproduce the linear default profiles exactly) and shown locked/dimmed; editing
  B1 or B8 re-derives them. When on, all eight are editable.
- Custom defaults (LED 85%, Incandes) are preserved on load — only re-derived if
  you edit an endpoint, matching the tool's "set B1/B8 and the middle fills in"
  behavior.
- Confirmed the profile name edits update the left lamp grid's Profile column live.

## 0.4.2 — 2026-07-03

- Darkened the app background slightly and gave the lamp table a solid card
  background so sections stand out.

## 0.4.1 — 2026-07-03

- Fixed large vertical gaps in the profiles table: `Color.clear` layout spacers
  were stretching vertically; pinned to `height: 0`.
- Lamp table (and its Insert column) now flexes with window width instead of a
  fixed block; outer layout fills width and left-aligns.
- Window minimum widened ~15% (940 → 1080).

## 0.4.0 — 2026-07-03

Redesigned the LED OCD page to match the original Windows app layout.

- Two-column layout: left = lamp table (Lamp / Insert / Profile / Select, the
  Profile column showing the assigned profile's name); right = profiles table
  (row #, Profile Name, B1–B8 under Min/Brightness/Max headers, Delay).
- New plain `NumBox` numeric field (no stepper, no chevron) for brightness and
  delay, matching the reference's typed fields.
- Game Select dropdown moved above the profiles table.
- Widened window minimum (940×600) to fit both columns.

## 0.3.7 — 2026-07-03

- Replaced the ▲▼ Stepper in `IntField` (profile delay, GI fade/activity) with a
  single-chevron dropdown — that stepper was the "double arrow" being reported.

## 0.3.6 — 2026-07-03

- Reverted the bordered custom-chevron box; `ChevronPicker` is now a plain
  pull-down `Menu`.

## 0.3.5 — 2026-07-03

- Fixed `ChevronPicker` actually showing a single chevron. The previous
  `.menuStyle(.button)` still rendered the macOS pop-up double up/down arrows.
  Now hides the system menu indicator (`.menuIndicator(.hidden)`) and draws a
  single `chevron.down` inside a control-styled bordered box. All dropdowns
  (header, LED, GI) now show one downward arrow.

## 0.3.4 — 2026-07-03

- Converted the remaining header dropdowns (Port, Board, Matrix) to
  `ChevronPicker`. Every dropdown in the app now uses the single-chevron
  pull-down style; no default double-arrow pickers remain.

## 0.3.3 — 2026-07-03

- Applied the single-chevron `ChevronPicker` to the LED page too: the machine
  picker and every lamp→profile dropdown now match the GI page's pull-down style.
  `ChevronPicker` gained an optional fixed `width` (used for the wide machine
  names) while other dropdowns keep sizing to content.

## 0.3.2 — 2026-07-03

GI page dropdown styling.

- Removed the small "input" caption before each string's input dropdown.
- New `ChevronPicker` component (a `Menu` with `.button` style) renders dropdowns
  as pull-downs with a single downward chevron instead of the default `Picker`'s
  double up/down arrows. Applied to the GI input pickers and the output-frequency
  picker.

## 0.3.1 — 2026-07-03

Refinements after reading the GI strings explanation on ledocd.com more closely,
plus a build-identification aid.

- **String 6 = "Mod Control"**: the GI OCD has 5 GI strings (1–5) plus a 6th
  channel for an optional external mod (per the usage page and confirmed in
  giocd.awk, which prints "Mod Control" for string 6). The GI editor and Manual
  Test panel now label it "Mod Control" instead of "String 6".
- Verified against giocd.awk that all **8 brightness levels per string are
  editable** (the page generates 8 range sliders for normal and 8 for active) —
  so the existing 8-level GI editor is correct; no change needed there.
- **Version badge** in the window header (e.g. "v0.3.1"), reading
  CFBundleShortVersionString, so it's obvious which build is running. (A stale
  in-memory instance of an older build was the reason earlier changes "weren't
  showing" — a running app keeps its launched binary; rebuilding on disk and
  re-`open`ing just re-activates the old process. Quit fully and relaunch.)

## 0.3.0 — 2026-07-03

Cross-checked against the official usage docs (usage_led.html / usage_gi.html)
and aligned the UI. The protocol and value ranges already matched (they were
derived from the firmware source); these are terminology/UX changes.

- **Interactive Manual Test panel** (`ManualTest.swift`): a sheet that holds one
  serial connection open (on its own queue) for fluid live testing. Set any
  lamp (LED) or string (GI) to hardware level 0–8 and it lights immediately via
  `SETLB` / `SETTB`; "Reset (All Off)", "Checkerboard" (reuses the open port),
  and exit via "Return to Normal" or "Keep Lit & Close". Replaces the old
  fire-and-forget "Manual" button.
- **GI input labels**: the string-input picker now reads "Input 1"…"Input 5"
  and "Always On" (value 6), matching the docs instead of raw numbers.
- **"Apply" → "Send"** to match the official wording.
- Kept 6 GI strings (firmware/original tool use 6; docs describe 5) per user
  choice — to be confirmed against hardware.
- Confirmed the factory defaults already reflect the docs' tuning advice
  (incandescent profile capped at 84% for anti-ghosting; GI fade min = 3).

## 0.2.0 — 2026-07-03

Added in-app machine-data refresh so the picker can stay current with
ledocd.com without rebuilding the app.

- **`DataSync.swift`**: fetches the ledocd.com data listing, downloads every CSV
  (with the browser User-Agent / Accept headers the server requires — it 406s
  otherwise), validates each as a real lamp map, and installs them atomically
  into `~/Library/Application Support/LED OCD/data`. A partial download (< half
  the listing) is rejected rather than clobbering good local data.
- **`Presets.swift`**: now merges bundled data with the refreshed user data,
  keyed by filename — downloaded files win, bundled-only files (the `-Undefined`
  templates) are preserved. Added `hasUserData`.
- **UI**: "Refresh Machine Data" button in the header with live progress and a
  status line ("bundled" vs "refreshed copy"); reloading preserves the current
  machine selection by name.
- Verified end-to-end against the live site: 100/100 downloaded, merged to 104
  picker entries, selection preserved.

## 0.1.1 — 2026-07-03

Synced the bundled machine data with the official ledocd.com dataset.

- Re-downloaded all 100 machine CSVs from https://ledocd.com/software/ledocd_data/;
  the local bundle had only 82 (an older snapshot). Added 20 machines (Avengers
  Pro, Corvette, Diner, Dirty Harry, Elvis, Fire, Jokerz!, Laser War, Monopoly,
  NBA Fastbreak, Pinbot, Playboy 35th, Popeye, Robo Cop, Roller Coaster Tycoon,
  Space Jam, Starship Troopers, Terminator 3, Transformers Pro, Walking Dead Pro).
- **Fixed corrupt data:** the old `Swords of Fury.csv` actually contained Cirqus
  Voltaire's lamp map; `Cirqus Voltaire.csv` was also revised. Both replaced with
  the site's corrected versions.
- Kept the two `-Undefined` blank templates (not on the site). Bundle is now 102
  CSVs → 104 dropdown entries incl. the built-in Generic WPC/Stern maps.
- Rebuilt the signed universal app + DMG.

## 0.1.0 — 2026-07-03

Initial native macOS port of the LED OCD / GI OCD configuration tool. Replaces
the original Linux + Apache + CGI + awk stack with a single self-contained
SwiftUI app that drives the board directly over serial.

- **Serial layer** (`SerialPort.swift`): POSIX `termios` port configuration
  (9600 8N1, raw, no flow control) transcribed from the C CLIs, using
  `/dev/cu.usbserial-*` on macOS. No third-party dependencies. Writes each
  framed message once rather than replicating the original C byte-sliding loop
  (which was undefined behavior).
- **Protocol** (`OCDDevice.swift`): every LED OCD and GI OCD command ported
  message-for-message — version query, board/matrix auto-detection, profiles
  (name/delay/brightness), lamp→profile assignment, GI strings (input/activity/
  normal+active brightness), fade delay, activity duration, 50 Hz, output
  frequency, mode switches, checkerboard, and `<Q>` read-settings frame parsing.
  Preserves the firmware's `62 → 63` payload guard and the Capcom-B `<1>` relay
  prefix.
- **Models** (`Models.swift`): `LEDConfig` / `GIConfig` seeded with the exact
  factory defaults from `ledocd.awk` / `giocd.awk`, plus read-settings parsers.
- **Machine presets** (`Presets.swift`): bundles all 82 machine CSVs and parses
  them with the original awk rules (numeric-first-field = lamp; lamp number < 11
  ⇒ Stern; `CAPCOM_A/B` markers ⇒ Capcom matrix). Adds generic WPC/Stern maps.
- **UI**: port picker + connect, board/matrix override, machine picker, profile
  and 88-lamp editors, GI string + globals editor, action bar (Read/Apply/Save/
  Normal/Manual/Passthrough/Checkerboard), and a live log.
- **Packaging**: `build.sh` produces a universal (arm64 + x86_64) binary signed
  with Developer ID + hardened runtime; `makedmg.sh` builds a DMG; `notarize.sh`
  submits/staples for distribution.
- **Verification**: pure logic (CSV parsing, matrix math, all frame parsers,
  frame splitting) checked against expected values via a self-test harness — all
  pass. Real serial comms against hardware still to be confirmed (cable pending).

_Wrote ~1000 lines of Swift to talk to a pinball board I've never seen, then
tested it against a board I can't plug in. Tomorrow the cable arrives and we
find out how brave that was._
