# Bonjour-Assisted AirPlay Picker Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Both output pickers (toolbar menu, Preferences → Output) list every AirPlay sink on the network by name, and selecting a not-yet-materialized sink auto-switches Cog the moment macOS materializes it.

**Architecture:** One new shared ObjC class, `AirPlayServiceBrowser`, owns Bonjour `_airplay._tcp` browsing (menu-open-scoped, 5 s grace) and the session-scoped pending auto-switch (CoreAudio device-list listener → write `outputDevice` defaults). The toolbar menu and the Swift Preferences model both consume it: they union its discovered names with the materialized CoreAudio `'airp'` devices.

**Tech Stack:** Objective-C, Network.framework C API (`nw_browser`), CoreAudio HAL listeners, SwiftUI (Preferences), Xcode project file edited by hand.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-07-23-airplay-bonjour-picker-design.md`.
- Branch `airplay-2-output`. Repo rules: **no Claude/co-author lines in commits**; real tabs for indentation in ObjC; never commit `CLAUDE.md`, `graphify-out/`, or a `DEVELOPMENT_TEAM` (Xcode sometimes injects one into `project.pbxproj` — revert it before committing).
- No unit-test suite exists. The verification gate for every task is the Debug build:
  `xcodebuild -project Cog.xcodeproj -scheme Cog -configuration Debug -arch arm64 -derivedDataPath build CODE_SIGNING_ALLOWED=NO build`
  (expect `** BUILD SUCCEEDED **`). Runtime verification is the manual matrix (Task 6).
- App deployment floor is macOS 10.15 (`nw_browser` and everything used here is 10.15+).
- User-facing strings go through `Localizable.xcstrings` / `InfoPlist.xcstrings`.

---

### Task 1: AirPlayServiceBrowser — Bonjour browsing core

**Files:**
- Create: `Window/AirPlayServiceBrowser.h`
- Create: `Window/AirPlayServiceBrowser.m`
- Modify: `Cog.xcodeproj/project.pbxproj` (add both files, compile the .m into the Cog app target)
- Modify: `Cog-Bridging-Header.h` (expose to Swift)

**Interfaces:**
- Consumes: nothing from other tasks.
- Produces (used by Tasks 3–5):
  - `+ (AirPlayServiceBrowser *)sharedBrowser NS_SWIFT_NAME(shared());` — Swift sees `AirPlayServiceBrowser.shared()`.
  - `- (void)beginBrowsing;` — idempotent; starts (or keeps) the Bonjour browser.
  - `- (void)endBrowsingSoon;` — schedules stop after a 5 s grace unless `beginBrowsing` runs again.
  - `@property (readonly) NSArray<NSString *> *discoveredNames;` — sorted, deduplicated service names; empty on failure/denial.
  - `- (BOOL)waitForFirstResultsUpTo:(NSTimeInterval)timeout;` — main-thread bounded run-loop wait so a cold menu open can warm up; returns YES if any results arrived.
  - Notification `AirPlayServiceBrowserDidUpdateNotification` (exported `extern NSNotificationName`), posted on the main thread whenever `discoveredNames` changes.

- [ ] **Step 1: Write `Window/AirPlayServiceBrowser.h`**

```objc
//
//  AirPlayServiceBrowser.h
//  Cog
//
//  Shared Bonjour browser for AirPlay sinks (_airplay._tcp) plus the
//  session-scoped pending auto-switch for sinks macOS has not yet
//  materialized as CoreAudio devices. Main-thread only.
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

extern NSNotificationName const AirPlayServiceBrowserDidUpdateNotification;

@interface AirPlayServiceBrowser : NSObject

+ (AirPlayServiceBrowser *)sharedBrowser NS_SWIFT_NAME(shared());

// Browsing runs while at least one picker needs it; endBrowsingSoon stops it
// after a ~5 s grace window unless beginBrowsing is called again first.
- (void)beginBrowsing;
- (void)endBrowsingSoon;

// Sorted, deduplicated Bonjour service names. Empty when browsing is off,
// failed, or local-network permission was denied.
@property (nonatomic, readonly) NSArray<NSString *> *discoveredNames;

// Bounded main-thread run-loop wait for the first results after a cold
// beginBrowsing, so the toolbar menu can be built warm. Returns YES if any
// results are available.
- (BOOL)waitForFirstResultsUpTo:(NSTimeInterval)timeout;

@end

NS_ASSUME_NONNULL_END
```

- [ ] **Step 2: Write `Window/AirPlayServiceBrowser.m`** (browsing only; the pending switch is Task 3)

```objc
//
//  AirPlayServiceBrowser.m
//  Cog
//

#import "AirPlayServiceBrowser.h"

#import <Network/Network.h>

#import "Logging.h"

NSNotificationName const AirPlayServiceBrowserDidUpdateNotification = @"AirPlayServiceBrowserDidUpdateNotification";

@implementation AirPlayServiceBrowser {
	nw_browser_t browser;
	NSMutableSet<NSString *> *names;
	NSUInteger browseGeneration;
}

+ (AirPlayServiceBrowser *)sharedBrowser {
	static AirPlayServiceBrowser *shared;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		shared = [AirPlayServiceBrowser new];
	});
	return shared;
}

- (id)init {
	self = [super init];
	if(self) {
		names = [NSMutableSet set];
	}
	return self;
}

- (NSArray<NSString *> *)discoveredNames {
	return [[names allObjects] sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
}

static NSString *browseResultName(nw_browse_result_t result) {
	if(!result) return nil;
	nw_endpoint_t endpoint = nw_browse_result_copy_endpoint(result);
	if(!endpoint) return nil;
	const char *name = nw_endpoint_get_bonjour_service_name(endpoint);
	return name ? @(name) : nil;
}

- (void)beginBrowsing {
	++browseGeneration;
	if(browser) return;

	nw_browse_descriptor_t descriptor = nw_browse_descriptor_create_bonjour_service("_airplay._tcp", NULL);
	nw_parameters_t parameters = nw_parameters_create();
	nw_parameters_set_include_peer_to_peer(parameters, true);
	browser = nw_browser_create(descriptor, parameters);
	if(!browser) return;

	// Deliver on the main queue: results mutate `names` and notify UI. The
	// toolbar warm-up wait (below) spins the default run-loop mode, which
	// drains the main queue, so results arrive even before the menu shows.
	nw_browser_set_queue(browser, dispatch_get_main_queue());

	__weak AirPlayServiceBrowser *weakSelf = self;
	nw_browser_set_browse_results_changed_handler(browser, ^(nw_browse_result_t old_result, nw_browse_result_t new_result, bool batch_complete) {
		AirPlayServiceBrowser *strongSelf = weakSelf;
		if(!strongSelf) return;
		BOOL changed = NO;
		NSString *oldName = browseResultName(old_result);
		NSString *newName = browseResultName(new_result);
		if(oldName && !newName && [strongSelf->names containsObject:oldName]) {
			[strongSelf->names removeObject:oldName];
			changed = YES;
		}
		if(newName && ![strongSelf->names containsObject:newName]) {
			[strongSelf->names addObject:newName];
			changed = YES;
		}
		if(changed) {
			[[NSNotificationCenter defaultCenter] postNotificationName:AirPlayServiceBrowserDidUpdateNotification object:strongSelf];
		}
	});
	nw_browser_set_state_changed_handler(browser, ^(nw_browser_state_t state, nw_error_t _Nullable error) {
		if(state == nw_browser_state_failed || state == nw_browser_state_waiting) {
			// Permission denied or network unavailable; pickers fall back to
			// the pre-Bonjour behavior. Log only.
			DLog(@"AirPlay Bonjour browser state %d, error %@", (int)state, error);
		}
	});
	nw_browser_start(browser);
}

- (void)endBrowsingSoon {
	NSUInteger generation = browseGeneration;
	__weak AirPlayServiceBrowser *weakSelf = self;
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
		AirPlayServiceBrowser *strongSelf = weakSelf;
		if(!strongSelf) return;
		if(generation != strongSelf->browseGeneration) return;
		if(strongSelf->browser) {
			nw_browser_cancel(strongSelf->browser);
			strongSelf->browser = NULL;
		}
		[strongSelf->names removeAllObjects];
	});
}

- (BOOL)waitForFirstResultsUpTo:(NSTimeInterval)timeout {
	NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
	while(![names count] && [deadline timeIntervalSinceNow] > 0) {
		[[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
		                         beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
	}
	return [names count] > 0;
}

@end
```

- [ ] **Step 3: Add both files to the Xcode project**

Edit `Cog.xcodeproj/project.pbxproj` by hand, pattern-matching the existing
`AirPlayItem` entries (`grep -n "AirPlayItem" Cog.xcodeproj/project.pbxproj`
shows every section that needs a sibling entry). Four places, using two fresh
24-hex-char UUIDs for the file references (one per file) and one for the
build file:

1. `PBXBuildFile` section: `AirPlayServiceBrowser.m in Sources` entry.
2. `PBXFileReference` section: one entry per file (`sourcecode.c.objc` /
   `sourcecode.c.h`, `path = AirPlayServiceBrowser.m` etc.,
   `sourceTree = "<group>"`).
3. The group that lists `Window/` children (`AirPlayItem.*` currently sits in
   the Visualization group — a known quirk; add the new files to the **same
   group** the `AirPlayItem` files are in so the relative `path` resolves the
   same way; do not relocate AirPlayItem).
4. `PBXSourcesBuildPhase` for the Cog app target: add the `.m` build file.

Note: the group containing `AirPlayItem.m` uses paths relative to its group
folder. Check `path = Window/AirPlayItem.m` vs `path = AirPlayItem.m` in the
file reference and mirror whichever form AirPlayItem uses.

- [ ] **Step 4: Expose to Swift**

In `Cog-Bridging-Header.h` add after the `Spotlight` import:

```objc
#import "Window/AirPlayServiceBrowser.h"
```

(If the group in Step 3 stores the files with a non-`Window/` relative path,
still import by the on-disk path shown here — the bridging header resolves
from the project root.)

- [ ] **Step 5: Build gate**

Run: `xcodebuild -project Cog.xcodeproj -scheme Cog -configuration Debug -arch arm64 -derivedDataPath build CODE_SIGNING_ALLOWED=NO build 2>&1 | grep -E "^\*\*|error:"`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 6: Commit**

```bash
git add Window/AirPlayServiceBrowser.h Window/AirPlayServiceBrowser.m Cog.xcodeproj/project.pbxproj Cog-Bridging-Header.h
git commit -m "Add shared Bonjour browser for AirPlay sinks"
```

(Confirm `git diff --cached Cog.xcodeproj/project.pbxproj` contains no
`DevelopmentTeam` before committing.)

---

### Task 2: Info.plist local-network keys

**Files:**
- Modify: `Info.plist`
- Modify: `InfoPlist.xcstrings`

**Interfaces:**
- Consumes: nothing.
- Produces: local-network permission plumbing required for Task 1's browser to return results on macOS 15+.

- [ ] **Step 1: Add the two keys to `Info.plist`**

Insert inside the top-level `<dict>` (alphabetical placement near other `NS*`
keys is fine):

```xml
	<key>NSBonjourServices</key>
	<array>
		<string>_airplay._tcp</string>
	</array>
	<key>NSLocalNetworkUsageDescription</key>
	<string>Cog looks for AirPlay speakers on your network so it can list them in the output device menu.</string>
```

Validate: `plutil -lint Info.plist` → `Info.plist: OK`.

- [ ] **Step 2: Localize the usage description**

`InfoPlist.xcstrings` is a JSON string catalog. Add a top-level entry to its
`"strings"` object (keep existing entries untouched):

```json
"NSLocalNetworkUsageDescription" : {
  "extractionState" : "manual",
  "localizations" : {
    "en" : {
      "stringUnit" : {
        "state" : "translated",
        "value" : "Cog looks for AirPlay speakers on your network so it can list them in the output device menu."
      }
    }
  }
}
```

Validate: `python3 -c "import json;json.load(open('InfoPlist.xcstrings'))"` → no output.

- [ ] **Step 3: Build gate**

Run: `xcodebuild -project Cog.xcodeproj -scheme Cog -configuration Debug -arch arm64 -derivedDataPath build CODE_SIGNING_ALLOWED=NO build 2>&1 | grep -E "^\*\*|error:"`
Expected: `** BUILD SUCCEEDED **`
Then confirm the key landed: `plutil -p build/Build/Products/Debug/Cog.app/Contents/Info.plist | grep -A2 Bonjour` shows `_airplay._tcp`.

- [ ] **Step 4: Commit**

```bash
git add Info.plist InfoPlist.xcstrings
git commit -m "Declare Bonjour AirPlay browsing in Info.plist"
```

---

### Task 3: Pending auto-switch in AirPlayServiceBrowser

**Files:**
- Modify: `Window/AirPlayServiceBrowser.h`
- Modify: `Window/AirPlayServiceBrowser.m`

**Interfaces:**
- Consumes: Task 1's class; `CogDeviceIDMatchingName()`, `CogDeviceTransportType()`, `kAudioDeviceTransportTypeAirPlay` from `<CogAudio/OutputDeviceRouting.h>`.
- Produces (used by Tasks 4–5):
  - `- (void)armPendingSwitchForDeviceName:(NSString *)name;` — remembers the pick, installs the HAL listener, checks immediately.
  - `@property (nonatomic, readonly, nullable) NSString *pendingDeviceName;` — non-nil while armed (menu shows the `–` marker for it).
  - Automatic disarm whenever `outputDevice` defaults change from any writer other than the browser itself.

- [ ] **Step 1: Extend the header**

Add inside the `@interface`, after `waitForFirstResultsUpTo:`:

```objc
// Pending auto-switch: remembers an un-materialized sink the user picked and
// selects it the moment macOS materializes a matching AirPlay CoreAudio
// device. Armed until superseded (any other outputDevice selection or a
// newer pick) or app quit. Session-scoped; never persisted.
- (void)armPendingSwitchForDeviceName:(NSString *)name;
@property (nonatomic, readonly, nullable) NSString *pendingDeviceName;
```

- [ ] **Step 2: Implement in the .m**

Add imports at the top of `AirPlayServiceBrowser.m`:

```objc
#import <CoreAudio/AudioHardware.h>

#import <CogAudio/OutputDeviceRouting.h>
```

Add ivars to the implementation block:

```objc
	NSString *pendingName;
	BOOL halListenerInstalled;
	BOOL writingSelection;
	AudioObjectPropertyListenerBlock halListenerBlock;
```

Add after `waitForFirstResultsUpTo:`:

```objc
- (NSString *)pendingDeviceName {
	return pendingName;
}

- (void)armPendingSwitchForDeviceName:(NSString *)name {
	if(![name length]) return;
	pendingName = [name copy];
	[self installHalListenerIfNeeded];
	[self installDefaultsObserverIfNeeded];
	[self checkPendingSwitch];
}

- (void)disarmPendingSwitch {
	pendingName = nil;
	if(halListenerInstalled) {
		AudioObjectPropertyAddress theAddress = {
			.mSelector = kAudioHardwarePropertyDevices,
			.mScope = kAudioObjectPropertyScopeGlobal,
			.mElement = kAudioObjectPropertyElementMaster
		};
		AudioObjectRemovePropertyListenerBlock(kAudioObjectSystemObject, &theAddress, dispatch_get_main_queue(), halListenerBlock);
		halListenerInstalled = NO;
	}
}

- (void)installHalListenerIfNeeded {
	if(halListenerInstalled) return;
	if(!halListenerBlock) {
		__weak AirPlayServiceBrowser *weakSelf = self;
		halListenerBlock = ^(UInt32 inNumberAddresses, const AudioObjectPropertyAddress *inAddresses) {
			[weakSelf checkPendingSwitch];
		};
	}
	AudioObjectPropertyAddress theAddress = {
		.mSelector = kAudioHardwarePropertyDevices,
		.mScope = kAudioObjectPropertyScopeGlobal,
		.mElement = kAudioObjectPropertyElementMaster
	};
	if(AudioObjectAddPropertyListenerBlock(kAudioObjectSystemObject, &theAddress, dispatch_get_main_queue(), halListenerBlock) == noErr) {
		halListenerInstalled = YES;
	}
}

// Any outputDevice change that we did not write ourselves supersedes the
// pending pick (covers both pickers and System Default selection).
- (void)installDefaultsObserverIfNeeded {
	static BOOL installed = NO;
	if(installed) return;
	installed = YES;
	[[NSNotificationCenter defaultCenter] addObserver:self
	                                         selector:@selector(defaultsDidChange:)
	                                             name:NSUserDefaultsDidChangeNotification
	                                           object:[NSUserDefaults standardUserDefaults]];
	lastSeenSelection = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"outputDevice"];
}

- (void)defaultsDidChange:(NSNotification *)notification {
	NSDictionary *current = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"outputDevice"];
	BOOL selectionChanged = (current != lastSeenSelection) && ![current isEqualToDictionary:lastSeenSelection ?: @{}];
	lastSeenSelection = current;
	if(selectionChanged && !writingSelection && pendingName) {
		DLog(@"Pending AirPlay switch superseded by a direct device selection");
		[self disarmPendingSwitch];
	}
}

- (void)checkPendingSwitch {
	if(!pendingName) return;
	AudioDeviceID matched = CogDeviceIDMatchingName(pendingName);
	if(matched == kAudioObjectUnknown) return;
	if(CogDeviceTransportType(matched) != kAudioDeviceTransportTypeAirPlay) return;

	DLog(@"Pending AirPlay device \"%@\" materialized as %u; switching output", pendingName, matched);
	NSString *name = pendingName;
	[self disarmPendingSwitch];
	writingSelection = YES;
	[[NSUserDefaults standardUserDefaults] setObject:@{ @"name": name, @"deviceID": @((int)matched) }
	                                          forKey:@"outputDevice"];
	writingSelection = NO;
}
```

Also add the `lastSeenSelection` ivar to the implementation block:

```objc
	NSDictionary *lastSeenSelection;
```

Note `writingSelection` is set around our own defaults write so the
`NSUserDefaultsDidChangeNotification` observer (delivered synchronously on
the posting thread — always main here) does not treat it as a superseding
selection. Also note `disarmPendingSwitch` runs before the write, so the
observer sees `pendingName == nil` regardless.

- [ ] **Step 3: Build gate**

Run: `xcodebuild -project Cog.xcodeproj -scheme Cog -configuration Debug -arch arm64 -derivedDataPath build CODE_SIGNING_ALLOWED=NO build 2>&1 | grep -E "^\*\*|error:"`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add Window/AirPlayServiceBrowser.h Window/AirPlayServiceBrowser.m
git commit -m "Auto-switch to a picked AirPlay sink once it materializes"
```

---

### Task 4: Toolbar menu integration

**Files:**
- Modify: `Window/AirPlayItem.m` (`showDeviceMenu:` and new action; import)

**Interfaces:**
- Consumes: `AirPlayServiceBrowser` API from Tasks 1 and 3; existing `enumerateOutputDevices:`, `openSoundSettings:` in `AirPlayItem.m`.
- Produces: user-visible menu behavior only.

- [ ] **Step 1: Import the browser**

In `Window/AirPlayItem.m`, after the `#import <CogAudio/OutputDeviceRouting.h>` line:

```objc
#import "AirPlayServiceBrowser.h"
```

- [ ] **Step 2: Start browsing at menu open and warm up**

In `showDeviceMenu:`, directly after the existing `routeDetector.routeDetectionEnabled = YES;` line, add:

```objc
	AirPlayServiceBrowser *serviceBrowser = [AirPlayServiceBrowser sharedBrowser];
	[serviceBrowser beginBrowsing];
	// Bounded warm-up so a cold first open can still list devices; near-zero
	// cost when results are already in from the grace window.
	[serviceBrowser waitForFirstResultsUpTo:0.7];
```

- [ ] **Step 3: Union the discovered names into the AirPlay section**

Replace the existing block (current form, after the B7 name-fallback change):

```objc
	if([airPlayItems count]) {
		for(NSMenuItem *item in airPlayItems) {
			[menu addItem:item];
		}
	} else if(routeDetector.multipleRoutesDetected) {
		// Routes exist but macOS has not materialized them as CoreAudio
		// devices yet; send the user to Sound settings to activate one.
		NSMenuItem *item = [menu addItemWithTitle:NSLocalizedString(@"Open Sound Settings…", @"") action:@selector(openSoundSettings:) keyEquivalent:@""];
		item.target = self;
	} else {
		NSMenuItem *item = [menu addItemWithTitle:NSLocalizedString(@"No AirPlay devices found", @"") action:nil keyEquivalent:@""];
		item.enabled = NO;
	}
```

with:

```objc
	// Bonjour-discovered sinks macOS has not materialized yet, minus any name
	// already present as a CoreAudio device (case/whitespace-insensitive).
	NSMutableArray<NSString *> *materializedNames = [NSMutableArray array];
	for(NSMenuItem *item in airPlayItems) {
		[materializedNames addObject:[item.title stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]].lowercaseString];
	}
	NSMutableArray<NSMenuItem *> *discoveredItems = [NSMutableArray array];
	for(NSString *name in [serviceBrowser discoveredNames]) {
		NSString *key = [name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]].lowercaseString;
		if([materializedNames containsObject:key]) continue;
		NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:name action:@selector(selectDiscoveredDevice:) keyEquivalent:@""];
		item.target = self;
		item.representedObject = name;
		if([name isEqualToString:[serviceBrowser pendingDeviceName]]) {
			item.state = NSControlStateValueMixed;
		}
		[discoveredItems addObject:item];
	}

	if([airPlayItems count] || [discoveredItems count]) {
		for(NSMenuItem *item in airPlayItems) {
			[menu addItem:item];
		}
		for(NSMenuItem *item in discoveredItems) {
			[menu addItem:item];
		}
	} else if(routeDetector.multipleRoutesDetected) {
		// Routes exist but macOS has not materialized them as CoreAudio
		// devices yet; send the user to Sound settings to activate one.
		NSMenuItem *item = [menu addItemWithTitle:NSLocalizedString(@"Open Sound Settings…", @"") action:@selector(openSoundSettings:) keyEquivalent:@""];
		item.target = self;
	} else {
		NSMenuItem *item = [menu addItemWithTitle:NSLocalizedString(@"No AirPlay devices found", @"") action:nil keyEquivalent:@""];
		item.enabled = NO;
	}
```

- [ ] **Step 4: Stop browsing when the menu closes and add the pick action**

At the end of `showDeviceMenu:`, next to the existing route-detector
generation/`dispatch_after` block (after `popUpMenuPositioningItem:` returns),
add one line:

```objc
	[serviceBrowser endBrowsingSoon];
```

Then add the new action method after `selectDevice:`:

```objc
- (void)selectDiscoveredDevice:(NSMenuItem *)sender {
	NSString *name = sender.representedObject;
	// The sink is not a CoreAudio device yet; remember the pick and send the
	// user to Sound settings to activate it. The browser switches the output
	// automatically the moment the device materializes.
	[[AirPlayServiceBrowser sharedBrowser] armPendingSwitchForDeviceName:name];
	[self openSoundSettings:sender];
}
```

- [ ] **Step 5: Build gate**

Run: `xcodebuild -project Cog.xcodeproj -scheme Cog -configuration Debug -arch arm64 -derivedDataPath build CODE_SIGNING_ALLOWED=NO build 2>&1 | grep -E "^\*\*|error:"`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 6: Commit**

```bash
git add Window/AirPlayItem.m
git commit -m "Toolbar: list Bonjour-discovered AirPlay sinks in the device menu"
```

---

### Task 5: Preferences integration

**Files:**
- Modify: `Preferences/Panes/AudioDeviceModel.swift`
- Modify: `Preferences/Panes/OutputPaneView.swift`

**Interfaces:**
- Consumes: `AirPlayServiceBrowser.sharedBrowser()`, `.beginBrowsing()`, `.endBrowsingSoon()`, `.discoveredNames`, `.armPendingSwitchForDeviceName(_:)`, `.pendingDeviceName`, and the `AirPlayServiceBrowserDidUpdateNotification` name — all via the bridging header (Task 1/3).
- Produces: user-visible Preferences behavior only.

- [ ] **Step 1: Extend `AudioDeviceModel` with discovered devices**

In `Preferences/Panes/AudioDeviceModel.swift`:

1. Extend `Device` with a flag (default keeps existing call sites valid):

```swift
    struct Device: Identifiable, Equatable {
        let id: Int      // AudioDeviceID stored as Int for UserDefaults compatibility
        let name: String
        let isAirPlay: Bool
        var isDiscoveredOnly: Bool = false   // Bonjour-only; selecting arms the pending switch
    }
```

2. At the end of `loadDevices()`, before `devices = result`, merge the
   Bonjour names using synthetic IDs below -1 (never colliding with the
   System Default sentinel `-1` or real `AudioDeviceID`s, which are
   positive):

```swift
        let materialized = Set(result.map { $0.name.trimmingCharacters(in: .whitespaces).lowercased() })
        let discovered = AirPlayServiceBrowser.shared().discoveredNames
        for (index, name) in discovered.enumerated() {
            let key = name.trimmingCharacters(in: .whitespaces).lowercased()
            if materialized.contains(key) { continue }
            result.append(Device(id: -(1000 + index), name: name, isAirPlay: true, isDiscoveredOnly: true))
        }
```

3. In the `selectedDeviceID` `didSet`, route discovered picks to the pending
   switch instead of `saveSelection()`:

```swift
    @Published var selectedDeviceID: Int = -1 {
        didSet {
            guard isActive else { return }
            if let picked = devices.first(where: { $0.id == selectedDeviceID }), picked.isDiscoveredOnly {
                AirPlayServiceBrowser.shared().armPendingSwitch(forDeviceName: picked.name)
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.sound")!)
                // Snap back to the stored selection; the browser writes the
                // real device once it materializes.
                loadSelection(from: devices)
                return
            }
            saveSelection()
        }
    }
```

   Guard against `didSet` recursion: `loadSelection` assigns
   `selectedDeviceID`, which re-enters `didSet` — but the reassigned value is
   never a discovered-only device (it comes from the stored defaults), so it
   falls through to `saveSelection()`, which rewrites the same stored value.
   That is idempotent and matches the pane's existing behavior on load.

4. Add refresh plumbing to the class (browser updates and external
   `outputDevice` writes — e.g. the pending switch firing — keep the pane
   live while it is open):

```swift
    private var observers: [NSObjectProtocol] = []

    func startObserving() {
        guard observers.isEmpty else { return }
        AirPlayServiceBrowser.shared().beginBrowsing()
        observers.append(NotificationCenter.default.addObserver(
            forName: NSNotification.Name("AirPlayServiceBrowserDidUpdateNotification"),
            object: nil, queue: .main) { [weak self] _ in self?.loadDevices() })
        observers.append(NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.loadSelection(from: self.devices)
            })
    }

    func stopObserving() {
        AirPlayServiceBrowser.shared().endBrowsingSoon()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
    }
```

   (`loadSelection` is currently `private`; leave it private — these methods
   are inside the class.)

- [ ] **Step 2: Drive the lifecycle from the view**

In `Preferences/Panes/OutputPaneView.swift`, on the `Form` inside
`formContent` (after the closing brace of the `Form { ... }` block, before
the property's closing brace):

```swift
        .onAppear { deviceModel.startObserving(); deviceModel.loadDevices() }
        .onDisappear { deviceModel.stopObserving() }
```

The AirPlay `Section` already renders whatever `devices` contains, so
discovered entries appear with no further view changes.

- [ ] **Step 3: Build gate**

Run: `xcodebuild -project Cog.xcodeproj -scheme Cog -configuration Debug -arch arm64 -derivedDataPath build CODE_SIGNING_ALLOWED=NO build 2>&1 | grep -E "^\*\*|error:"`
Expected: `** BUILD SUCCEEDED **`
(If Swift cannot see the browser class, re-check the Task 1 bridging-header
import and that the notification name string matches exactly.)

- [ ] **Step 4: Commit**

```bash
git add Preferences/Panes/AudioDeviceModel.swift Preferences/Panes/OutputPaneView.swift
git commit -m "Preferences: list Bonjour-discovered AirPlay sinks"
```

---

### Task 6: Matrix rows, ledger, universal build

**Files:**
- Modify: `docs/superpowers/handoffs/2026-07-23-airplay-2-testing-followup-handoff.md`
- Modify: `.superpowers/sdd/progress.md` (gitignored — update, do not commit)

**Interfaces:**
- Consumes: everything above.
- Produces: updated manual test matrix; CI-equivalent build proof.

- [ ] **Step 1: Append matrix rows A17–A19**

In the handoff's matrix table, after the A16 row, add:

```markdown
| A17 | **Bonjour pick: toolbar** (new) | With a sink on the network but not in Sound settings' active output, open the toolbar menu | Device listed by name; picking it opens Sound settings and shows a – marker on reopen; activating the device in Settings makes Cog switch to it automatically (log shows the device change) |
| A18 | **Bonjour pick: Preferences** (new) | Same flow via Preferences → Output | Same, including snap-back of the picker until the device materializes |
| A19 | **Local-network permission** (new) | First menu open on macOS 15+ | Permission prompt appears once; denying it leaves the menu working with the pre-Bonjour fallback behavior |
```

- [ ] **Step 2: Update the ledger**

Append to `.superpowers/sdd/progress.md` a line recording: Bonjour picker
feature implemented per `docs/superpowers/specs/2026-07-23-airplay-bonjour-picker-design.md`,
tasks 1–6 complete with per-task commits, matrix rows A17–A19 pending human
run.

- [ ] **Step 3: CI-equivalent universal build gate**

Run: `xcodebuild -project Cog.xcodeproj -scheme Cog -configuration Debug -arch x86_64 -arch arm64 -derivedDataPath build CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=NO build 2>&1 | grep -E "^\*\*|error:"`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add docs/superpowers/handoffs/2026-07-23-airplay-2-testing-followup-handoff.md
git commit -m "Add Bonjour picker rows to the AirPlay test matrix"
```
