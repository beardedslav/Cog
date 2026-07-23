# Bonjour AirPlay Picker — Implementation Handoff

## Prompt for the new session

You are implementing a planned feature on branch `airplay-2-output` in
`/Users/kmalinowski/dev/Cog` (Cog, a native macOS audio player; Obj-C/Swift;
no unit-test suite — the build is the verification gate).

**Task: execute the implementation plan at
`docs/superpowers/plans/2026-07-23-airplay-bonjour-picker.md` using the
`superpowers:subagent-driven-development` skill** — fresh subagent per task,
review between tasks. The plan has 6 tasks with complete code, exact file
paths, and a build gate per task. Read the plan first; the spec behind it is
`docs/superpowers/specs/2026-07-23-airplay-bonjour-picker-design.md`.

Context you inherit (do not redo):

- The AirPlay 2 output feature is code-complete and reviewed (see
  `.superpowers/sdd/progress.md` for the full ledger). Part B follow-up fixes
  are done (commits `c644b50d9`..`178a0ea99`).
- `89d54f74e` fixed a playback-start deadlock inherited from main
  (`c2d5ac7a7` made `DSPFaderNode setDoPMode:` take the fader mutex; now an
  atomic store). Candidate for separate upstream/main cherry-pick at
  merge time.
- The manual hardware test matrix (rows A1–A16 in
  `docs/superpowers/handoffs/2026-07-23-airplay-2-testing-followup-handoff.md`)
  is still being run by the human; this feature adds rows A17–A19 (plan
  Task 6).

User rules that bind this repo: **no Claude/co-author signature lines in git
commits**; real tabs for indentation in Obj-C; never commit the untracked
`CLAUDE.md` or `graphify-out/`; never commit a `DEVELOPMENT_TEAM` (pre-commit
hook enforces; Xcode sometimes injects one into `project.pbxproj` — revert
it). One commit per plan task (messages are in the plan).

Build gate after every task:

```sh
xcodebuild -project Cog.xcodeproj -scheme Cog -configuration Debug -arch arm64 -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
```

Final gate (plan Task 6): the CI-equivalent universal build
(`-arch x86_64 -arch arm64 ... ONLY_ACTIVE_ARCH=NO`).

Watch-outs the plan already encodes (hold subagents to them):

- Task 1 edits `project.pbxproj` by hand — pattern-match the existing
  `AirPlayItem` entries, and verify no `DevelopmentTeam` sneaks into the
  staged diff.
- Task 3's defaults observer must not disarm on the browser's own
  `outputDevice` write (`writingSelection` flag; disarm-before-write order).
- Task 5's Swift/ObjC boundary: `+sharedBrowser` carries
  `NS_SWIFT_NAME(shared())`; the Preferences `didSet` recursion note in the
  plan is load-bearing — read it before changing that code.

When all 6 tasks are done: update the ledger
(`.superpowers/sdd/progress.md`, gitignored — update, do not commit), tell
the human rows A17–A19 (plus re-runs of A14/A16) are ready for hardware
testing, and push the branch. Do not merge or open a PR — the
merge/PR decision waits until the human finishes the full matrix
(then `superpowers:finishing-a-development-branch`).
