# AirPlay matrix resume handoff — written 2026-07-24 late, for the next session

**Read this first when resuming. This supersedes the two earlier 2026-07-24
handoffs for session-planning purposes: the debug-session handoff is RESOLVED
(all four findings closed; see its header addendum), and the full-testing
handoff (`2026-07-24-airplay-full-testing-handoff.md`) remains the reference
for matrix row definitions, hardware setup, and build/run/log commands. This
file tells you what to run next and what changed under the rows.**

## Prompt for the new session

You are resuming manual matrix testing on branch `airplay-2-output` in
`/Users/kmalinowski/dev/Cog` (Cog, native macOS audio player; Obj-C/Swift; no
unit tests — build is the gate). The human drives hardware steps; you watch
logs and fix failures using `superpowers:systematic-debugging` (one commit
per fix, build gate, re-run affected rows). User rules: no Claude/co-author
signature lines in commits; tabs in Obj-C; never commit CLAUDE.md,
graphify-out/, or a DEVELOPMENT_TEAM. `.superpowers/sdd/progress.md` is
gitignored local state — update it, don't commit it.

State: HEAD `bcf9d6b5e`, pushed to origin. All code fixes below are in build
`build/Build/Products/Debug/Cog.app` (rebuild if in doubt). Sinks: Bedroom,
Utility Room, Living Room (`_airplay._tcp`). Machine: MacBook Pro; speakers
"MacBook Pro Speakers" (`bltn`; deviceID was 73 on 2026-07-24, may change
per boot).

## Session tooling gotchas (carried over + new; cost real time)

- zsh has a `log` builtin/shim — **always `/usr/bin/log`**. `--level debug`
  is `log stream` only; for `log show` use `--info --debug`.
- Cog-authored DLog lines match `grep -E "\(line [0-9]+\)"`; **filter the
  FileTree noise**: `grep -viE "FileTreeDataSource|nodeForPath|pathDidChange|PrintStreamDesc"`.
- After relaunches, **filter by PID** (`awk '$6 == <pid>'`) — old wedged
  instances pollute the window. `pgrep -x Cog` for the live one.
- Landmark lines now include:
  `Pending AirPlay sink "<name>" reachable via device <id>; switching output`
  (new pending-switch), `Retargeted across a transport boundary; restarting
  playback to switch backend` (new listener-retarget re-pick), plus the old
  `Output backend for current device:` / `boundary` / `sbufIsOld` set.
- The bridge device: single generic CoreAudio device, transport `airp`, name
  literally **"AirPlay"**, UID `52eec622-…-Audio`, IDs churn per
  materialization (saw 331→336→346→356→104→148 in one day). It exists ONLY
  while the system routes to an AirPlay sink; moving the system default away
  destroys it.

## What changed on 2026-07-24 (all pushed; full detail in the RESOLVED debug handoff)

1. `795d8cd50` — **Discard-wedge root fix.** Bridge reports 2.000 s stream
   latency; MediaToolbox anchors the synchronizer timebase that far behind
   the queue playhead; feeder cap now budgets `kAirPlayMaxBufferedSeconds +
   HAL device latency`. AirPlay playback no longer dies at ~2 s.
2. `015a2397a` — **Pending auto-switch matches by transport** (fallback from
   exact name), stores the bridge's real device name ("AirPlay") in the
   selection dict so name-fallback survives ID churn.
3. `cdd35cfd4` — **Backends re-pick after listener-driven retargets.** Bridge
   dies or tracked default moves across the AirPlay boundary → playback
   restarts on the correct backend (both directions).
4. `9de0bb28c` — **Virtual transports hidden from the quick picker** (Teams/
   Zoom devices), unless one is the current selection. Preferences → Output
   still lists everything (so BlackHole-style tools remain reachable there).
5. `bcf9d6b5e` — docs only.

Closed as platform limitation (human signed off): per-app AirPlay routing is
Apple-private (entitlement-gated); activating a sink hijacks the system
output and "System Default" resolving to the bridge is inherent. Do not
reopen without new API evidence.

## Expected-behavior changes that reinterpret old matrix rows

- **A10/A11 (route loss):** previously "falls back to default device and
  continues" within the AirPlay backend. NOW: bridge death triggers a
  backend restart onto OutputCoreAudio (brief interruption, then wired
  playback, correct backend in log). That IS the pass condition now.
- **A17/A18:** after auto-switch, the checkmark lands on the **"AirPlay"**
  bridge entry, not the room name — one-bridge model, by design.
- **AirPlay buffered depth** is now ~(2 s + device latency) ≈ 4 s: the
  visualization/position lead on AirPlay grows accordingly (known deferral,
  do not report).
- Stale-selection self-heal: if the stored dict points at a dead bridge, the
  rebuilt backend logs `No output device could be found` once, clears the
  selection to System Default, and continues on the real default. Noisy but
  correct; not a bug.

## What to run, in order

1. **A18, both passes, on build ≥ `9de0bb28c`** — the only fix-touched row
   not re-run: (1) pick a room in Preferences → Output → snap-back → activate
   in Sound settings with Preferences closed; (2) repeat with the pane OPEN
   while activating — picker must land on the new device (shows as
   "AirPlay"), not System Default. This is the historically worst
   interleaving; give it attention.
2. **Quick-picker filter visual check** (30 s): open the toolbar menu; Local
   section shows real devices only (no Microsoft Teams Audio / ZoomAudioDevice);
   they still appear in Preferences → Output.
3. **Re-run rows the fixes could touch:** A7, A8, A9 (route switches — the
   listener-retarget re-pick changes the System Default path), A10, A11
   (route loss, new expected behavior above), A3, A5 (basic AirPlay + pause/
   seek on the latency-aware cap).
4. **Rest of the matrix:** A1–A2 (wired regression — OutputCoreAudio was
   touched by cdd35cfd4), A4, A6, A12–A16, A19, per the full-testing
   handoff's row notes.
5. Record results inline in the Part A table
   (`2026-07-23-airplay-2-testing-followup-handoff.md`) as done for A17/A18.

## Open design item (do NOT fix mid-matrix unless a row fails on it)

Picker labeling/dedup rethink: the AirPlay section lists the "AirPlay"
bridge device AND all Bonjour room names; the name-based dedup can never
collapse them (bridge name ≠ room names). Options sketched: show room names
with the active one implied by the system route; or label the bridge entry
"AirPlay (current route)". Needs a small design decision with the human
AFTER the matrix is green.

## Still deferred until matrix green

Hygiene batch (see end of `.superpowers/sdd/progress.md`: dedup asymmetry,
positional synthetic IDs, `es` localization, warm-up skip on failed browser
state, etc.). Final review adjudicated all of it non-blocking.
