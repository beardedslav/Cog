# AirPlay picker: Bonjour-assisted device list — design

Date: 2026-07-23. Extends the AirPlay 2 output feature
(`2026-07-22-airplay-2-output-design.md`) on branch `airplay-2-output`.

## Problem

macOS materializes an AirPlay sink as a CoreAudio device only after the user
activates it once via Sound settings / Control Center. Until then, Cog's
pickers (toolbar menu, Preferences → Output) cannot list it — the toolbar
falls back to a single "Open Sound Settings…" item. Users expect the dropdown
to show their AirPlay devices.

## Verified platform constraints (macOS 26 SDK)

- `AVAudioSession` is `API_UNAVAILABLE(macos)`: no iOS-style route switching.
- `AVRoutePickerView` on macOS routes only an `AVPlayer`; routing an
  `AVSampleBufferAudioRenderer` via the system picker is iOS/tvOS-only.
- No public API lists or connects to un-materialized AirPlay sinks.
- AirPlay sinks advertise `_airplay._tcp` over Bonjour — names are publicly
  discoverable via Network.framework/NSNetServiceBrowser.
- The app sandbox already has outgoing network connections enabled
  (`ENABLE_OUTGOING_NETWORK_CONNECTIONS = YES`); Bonjour browsing additionally
  requires `NSBonjourServices` (listing `_airplay._tcp`) and
  `NSLocalNetworkUsageDescription` in Info.plist, and triggers the macOS 15+
  one-time local-network permission prompt on first browse.

Chosen approach: Bonjour-discovered names merged into both pickers, with a
pending auto-switch for devices the system has not yet materialized.
Rejected: dummy-`AVPlayer` `AVRoutePickerView` (routes the wrong object);
private MediaRemote API (fragile, not upstreamable).

## Components

### AirPlayServiceBrowser (new, shared)

Small Objective-C class (`Window/AirPlayServiceBrowser.[hm]`, exposed to Swift
via the app bridging header) that browses Bonjour `_airplay._tcp` and
publishes a deduplicated list of discovered service names.

- API: `+sharedBrowser`; `-beginBrowsing` / `-endBrowsingSoon` reference-ish
  lifecycle: browsing runs while at least one picker needs it and stops after
  a short grace window (~5 s), mirroring the AVRouteDetector pattern.
- Publishes `@property (readonly) NSArray<NSString *> *discoveredNames` and
  posts a notification on changes so an open menu / SwiftUI list can refresh.
- Browse failure or local-network permission denial yields an empty list —
  pickers degrade to current behavior. No caching across launches.

### Picker contents (toolbar `AirPlayItem` + Preferences `AudioDeviceModel`)

The AirPlay section shows the union of:

1. Materialized CoreAudio `'airp'` devices (as today — selecting connects
   directly), and
2. Bonjour-discovered names not matching any materialized device (dedup by
   case- and whitespace-insensitive name comparison; CoreAudio entry wins).

Unmaterialized entries render as normal items. "Open Sound Settings…"
remains only when routes are detected (`multipleRoutesDetected`) and both
lists are empty. "No AirPlay devices found" remains for the nothing-at-all
case.

While a pending switch (below) is armed, the pending device shows
`NSControlStateValueMixed` (–) in the toolbar menu; the checkmark appears
only once actually selected.

### Pending auto-switch (owned by AirPlayServiceBrowser)

Selecting an unmaterialized device:

1. Arms a session-scoped pending switch holding the device name.
2. Opens Sound settings (existing `openSoundSettings:` deep link).
3. Installs a `kAudioHardwarePropertyDevices` listener. On every device-list
   change, look for an alive output device whose name matches
   (`CogDeviceIDMatchingName`) and whose transport is
   `kAudioDeviceTransportTypeAirPlay`.
4. On match: write `{name, deviceID}` to the `outputDevice` user default on
   the main queue — the existing KVO machinery (AudioPlayer backend check,
   output device switch) does the rest — then disarm and remove the listener.

Lifetime: armed until superseded by any other device selection (either
picker), replaced by a newer pending pick, or app quit. No timeout, no
persistence across launches. Disarm also removes the HAL listener.

### Preferences wiring

`AudioDeviceModel` (Swift) subscribes to the browser while the Output pane is
visible and appends unmaterialized names to its AirPlay section using
synthetic negative IDs (below -1, never colliding with the System Default
sentinel); selecting one calls the same arm-pending path instead of writing
a device ID directly.

## Edge cases

- Duplicate names across `_airplay._tcp` services (stereo pairs, groups):
  dedup by name; first match wins on materialization.
- A local (non-AirPlay) device sharing a discovered name: transport check in
  the pending matcher prevents a false bind.
- Pending device disappears from Bonjour: stays armed (the user may still
  activate it); the menu keeps listing it only while discovered or pending.
- Permission prompt: first menu open on macOS 15+ triggers the local-network
  dialog; denial leaves Bonjour empty and pickers fall back to today's UX.

## Testing (extends the manual matrix)

- A17: with a sink on the network but not materialized, open the toolbar
  menu → the device is listed by name; pick it → Sound settings opens,
  pending marker (–) shows on reopen; activate the device in Settings →
  Cog switches to it automatically (log shows backend/device change).
- A18: same via Preferences → Output.
- A19: first-open local-network permission prompt appears; denying it leaves
  the pickers functional with today's fallback behavior.
- Re-run A14 (menu visual) and A16 (fallback item) after implementation.
