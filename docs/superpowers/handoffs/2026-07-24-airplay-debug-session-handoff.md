# AirPlay debug session handoff — 2026-07-24 evening

> **RESOLVED — 2026-07-24 late evening session. Do not resume from "Next
> steps"; everything below is kept for archaeology. Outcomes:**
>
> - **Finding 3 (discard wedge): FIXED at root cause** (795d8cd50). H1 was
>   refuted — a fresh renderer wedged identically. Real cause: the AirPlay
>   bridge reports 2.000 s stream latency (88200 frames @ 44.1k) and
>   MediaToolbox anchors the synchronizer timebase that far behind the
>   queue's playhead, so the 2.0 s feeder cap gated enqueue exactly at the
>   discard threshold. Fix: query the bound device's HAL output latency and
>   add it to the buffered-seconds cap. Verified: zero sbufIsOld discards,
>   continuous playback, seek/pause clean.
> - **Finding 1 (name-based pending switch): FIXED** (015a2397a) —
>   transport-based fallback match + store the bridge's real device name.
>   A17 auto-switch verified live; A18 Preferences flows still to re-run.
> - **Finding 2 (restore-system-default mitigation): NOT VIABLE, closed.**
>   Moving the system default away destroys the bridge device (verified by
>   enumeration); the earlier "bridge stayed alive" observation was made
>   while inaudibly wedged and was wrong. Research spike (SDK headers,
>   Optimus Player AirPlay-Enabler, FB13521393): per-app AirPlay routing on
>   macOS is entitlement-gated private API; AVRoutePickerView routes
>   AVPlayer only on macOS. No public path; system-route hijack is accepted
>   as a platform limitation (human signed off).
> - **Finding 4 (silent cross-transport retarget): FIXED** (cdd35cfd4) —
>   both backends re-run backendMatchesCurrentDevice after listener-driven
>   retargets and restart playback across the boundary. Verified live both
>   directions.
> - Bonus: virtual transport devices (Teams/Zoom) hidden from the quick
>   picker unless currently selected (9de0bb28c).

**Read this first when resuming. This continues the full-matrix testing
session (`2026-07-24-airplay-full-testing-handoff.md`) which was interrupted
mid-debug on rows A17/A18. Use `superpowers:systematic-debugging`; Phase 1
(root cause) is COMPLETE for all findings below — do not redo it. Resume at
"Next steps".**

## Prompt for the new session

You are resuming a live debugging session on branch `airplay-2-output` in
`/Users/kmalinowski/dev/Cog` (Cog, native macOS audio player; Obj-C/Swift; no
unit tests — build is the gate). The human drives hardware steps; you watch
logs and fix. Build/run/log commands are in the full-testing handoff. User
rules: no Claude/co-author signature lines in commits; tabs in Obj-C; never
commit CLAUDE.md, graphify-out/, or a DEVELOPMENT_TEAM.

The human's AirPlay sinks (Bonjour `_airplay._tcp`): **Bedroom, Utility
Room, Living Room**. Machine: MacBook Pro, speakers device name "MacBook Pro
Speakers" (deviceID 73 this boot, `bltn`).

## Session tooling gotchas (cost real time, don't rediscover)

- The user's zsh has a `log` **builtin/shim — `log show` silently returns
  nothing.** Always use `/usr/bin/log`.
- `--level debug` is a `log stream` flag; for `log show` use `--info --debug`.
- `DLog` is NSLog only in Debug builds. Cog-authored lines match
  `grep -E "\(line [0-9]+\)"`.
- Landmark predicate:
  `/usr/bin/log show --last 15m --predicate 'process == "Cog"' --info --debug`
  then grep for: `materialized|boundary|backend for current|Rebuilding|
  superseded|setOutputDeviceByID|sbufIsOld|Resyncing AQ timeline|
  FigSBAudioRenderer`.
- To dump exact CoreAudio device names/transports/UIDs (byte-exact), a Swift
  script from this session enumerates devices; recreate quickly via
  `system_profiler SPAudioDataType` (approximate) or rewrite: enumerate
  `kAudioHardwarePropertyDevices`, print
  `kAudioDevicePropertyDeviceNameCFString` (output scope), transport,
  `kAudioDevicePropertyDeviceUID`.

## Finding 1 — CONFIRMED, design-breaking: macOS materializes ONE generic device named "AirPlay"

On this macOS, activating any sink via Sound settings creates a single
CoreAudio bridge device, transport `airp`, **name literally `AirPlay`**
(UID like `52eec622-…-Audio`), routing to whichever sink the *system*
targets. There are never per-sink CoreAudio devices named "Bedroom" etc.
Observed IDs churn per materialization (331 → 336 → 346 within one session).

Breaks three spec assumptions
(`docs/superpowers/specs/2026-07-23-airplay-bonjour-picker-design.md`):

1. **Pending auto-switch can never fire.** `checkPendingSwitch`
   (`Window/AirPlayServiceBrowser.m`) matches the Bonjour name via
   `CogDeviceIDMatchingName` (exact `isEqualToString:`,
   `Audio/Output/OutputDeviceRouting.m:99`) — the device is named "AirPlay",
   so no match, silent failure. Confirmed in logs: device materialized
   18:48:11–16, pending still armed at 18:48:35 when the human's manual pick
   superseded it ("Pending AirPlay switch superseded…"). **A17/A18
   auto-switch step = ❌.** Fix direction: match any *newly appearing* device
   with transport `kAudioDeviceTransportTypeAirPlay` instead of by name.
2. **Picker dedup never dedups** — "AirPlay" ≠ any Bonjour name, so pickers
   list the bridge device *and* all room names.
3. **Cog cannot pick which sink at the CoreAudio level** — sink identity
   lives in the system route; the bridge is a proxy.

## Finding 2 — UX trap (not a code bug): activation hijacks system output; "System Default" then means the sink

Activating in Sound settings sets **system-wide** output (only public
materialization mechanism). The human then picked "System Default Device" in
Cog to "switch back to speakers" — which correctly resolved to the AirPlay
bridge. Both user complaints ("changes whole system output", "can't switch
back") stem from this. Explicit "MacBook Pro Speakers" pick works (transport
boundary rebuild verified in logs at 18:48:35).

**Mitigation candidate (experiment partly done):** after Cog binds the bridge
by UID, programmatically restore the previous system default
(`kAudioHardwarePropertyDefaultOutputDevice`). Evidence FOR viability: when
the human moved system output back to speakers while Cog's renderer held the
bridge (19:2x), **the bridge device stayed alive** — no DeviceIsAlive event,
no retarget fired. Audio inaudibility during that window was Finding 3, not
route loss. Needs a clean re-test after Finding 3 is fixed. This is a spec
change — get the human's sign-off.

## Finding 3 — MAIN OPEN BUG: plays ~2 s then silence (renderer discards everything)

Symptom: select the materialized "AirPlay" device, play → exactly ~2 s of
audio on the sink, then silence; seek buys another 2 s. No error anywhere:
renderer status healthy, `isReadyForMoreMediaData` YES, timebase runs at 1.0.

Mechanism (from MediaToolbox logs 19:22:44–47, fully diagnosed):

- The renderer's internal audio queue anchored its media clock ~2 s **ahead**
  of the `AVSampleBufferRenderSynchronizer` timebase Cog observes (timebase
  −1.015 while queue `currentMediaTime` 2.021 at the same instant).
- Cog's feeder gates enqueue at `kAirPlayMaxBufferedSeconds = 2.0` ahead of
  the timebase (`Audio/Output/OutputAirPlay.m:460`, constant at `:20`) —
  exactly the skew → zero net headroom.
- Every post-burst buffer arrives 12–23 ms late; MediaToolbox drops each one:
  `subaq_enqueueOneSourceSBuf: … sbufIsOld: 1 … WILL discard this sbuf now`
  plus endless `Resyncing AQ timeline` lines, at realtime pace, forever.

**Hypothesis H1 (untested, next action):** the skew appears only on a
renderer that was *retargeted in place* via `setAudioOutputDeviceUniqueID`
across routes. This instance (created 18:48:35 for device 336) was retargeted
to speakers 73 (18:49:43) and back to bridge 346 (19:18:23, with automatic
flush). The **fresh** renderer at 18:48:35 played 10+ s fine.

**Pending experiment (human, 30 s, current build):** in Cog's picker select
MacBook Pro Speakers, then the AirPlay device, then play. Both crossings are
transport boundaries → whole backend rebuilt → fresh renderer. If playback is
continuous past 2 s, H1 confirmed.

**Planned fix if confirmed:** in `setOutputDeviceByID:`
(`Audio/Output/OutputAirPlay.m:247–269`), when a *live* renderer is
retargeted to a different device, don't just swap the UID — set
`rendererFailed` under `currentPtsLock` so the feeder runs the existing
in-place `rebuildRenderer` path (`OutputAirPlay.m:698`). Optional defense in
depth: feeder-side wedge detection (timebase advancing while nothing
enqueueable and `outputPts` pinned at `currentPts + max`).

## Finding 4 — latent gap (noted, not yet user-visible)

`AudioPlayer` re-picks the backend only on `outputDevice` defaults writes
(`Audio/AudioPlayer.m:56`) and at play-start (`:102`). While on "System
Default Device", a HAL default-device change across a transport boundary just
retargets the live backend: at 18:49:43 OutputAirPlay silently followed the
default onto the built-in speakers (AirPlay backend + ~2 s latency on wired).
Mirror case exists for OutputCoreAudio onto an AirPlay route. Fix idea: a
`kAudioHardwarePropertyDefaultOutputDevice` listener in AudioPlayer that
re-runs the `backendMatchesCurrentDevice` check when on system default.

## Session timeline (for log archaeology; all 2026-07-24)

- 18:41 human picks Bonjour sink → Settings opens (designed A17 path; no
  AirPlay CoreAudio device existed).
- 18:48:11–16 sink activated in Settings; device churn 331/73/336.
- 18:48:35 pending supersede + transport-boundary rebuild → OutputAirPlay 336;
  plays fine ("it works").
- 18:49:43 default moved back to speakers → in-place retarget to 73.
- 19:18:23 sink re-activated → in-place retarget to 346 + automatic flush.
- 19:22:41 supersede again (human picked "AirPlay" device directly).
- 19:22:44 play → discards begin 19:22:46.78; seek 19:22:58 → same wedge.

## Next steps, in order

1. Run the H1 experiment above. If confirmed → implement retarget-rebuild
   fix, build-gate (`xcodebuild … -scheme Cog -configuration Debug -arch
   arm64 -derivedDataPath build CODE_SIGNING_ALLOWED=NO build`), re-test.
2. Re-run the restore-system-default viability test cleanly (Finding 2), then
   discuss spec change with the human: transport-based pending switch
   (Finding 1 fix), restore previous default after bind, picker
   dedup/labeling rethink (maybe show room names + single bridge sensibly).
3. Decide with the human whether Finding 4 gets fixed now or is deferred.
4. Update matrix rows A17/A18 (auto-switch ❌ w/ root cause) in the Part A
   table, update `.superpowers/sdd/progress.md`, commit per-fix, push.
5. Hygiene batch stays deferred until the matrix is green.
