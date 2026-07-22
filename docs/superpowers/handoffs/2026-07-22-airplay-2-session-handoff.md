# AirPlay 2 Output — Session Handoff

**Read this first, then resume execution. Do not redo completed work.**

## Prompt for the new session

You are resuming a subagent-driven plan execution on branch `airplay-2-output` in
`/Users/kmalinowski/dev/Cog` (Cog, a native macOS audio player; Obj-C; no unit-test
suite — the build is the verification gate). Invoke the
`superpowers:subagent-driven-development` skill and continue the plan at
**Task 3 fix stage** (see "Exact resume point" below). Key documents:

- Spec: `docs/superpowers/specs/2026-07-22-airplay-2-output-design.md`
- Plan (7 tasks, complete code inline): `docs/superpowers/plans/2026-07-22-airplay-2-output.md`
- Progress ledger: `.superpowers/sdd/progress.md`
- Task briefs/reports/review packages: `.superpowers/sdd/`

User rules that bind this repo: **no Claude/co-author signature lines in git
commits** (also stored in memory: `no-claude-commit-signature`); real tabs for
indentation; never commit the untracked `CLAUDE.md` or `graphify-out/`; never
commit a `DEVELOPMENT_TEAM` (a pre-commit hook enforces this — Xcode builds
sometimes inject one into `Cog.xcodeproj/project.pbxproj`, revert it before
committing, it happened once already in Task 3).

Build gate for every task:

```sh
xcodebuild -project Cog.xcodeproj -scheme Cog -configuration Debug -arch arm64 -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
```

## State at handoff

| Task | Status | Commits |
|---|---|---|
| Spec + plan committed | done | `e96bb66a9`, `60b64cbad` |
| 1. `CogOutput` protocol | complete, review clean | `f5286e887` |
| 2. `OutputDeviceRouting` helpers | complete, review clean | `3e536af9b` |
| 3. `OutputAirPlay` backend | **implemented (`0addf3e0b`), review found issues, FIX NOT YET DISPATCHED** | fix pending |
| 4. Transport-driven backend selection | not started | — |
| 5. AirPlay toolbar button | not started | — |
| 6. Preferences grouping | not started | — |
| 7. Cleanup + universal build + manual matrix | not started | — |

## Exact resume point: dispatch the Task 3 fix subagent

Task 3's reviewer (full findings in its review output; diff package at
`.superpowers/sdd/review-3e536af9b..0addf3e0b.diff`, report at
`.superpowers/sdd/task-3-report.md`) returned spec ✅ but three Important
findings on `Audio/Output/OutputAirPlay.m`. Dispatch ONE fix subagent (sonnet)
with the fixes below, build gate, append-to-report contract
(`.superpowers/sdd/task-3-report.md`), then RE-REVIEW the fix diff before
marking Task 3 complete in the ledger.

**I-1 (dropped audio at every start/seek).** `threadEntry:` starts the
synchronizer (`resume` → `setRate:1.0`) before anything is enqueued, so the
timeline advances from 0 while the DSP tail spins up, and the first chunks are
stamped in the past and dropped. Fix: gate the resume on the first successful
enqueue — in `threadEntry:` change `if(!started && !paused)` to
`if(!started && !paused && prebufferReached)`, and in `flushRenderer` add
`prebufferReached = NO; prebufferSignaled = NO;` so post-seek playback also
waits for the first re-enqueued buffer.

**I-2 (retain cycle).** The periodic observer block in `synchronizerBlock`
captures `self` strongly (`self->currentPts` etc.); the token is retained by
`renderSynchronizer`, a strong ivar → cycle (this is the `-Warc-retain-cycles`
warning the build shows). Fix: `__weak OutputAirPlay *weakSelf = self;` before
the block; inside, `OutputAirPlay *strongSelf = weakSelf; if(!strongSelf) return;`
and use `strongSelf->` for all ivar accesses.

**I-3 (teardown race, end-of-stream path).** On natural end of stream the
feeder thread itself calls `doStop`, which nils `outputController` /
`visController` while an in-flight main-queue observer block may still read
them. Fix WITHOUT a dispatch_sync barrier — that can deadlock: `dealloc` busy-
waits on `stopCompleted` (possibly on the main thread) while the feeder would
be dispatch_sync-ing to main. Instead make the accesses lock-guarded: in the
observer block, snapshot `outputController` and `visController` into locals
under `currentPtsLock` (inside the existing lock section) and use only the
locals; in `doStop`, take `currentPtsLock` around `outputController = nil` and
around capturing+niling `visController` (call `[visController reset]` on a
local AFTER unlocking).

**M-1 (torn CMTime read).** `resume` reads `currentPts` unlocked. Fix: snapshot
under `currentPtsLock` into a local, pass that to `setRate:1.0 time:`.

**M-2 (unsynchronized `secondsLatency`).** Guard writes (observer block),
zeroing (`flushRenderer`), and reads (`latency`, `doStop` drain calculation)
with `currentPtsLock`.

**M-3 — adjudicated NO CHANGE NEEDED** (controller resolved this with cross-file
context the reviewer lacked): the reviewer thought `prepareForInputFormat:`
fails to propagate the downmix format, but `OutputNode.prepareForInputFormat`
(`Audio/Chain/OutputNode.m:315`) already calls
`[[output downmix] setOutputFormat:…]` after the backend call. Tell the
re-reviewer this adjudication so it isn't re-flagged.

**M-4 (dead `faded` flag), M-5 (doStop drain ineffective when run on main
thread — bounded, no hang):** deferred; recorded in the ledger for the final
whole-branch review to triage. Do not fix now.

## After Task 3 is green

Continue the normal loop for Tasks 4–7: for each task run
`scripts/task-brief docs/superpowers/plans/2026-07-22-airplay-2-output.md N`
(scripts live in the subagent-driven-development skill directory), dispatch an
implementer (haiku for Tasks 6–7, sonnet for 4–5; the plan contains complete
code), record the pre-dispatch HEAD as review BASE, run
`scripts/review-package BASE HEAD`, dispatch a task reviewer (sonnet), fix loop
if needed, append to the ledger. Reviewer context worth passing forward:

- Task 4 reviewer: `AudioPlayer.play:` reuses the existing output node; the
  rebuild check must run BEFORE the `if(output) fadeOutBackground` block.
- Task 5 has xib edits in three toolbars — after building, a run-launch sanity
  check matters more than the diff (button presence).
- Tasks 4 and 7 contain manual steps requiring AirPlay hardware — flag them to
  the user rather than skipping silently.

After Task 7: final whole-branch review on the most capable model using
`superpowers:requesting-code-review`'s template with
`scripts/review-package $(git merge-base main HEAD) HEAD`, pointing it at the
deferred Minors list in the ledger (Task 2: no raw build log in report,
ElementMaster deprecation is pre-existing idiom; Task 3: M-4, M-5). Then
`superpowers:finishing-a-development-branch`.

Known v1 deferrals (by design, in the spec/plan — do not "fix"): route-loss
feedback is log-only; gapless across sample-rate changes on AirPlay may gap;
visualization leads audible audio unless existing latency compensation absorbs
it; spatial audio explicitly out of scope (never set
`allowedAudioSpatializationFormats`).
