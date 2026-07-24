# AirPlay 2 Output — Testing & Follow-up Handoff

**Read this first. It drives two work streams: (A) the manual hardware test
matrix, (B) the follow-up fixes. Do not redo completed work.**

## Prompt for the new session

You are resuming work on branch `airplay-2-output` in `/Users/kmalinowski/dev/Cog`
(Cog, a native macOS audio player; Obj-C/Swift; no unit-test suite — the build is
the verification gate). The feature is code-complete, reviewed, and pushed to
`origin/airplay-2-output` (HEAD `fbe719225` + this handoff commit). All 7 plan
tasks, a final whole-branch review, and two fix passes are done — see the ledger.
Remaining work: the human runs the test matrix (Part A) while you fix the
follow-up minors (Part B), starting with the AVRouteDetector power issue.

Key documents:

- Spec: `docs/superpowers/specs/2026-07-22-airplay-2-output-design.md`
- Plan: `docs/superpowers/plans/2026-07-22-airplay-2-output.md`
- Progress ledger (full review history + all deferred minors): `.superpowers/sdd/progress.md`
- Review/fix reports: `.superpowers/sdd/` (gitignored, local only)

User rules that bind this repo: **no Claude/co-author signature lines in git
commits**; real tabs for indentation in Obj-C; never commit the untracked
`CLAUDE.md` or `graphify-out/`; never commit a `DEVELOPMENT_TEAM` (pre-commit
hook enforces; Xcode sometimes injects one into `project.pbxproj` — revert it).

Build gate for every fix:

```sh
xcodebuild -project Cog.xcodeproj -scheme Cog -configuration Debug -arch arm64 -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
```

Final gate before merge/PR: the CI-equivalent universal build
(add `-arch x86_64 -arch arm64 ... ONLY_ACTIVE_ARCH=NO`).

## Part A: Manual test matrix (human + AirPlay hardware)

Setup: build Debug, launch `build/Build/Products/Debug/Cog.app`. Watch logs in a
terminal: `log stream --predicate 'process == "Cog"' --level debug`. The backend
choice logs as `Output backend for current device: OutputAirPlay|OutputCoreAudio`.

Record each row's result inline below (✅ / ❌ + notes). On any failure: capture
the log around it, note the exact row, and hand it to the session — it should use
`superpowers:systematic-debugging` before proposing fixes.

| # | Test | Steps | Expected |
|---|------|-------|----------|
| A1 | Wired regression | Play/pause/seek on built-in output; a gapless album (e.g. live recording) | Feel identical to pre-branch; no gaps between tracks |
| A2 | DoP DAC regression (if DAC available) | Play DSD to the DoP DAC | Unchanged DoP playback |
| A3 | AirPlay basic | Toolbar → pick HomePod/AirPlay speaker; play FLAC 44.1k, then 96k | Audio on speaker after ~1–2 s; position slider advances honestly |
| A4 | DSD→PCM on AirPlay | Play a DSD64 track to AirPlay | Plays as decimated PCM (352.8k source → PCM), no DoP attempt, no failure |
| A5 | Pause/resume/seek on AirPlay | Pause, resume, seek mid-track | Prompt pause; resume without dropped audio at start; seek lands within ~a beat |
| A6 | Track transitions on AirPlay | Let an album play across ≥2 track boundaries | Continuous playback; gapless where same format (format-change gap is a known v1 deferral) |
| A7 | Route switch: toolbar | Mid-play: toolbar menu → built-in; then back to AirPlay | Restart at position on right backend each way (check log line) |
| A8 | Route switch: Preferences | Same via Preferences → Output | Same |
| A9 | Route switch: Control Center | Set Cog to "System Default Device"; change default output in Control Center to AirPlay and back | Same — buffered path engages via default-device resolution |
| A10 | Route loss | Power off the speaker mid-stream | Playback falls back to default device and continues; renderer failure in log (log-only feedback is by design) |
| A11 | **Failure with AirPlay default** (new, targets the hardened path) | Cog on "System Default Device", system default = AirPlay speaker; kill the speaker mid-play | In-place renderer rebuild recovers playback (log shows rebuild); no permanent silence |
| A12 | **Early unpause** (new, targets prebuffer gating) | Start playback to AirPlay paused (or pause within ~1 s of start), then unpause immediately | No dropped/garbled first seconds; playback starts when prebuffer fills |
| A13 | Multi-room | While Cog plays to speaker 1, group it with speaker 2 in Control Center | Both play; Cog unaffected |
| A14 | Toolbar button visual | All three windows (main, mini, mini plus): button present (next to shuffle/repeat, before Spectrum), menu shows Local/AirPlay sections with checkmark, icon tints with accent while on AirPlay | As described (this was never visually verified — session lacked screen permissions) |
| A15 | Stress: rapid switching | Click through several devices quickly in the toolbar menu | Serialized restarts, ends on last selection, no hang/crash |
| A16 | **Route-detector fallback** (new, after B1) | With AirPlay routes on the network but none materialized as a CoreAudio device, open the toolbar menu; close it and reopen within ~5 s | "Open Sound Settings…" item appears, at least on the second open (detection now runs only while the menu is open plus a short grace window) |
| A17 | **Bonjour pick: toolbar** (new) | With a sink on the network but not in Sound settings' active output, open the toolbar menu | Device listed by name; picking it opens Sound settings and shows a – marker on reopen; activating the device in Settings makes Cog switch to it automatically (log shows the device change) — **Result 2026-07-24: ❌ then ✅.** Name-based match could never fire (macOS materializes ONE generic device named "AirPlay", transport airp). Fixed by transport-based matching (015a2397a); verified live: pick room → activate in Settings → auto-switch onto the bridge, playback continuous (discard wedge separately fixed, 795d8cd50). Note: post-switch the checkmark lands on the "AirPlay" bridge device, not the room name — inherent to the one-bridge model. |
| A18 | **Bonjour pick: Preferences** (new) | Same flow via Preferences → Output; also repeat leaving Preferences → Output open while activating the sink in Sound settings | Same, including snap-back of the picker until the device materializes; with the pane open, the picker must land on the new device (not System Default) once it materializes — **Result 2026-07-24: mechanism fixed (shared with A17, 015a2397a) but this row's Preferences flows (incl. pane-open pass) not yet re-run on the fixed build ≥9de0bb28c.** |
| A19 | **Local-network permission** (new) | First menu open on macOS 15+ | Permission prompt appears once; denying it leaves the menu working with the pre-Bonjour fallback behavior |

Known v1 deferrals — expected behavior, do NOT report as bugs: route-loss
feedback is log-only; gapless across sample-rate changes on AirPlay may gap;
visualization leads audible audio by the buffer depth; spatial audio untouched.

## Part B: Follow-up fixes (agent work, can start before test results arrive)

Work on `airplay-2-output`. One commit per numbered item (or batch B3–B5 as one
hygiene commit). Build gate after each. Use focused subagents if convenient; the
diffs are small enough to do directly. Re-run any affected matrix rows after.

### B1 — AVRouteDetector power cost (do first; user flagged as important)

`Window/AirPlayItem.m` (~57–58): `awakeFromNib` creates an `AVRouteDetector`
with `routeDetectionEnabled = YES` for the app's lifetime — ×3 toolbar items.
Apple documents active route detection as significantly increasing power
consumption and advises enabling it only while picker UI is visible. Only
consumer is the `multipleRoutesDetected` read in `showDeviceMenu:` (the
"Open Sound Settings…" fallback).

Fix shape:
- Share ONE detector across the three items (e.g. a class-level/static instance)
  instead of three.
- Enable detection only around menu display: set `routeDetectionEnabled = YES`
  in `showDeviceMenu:` before building the menu; disable when the menu closes
  (NSMenuDelegate `menuDidClose:`, or a short `dispatch_after`).
- **Caveat to verify on hardware (add to matrix as A16):** a freshly-enabled
  detector may briefly report `multipleRoutesDetected == NO` before detection
  completes, so the fallback item could be missed on first open. Acceptable
  mitigations: keep detection on for a few seconds after menu close so a
  re-open is accurate; or KVO `multipleRoutesDetected` and, while the menu is
  open, insert the fallback item live when it flips. Pick the simplest thing
  that passes A16 (open menu with no materialized AirPlay device but routes
  present → fallback item appears, at least on second open).
- `dealloc` must still disable detection if enabled.

### B2 — Resume-vs-rebuild hardening (cheap, concurrency)

`Audio/Output/OutputAirPlay.m`: a user `resume` racing an in-place renderer
rebuild can read stale `prebufferReached`, set rate on the dead synchronizer,
and leave `started == YES` gating off the feeder auto-start → new synchronizer
stuck at rate 0 until the user pauses/unpauses (microsecond window). Reviewer's
suggested fix: in the feeder loop, also fire the auto-start when
`prebufferReached && !paused && started && [renderSynchronizer rate] == 0`
right after a rebuild (or re-verify synchronizer identity in `resume`).

### B3 — Dead state cleanup (batch)

`Audio/Output/OutputAirPlay.m`: delete the never-read `faded` flag, `lastPts`
(assigned, never read), and the unused `streamTimestamp` ivar (zeroed once;
line ~422 uses the chunk's own property, not the ivar).

### B4 — doStop/setup polish (batch with B3)

`Audio/Output/OutputAirPlay.m`: (a) move the `stopInvoked` fast-path check to
the first statement *inside* the `@synchronized` Phase 1 block; (b) hoist the
redundant `stopping = YES` out of the Phase-2 join loop; (c) add a comment on
`setup` forbidding re-setup of a stopped instance (unsafe in the Phase-2
window; currently unreachable — `OutputNode` always allocates a fresh backend).

### B5 — Device-name lookup dedup (batch with B3)

`Audio/Output/OutputAirPlay.m` `setOutputDeviceWithDeviceDict:` reimplements
the enumeration that exists as static `deviceIDMatchingName()` in
`Audio/Output/OutputDeviceRouting.m`. Export it from `OutputDeviceRouting.h`
and call it. (Leave `OutputCoreAudio`'s pre-branch copy alone.)

### B6 — Preferences "Local" header (2 lines, spec parity)

`Preferences/Panes/OutputPaneView.swift`: wrap the non-AirPlay `ForEach` in
`Section(header: Text("Local"))` to match the toolbar menu's grouping ("Local"
is already in the string catalog). Optional per final review — do it, it's
cheap and closes the spec-text gap.

### B7 — Toolbar checkmark name-fallback (cosmetic, lowest priority)

`Window/AirPlayItem.m` `showDeviceMenu:` checkmark matches by `deviceID` only,
while the tint state (`CogOutputDeviceDictIsAirPlay`) has a name fallback for
stale IDs — mirror that fallback for the checkmark, or skip if not worth it.

### Not worth fixing (adjudicated ship-as-is — leave alone)

`kAudioObjectPropertyElementMaster` deprecations (codebase idiom); AirPlayItem
files sitting in the Visualization pbxproj group; `{name:"", deviceID:-1}` vs
Preferences' System Default dict (all consumers short-circuit on -1);
unguarded `prebufferReached` reset in `doStop` (shutdown window only);
`buildRenderer` alloc-failure silent path (practically unreachable — at most
add a DLog); KVO-removal fragility in `AudioPlayer.dealloc`; no coalescing of
rapid device switches (serializes safely, verified by A15).

## After both parts are green

Update the ledger, append test results here, commit (no signature lines), push.
Then use `superpowers:finishing-a-development-branch` — the user deferred the
merge/PR decision until testing is done.
