# AirPlay 2 Output Support — Design

**Date:** 2026-07-22
**Branch:** `airplay-2-output`
**Status:** Approved (brainstorming complete)

## Goal

True AirPlay 2 streaming from Cog on macOS: buffered long-form audio to AirPlay 2
devices (HomePods, Apple TVs, third-party speakers), with an in-app route picker
in the toolbar. Multi-room grouping is handled by the OS (Control Center); Cog
targets a route, the system fans it out.

**Must work when routed to AirPlay:** the full DSP chain (EQ, ReplayGain,
Rubberband/Signalsmith, FreeSurround, HRTF) and automatic DSD→PCM fallback.
**Nice-to-have, lower priority:** gapless playback (kept where nearly free),
visualization latency compensation (deferred if not free).

## Background: the 2023 revert

Cog already shipped an `AVSampleBufferAudioRenderer`-based output once:

- `dccb7f8b4` (2022-06) replaced the CoreAudio output with `OutputAVFoundation`
  (renderer + `AVSampleBufferRenderSynchronizer`). It carried ~1s of enqueued
  buffer and did resampling/HRTF/FreeSurround inside the output.
- `7ab2a8305` (2023-10) reverted to `OutputCoreAudio` because of playback and
  seeking latency. The deep buffer is inherent to the renderer's push model —
  and to AirPlay 2 itself — but it penalized wired listening.
- `OutputAVFoundation.m/h` remain on disk but are **orphaned**: no references in
  `project.pbxproj`, and they predate the DSP-chain extraction
  (`Audio/Chain/DSP/`), `VisualizationNode`, and the interrupt-forwarding work.

**Design conclusion:** the latency that killed the 2022 attempt is not a bug to
fix; it is the cost of buffered AirPlay. So the buffered output must be a
*second* backend that engages only when the route is AirPlay, never a
replacement for the low-latency wired path.

## Key platform facts (verified against the macOS SDK)

- `AVRoutePickerView` on macOS attaches only to an `AVPlayer` (`player`
  property). Cog's custom pipeline cannot use the system picker; we build our
  own button + menu.
- `AVSampleBufferAudioRenderer.audioOutputDeviceUniqueID` (macOS 10.13+)
  targets any CoreAudio output device by UID.
- AirPlay devices appear as CoreAudio devices with transport type
  `kAudioDeviceTransportTypeAirPlay` (`'airp'`).
- `AVRouteDetector.multipleRoutesDetected` reports AirPlay route availability
  even before a device materializes as a CoreAudio device.

## Architecture

### CogOutput protocol

Extract the interface `OutputNode` actually uses from `OutputCoreAudio` into a
`CogOutput` protocol: setup/process/close, pause/resume, seek/flush, volume,
latency reporting (`latency`, `getTotalLatency`, `getVisLatency` inputs),
fade support, `setShouldPlayOutBuffer`, end-of-stream signaling,
`outputFormatForInputFormat:`.

- `OutputCoreAudio` conforms **with no behavioral changes**. The wired path
  stays exactly what ships today.
- New `OutputAirPlay` (`Audio/Output/OutputAirPlay.m`, Obj-C) also conforms.

### OutputAirPlay

A fresh implementation against the current node architecture, using the
orphaned `OutputAVFoundation.m` as a **reference only** (its resampler, HRTF,
and FreeSurround now live in the DSP chain and must not be duplicated). The old
`OutputAVFoundation.m/h` files are deleted once `OutputAirPlay` lands.

- Push model: a feeder thread pulls `AudioChunk`s from the chain, wraps them in
  `CMSampleBuffer`s, enqueues into `AVSampleBufferAudioRenderer` under an
  `AVSampleBufferRenderSynchronizer`.
- PCM only. Target buffer depth ~2 s (local listeners never touch this path).
- Targets the selected AirPlay device via `audioOutputDeviceUniqueID`.
- Reports real buffered depth through the existing latency methods so position,
  scrobbling, and end-of-stream signaling stay honest.
- Pause = `synchronizer.rate = 0`; resume = `rate = 1`; seek = flush +
  re-enqueue (a beat of delay on seek is inherent and accepted).
- Spatial audio (`allowedAudioSpatializationFormats`) stays at default —
  explicitly out of scope (that is where the 2022 attempt hit Apple bug
  FB10441301).

### Backend switching

`OutputNode` — not the backends — owns observation of the `outputDevice`
NSUserDefaults key (moved up from `OutputCoreAudio`). On change it resolves the
device's transport type via `kAudioDevicePropertyTransportType`:

- transport `'airp'` → `OutputAirPlay` targeting that device UID
- anything else → `OutputCoreAudio` via the existing `setOutputDeviceByID:`

"System Default Device" resolves the *default device's* transport, so routing
via Control Center also engages the buffered path. Mid-play switches reuse the
existing teardown + `restartPlaybackAtCurrentPosition` flow. Every switch
decision logs device name, transport, and chosen backend at `DLog` level.

## UI

### Toolbar button

Custom toolbar item, template image = SF Symbol `airplay.audio`, added to all
three toolbars in `MainMenu.xib` (main window, mini window, mini player plus).
Default placement: after the shuffle/repeat cluster, before the Spectrum item.
Standard customizable `NSToolbar`, so users can move/remove it. The button
tints with the accent color while the active route is an AirPlay device.

### Device menu

Clicking opens an `NSMenu` built on demand:

- **Local** section: "System Default" plus non-AirPlay CoreAudio devices.
- **AirPlay** section: transport-`'airp'` devices.
- Checkmark on the active selection.

Selecting an entry writes the same `outputDevice` defaults dictionary the
Preferences pane writes — a single source of truth shared by the toolbar menu,
the Preferences device list, and the backend switcher. The Preferences device
list gains the same Local/AirPlay grouping; no other Preferences changes.

### Discovery fallback

macOS materializes an AirPlay device as a CoreAudio device only once the system
knows it. When `AVRouteDetector` reports routes but no `'airp'` device is
enumerable, the AirPlay section shows one item — "Open Sound Settings…" —
deep-linking to the Sound pane. New strings go through `Localizable.xcstrings`.

## Data flow

### DSD → PCM fallback (must-have)

`ConverterNode` already derives DoP-vs-PCM purely from the output's advertised
format (`ConverterNode.m:460`: DoP only when the output rate is input÷16).
`OutputAirPlay`'s `outputFormatForInputFormat:` only ever advertises plain PCM
rates, so DSD input automatically takes the `DSD_DECIMATE` path (e.g. DSD64 →
352.8 kHz float, ÷8). No new conversion code. Mid-track switches between a DoP
DAC and AirPlay go through restart-at-position, which rebuilds the chain — the
transition class already hardened by the recent DoP work.

### Timing

The renderer's buffered depth feeds `latency`/`getTotalLatency`, keeping the
position slider, scrobble threshold, and the delayed end-of-stream signal
(`dispatch_after` by latency) correct with ~2 s in flight.

### Gapless (kept where nearly free)

Successive `BufferChain`s feed one continuously running renderer with PTS
continuity; no flush at track boundaries. Deferred: gapless across *format
changes* on AirPlay (e.g. 44.1 k → 96 k) — v1 accepts a flush-induced gap
there.

### Visualization (deferred)

`VisualizationNode` keeps working but leads the audible audio by the buffer
depth. `OutputAirPlay` reports honest values into `getVisLatency`; if the
existing compensation absorbs them, fine, otherwise v1 ships with leading
visuals and a noted follow-up.

## Error handling

- **Route death** (speaker off, Wi-Fi drop, renderer `status == .failed`,
  `AVSampleBufferAudioRendererWasFlushedAutomaticallyNotification`): fall back
  to the system default device — which re-resolves the backend — and keep
  playing; surface a status message through the existing error-notification
  path.
- **Format rejection** (FB10441301-class limits): constrain advertised formats
  to what the renderer accepts and let the ConverterNode resampler degrade the
  stream rather than fail.
- **Sandbox**: verify `com.apple.security.network.client` is present (Cog
  already streams HTTP; no new entitlements expected).

## Out of scope

- Spatial audio / `allowedAudioSpatializationFormats`.
- In-app multi-room grouping UI (OS handles grouping via Control Center).
- Gapless across format changes on AirPlay (v1).
- Visualization delay compensation beyond honest latency reporting (v1).
- iOS-style `AVAudioSession` route-sharing policy (iOS-only API; N/A on macOS).

## Verification

No unit-test suite exists in this repo; verification is build-and-run:

1. Universal build (x86_64 + arm64) via the CI `xcodebuild` invocation.
2. **Wired regression:** play/pause/seek latency feel unchanged; DoP DAC
   playback (if hardware available); gapless album playback.
3. **AirPlay playback:** FLAC 44.1 k and 96 k; DSD64 plays as PCM; pause /
   resume / seek behavior; track transitions.
4. **Route switching mid-play**, both directions, via all three entry points:
   toolbar menu, Preferences, Control Center default-device change.
5. **Route loss mid-stream:** power off the speaker; playback falls back to the
   default device with a status message.
6. **Multi-room smoke test** via Control Center grouping.
