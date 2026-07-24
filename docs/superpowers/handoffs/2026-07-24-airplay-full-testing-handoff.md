# AirPlay 2 + Bonjour Picker — Full Test-Matrix Handoff

**Read this first. One work stream: drive the full manual hardware matrix
(A1–A19) with the human, triage and fix what it finds. Do not redo completed
work.**

## Prompt for the new session

You are resuming work on branch `airplay-2-output` in
`/Users/kmalinowski/dev/Cog` (Cog, a native macOS audio player; Obj-C/Swift;
no unit-test suite — the build is the verification gate). Two features are
code-complete, reviewed, and pushed to `origin/airplay-2-output`
(HEAD `cf8d1d727`):

1. **AirPlay 2 output** (7 tasks + final review + 2 fix passes; Part B
   follow-ups B1–B7 all done).
2. **Bonjour-assisted AirPlay picker** (6 tasks + final review + 3 fix
   passes: pending-switch clobber/refcount lifecycle `1de69eea7`,
   window-close browsing leak `bc1416178`, pane-visibility gating
   `df7deb32d`).

Nothing on the matrix has been formally recorded yet. A1 was informally
verified once while fixing a main-inherited deadlock (`89d54f74e`), but that
predates all Part B fixes and the entire Bonjour feature — treat every row
as not run.

**Your job:** guide the human through matrix rows A1–A19, record results,
and on any failure use `superpowers:systematic-debugging` before proposing
fixes. The matrix table lives in
`docs/superpowers/handoffs/2026-07-23-airplay-2-testing-followup-handoff.md`
(Part A) — record ✅/❌ + notes inline there, next to each row. The human
runs all hardware steps; you watch logs, interpret, and fix.

Key documents:

- Matrix + row details: `docs/superpowers/handoffs/2026-07-23-airplay-2-testing-followup-handoff.md`
- Specs: `docs/superpowers/specs/2026-07-22-airplay-2-output-design.md`,
  `docs/superpowers/specs/2026-07-23-airplay-bonjour-picker-design.md`
- Plans: `docs/superpowers/plans/2026-07-22-airplay-2-output.md`,
  `docs/superpowers/plans/2026-07-23-airplay-bonjour-picker.md`
- Progress ledger (full review history, all deferred minors, follow-up
  batch): `.superpowers/sdd/progress.md` (gitignored, local only)

User rules that bind this repo: **no Claude/co-author signature lines in git
commits**; real tabs for indentation in Obj-C; never commit the untracked
`CLAUDE.md` or `graphify-out/`; never commit a `DEVELOPMENT_TEAM`
(pre-commit hook enforces; Xcode sometimes injects one into
`project.pbxproj` — revert it).

## Test session setup

```sh
xcodebuild -project Cog.xcodeproj -scheme Cog -configuration Debug \
  -arch arm64 -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
open build/Build/Products/Debug/Cog.app
```

Log watching (second terminal):

```sh
log stream --predicate 'process == "Cog"' --level debug
```

Landmark log lines:

- Backend choice: `Output backend for current device: OutputAirPlay|OutputCoreAudio`
- Bonjour auto-switch firing: `Pending AirPlay device "<name>" materialized as <id>; switching output`
- Pending pick superseded: `Pending AirPlay switch superseded by a direct device selection`
- Browser permission/network trouble: `AirPlay Bonjour browser state …`

## Running the matrix

Order: A1–A15 (original), then A16 (route-detector fallback), then A17–A19
(Bonjour). Batch by hardware setup, not number, if that is faster — e.g. all
toolbar-menu rows together.

Row-specific notes beyond the table:

- **A14** needs eyes on all three windows (main, mini, mini plus) — this was
  never visually verified in any session (screen-capture permissions).
- **A16/A17** setup ("sink on the network but not materialized as a
  CoreAudio device"): a HomePod/AirPlay speaker that is on the network but
  not currently selected as an output anywhere. If everything is already
  materialized, toggling the device off/on in Sound settings or rebooting
  the speaker usually gets it back to Bonjour-only.
- **A17** – marker: reopen the toolbar menu within ~5 s of the pick (the
  browse results survive a close by a 5 s grace window; after that the list
  rebuilds when the menu reopens and the marker should reappear once the
  name is rediscovered).
- **A18** has TWO passes: (1) pick in Preferences → snap-back → activate in
  Sound settings with Preferences closed; (2) same but leave Preferences →
  Output open while activating — the picker must land on the new device,
  not System Default. Pass 2 is the exact interleaving that produced the
  worst post-review bug; give it attention.
- **A19** (macOS 15+ only): the Local Network prompt should appear on the
  first action that starts browsing (first toolbar-menu open or first visit
  to Preferences → Output) — and NOT merely from opening Preferences on a
  different pane. To re-test after answering: System Settings → Privacy &
  Security → Local Network → toggle Cog, or delete/re-grant and relaunch.
  Denying must leave both pickers on pre-Bonjour behavior (materialized
  devices + "Open Sound Settings…" fallback), no hang from the 0.7 s
  warm-up wait.

Known v1 deferrals — expected, do NOT report as bugs: route-loss feedback is
log-only; gapless across sample-rate changes on AirPlay may gap;
visualization leads audible audio by the buffer depth; spatial audio
untouched; a ~0.7 s menu-open delay when no sinks exist or permission is
denied (bounded warm-up wait, known); Preferences pane may transiently show
System Default if HAL enumeration lags the auto-switch (self-corrects on the
next update).

## On failures

Use `superpowers:systematic-debugging`. Capture the log around the failure
and the exact row. Fix on `airplay-2-output`, one commit per fix, build gate
after each:

```sh
xcodebuild -project Cog.xcodeproj -scheme Cog -configuration Debug -arch arm64 -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
```

Rebuild, relaunch, re-run the failed row plus any row the fix could touch.

Do NOT start the deferred hygiene batch (listed at the end of
`.superpowers/sdd/progress.md`: dedup asymmetry, positional synthetic IDs,
`es` localization, warm-up skip on failed browser state, etc.) until the
matrix is green — the final review adjudicated all of it non-blocking, and
churning code mid-matrix invalidates rows.

## After the matrix is green

1. Append the recorded results to the Part A table (inline ✅/❌ + notes),
   update the ledger, commit (no signature lines), push.
2. Optionally run the hygiene batch as one commit, re-running affected rows.
3. Final gate: CI-equivalent universal build
   (`-arch x86_64 -arch arm64 … ONLY_ACTIVE_ARCH=NO`).
4. Use `superpowers:finishing-a-development-branch` — the merge/PR decision
   was deferred until testing is done. At merge time, remember
   `89d54f74e` (fader DoP-mode deadlock) is a candidate for a separate
   upstream/main cherry-pick — it fixes a main-inherited bug, not a branch
   bug.
