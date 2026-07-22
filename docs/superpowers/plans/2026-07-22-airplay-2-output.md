# AirPlay 2 Output Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** True AirPlay 2 streaming from Cog via a second output backend (`OutputAirPlay`, built on `AVSampleBufferAudioRenderer`) that engages automatically when the selected output device's CoreAudio transport type is AirPlay, plus an AirPlay toolbar button with a device menu.

**Architecture:** A `CogOutput` protocol abstracts the backend interface `OutputNode` uses. `OutputCoreAudio` conforms unchanged (wired path untouched). New `OutputAirPlay` is a push-model output: a feeder thread pulls chunks through a downmix→fader→buffer tail-node chain and enqueues `CMSampleBuffer`s into an `AVSampleBufferAudioRenderer` under an `AVSampleBufferRenderSynchronizer`, targeting the AirPlay device by CoreAudio UID. `OutputNode` picks the backend class from the selected device's transport type; `AudioPlayer` restarts playback when a device change crosses the transport boundary. Spec: `docs/superpowers/specs/2026-07-22-airplay-2-output-design.md`.

**Tech Stack:** Objective-C, AVFoundation (`AVSampleBufferAudioRenderer`, `AVSampleBufferRenderSynchronizer`, `AVRouteDetector`), CoreAudio, CoreMedia, AppKit, SwiftUI (Preferences pane).

## Global Constraints

- Deployment target is macOS **10.15**: guard macOS 11+ API (`NSImage imageWithSystemSymbolName:`) with `@available` and provide a fallback.
- Indent with **real tabs** (`.clang-format`: LLVM base, `IndentWidth: 4`, `UseTab: ForIndentation`, `ColumnLimit: 0`). Match surrounding style exactly.
- User-facing strings go through `NSLocalizedString` and `Localizable.xcstrings`.
- **Never** commit a Development Team ID. Never commit the untracked `CLAUDE.md` or `graphify-out/` at repo root.
- Commit messages: plain, no Claude/co-author signature lines (explicit user requirement for this repo).
- There is **no unit-test suite** in this repo. The red/green cycle for every task is the build:
  ```sh
  xcodebuild -project Cog.xcodeproj -scheme Cog -configuration Debug -arch arm64 -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
  ```
  Expected: `** BUILD SUCCEEDED **`. (Task 7 does the universal two-arch build.)
- First-time setup must already be done (submodules, `ThirdParty/libraries.tar.xz` extracted). If the build fails with missing third-party libraries, run the setup from CLAUDE.md first.
- Spatial audio is out of scope: never set `allowedAudioSpatializationFormats`.
- `Audio/Output/OutputAVFoundation.m/h` are orphaned reference material until Task 7 deletes them. Read them for patterns; do not add them to any target; do not copy their in-output DSP (resampler/HRTF/FreeSurround/EQ) — that lives in chain nodes now.

---

### Task 1: `CogOutput` protocol and generic `OutputNode`

**Files:**
- Create: `Audio/Output/CogOutput.h`
- Modify: `Audio/Chain/OutputNode.h` (ivar type + import)
- Modify: `Audio/Output/OutputCoreAudio.h` (declare conformance)
- Modify: `Audio/CogAudio.xcodeproj/project.pbxproj` (add public header)

**Interfaces:**
- Consumes: existing `OutputCoreAudio` API (`Audio/Output/OutputCoreAudio.h:133-167`), existing `OutputNode` forwarding (`Audio/Chain/OutputNode.m`).
- Produces: `@protocol CogOutput` — the exact backend contract later tasks implement. `OutputNode`'s `output` ivar becomes `Node<CogOutput> *`. Task 3's `OutputAirPlay` and Task 4's selection logic depend on this protocol existing with these exact selectors.

- [ ] **Step 1: Write `Audio/Output/CogOutput.h`**

```objc
//
//  CogOutput.h
//  CogAudio
//
//  The backend contract OutputNode drives. OutputCoreAudio (low-latency
//  wired playback) and OutputAirPlay (buffered AirPlay playback) conform.
//

#import <CoreAudio/CoreAudioTypes.h>
#import <Foundation/Foundation.h>

@class OutputNode;
@class DSPDownmixNode;
@class DSPFaderNode;

@protocol CogOutput <NSObject>

- (id _Nullable)initWithController:(OutputNode *_Nonnull)c;

- (BOOL)setup;
- (void)start;
- (void)stop;
- (void)pause;
- (void)resume;

- (void)fadeOut;
- (void)fadeOutBackground;
- (void)beginSeek;
- (void)fadeIn;
- (void)faderFadeIn;

- (void)timeOut;

- (double)latency;

- (double)volume;
- (void)setVolume:(double)v;

- (void)setShouldPlayOutBuffer:(BOOL)enabled;

- (void)sustainHDCD;

- (AudioStreamBasicDescription)deviceFormat;
- (uint32_t)deviceChannelConfig;
- (AudioStreamBasicDescription)outputFormatForInputFormat:(AudioStreamBasicDescription)inputFormat;
- (BOOL)prepareForInputFormat:(AudioStreamBasicDescription)inputFormat;

- (DSPDownmixNode *_Nullable)downmix;
- (DSPFaderNode *_Nullable)fader;

@end
```

- [ ] **Step 2: Declare conformance in `Audio/Output/OutputCoreAudio.h`**

Add the import below the existing `#import <CogAudio/SimpleBuffer.h>` line:

```objc
#import <CogAudio/CogOutput.h>
```

Change the interface line:

```objc
// old
@interface OutputCoreAudio : Node {
// new
@interface OutputCoreAudio : Node <CogOutput> {
```

No implementation changes — every protocol method already exists on `OutputCoreAudio`.

- [ ] **Step 3: Genericize `Audio/Chain/OutputNode.h`**

Replace the import:

```objc
// old
#import <CogAudio/OutputCoreAudio.h>
// new
#import <CogAudio/CogOutput.h>
```

Replace the ivar:

```objc
// old
	OutputCoreAudio *output;
// new
	Node<CogOutput> *output;
```

`Audio/Chain/OutputNode.m` already imports `"OutputCoreAudio.h"` directly (line 12) — leave that; the alloc line `output = [[OutputCoreAudio alloc] initWithController:self];` compiles as-is against the new ivar type.

- [ ] **Step 4: Add `CogOutput.h` to the CogAudio project as a Public header**

Edit `Audio/CogAudio.xcodeproj/project.pbxproj`, four insertions (anchor on the existing `OutputCoreAudio` entries):

1. In the `PBXBuildFile` section, directly after the line containing `835DD2682ACAF1D90057E319 /* OutputCoreAudio.h in Headers */`:
```
		A1A0C0DE2E3700000000A002 /* CogOutput.h in Headers */ = {isa = PBXBuildFile; fileRef = A1A0C0DE2E3700000000A001 /* CogOutput.h */; settings = {ATTRIBUTES = (Public, ); }; };
```
2. In the `PBXFileReference` section, directly after the line containing `835DD2662ACAF1D90057E319 /* OutputCoreAudio.h */ = {isa = PBXFileReference;`:
```
		A1A0C0DE2E3700000000A001 /* CogOutput.h */ = {isa = PBXFileReference; fileEncoding = 4; lastKnownFileType = sourcecode.c.h; path = CogOutput.h; sourceTree = "<group>"; };
```
3. In the group listing `Output` children (the block containing both `835DD2662ACAF1D90057E319 /* OutputCoreAudio.h */,` and `835DD2652ACAF1D90057E319 /* OutputCoreAudio.m */,`), add:
```
				A1A0C0DE2E3700000000A001 /* CogOutput.h */,
```
4. In the `Headers` build phase (the block containing `835DD2682ACAF1D90057E319 /* OutputCoreAudio.h in Headers */,`), add:
```
				A1A0C0DE2E3700000000A002 /* CogOutput.h in Headers */,
```

- [ ] **Step 5: Build**

Run the Global Constraints build command. Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add Audio/Output/CogOutput.h Audio/Output/OutputCoreAudio.h Audio/Chain/OutputNode.h Audio/CogAudio.xcodeproj/project.pbxproj
git commit -m "Output: introduce CogOutput backend protocol"
```

---

### Task 2: AirPlay device-routing helpers

**Files:**
- Create: `Audio/Output/OutputDeviceRouting.h`
- Create: `Audio/Output/OutputDeviceRouting.m`
- Modify: `Audio/CogAudio.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: CoreAudio HAL property API only.
- Produces (C functions, public CogAudio header — Task 4's backend selection, Task 5's toolbar item, and Task 3's device targeting all call these):
  - `UInt32 CogDeviceTransportType(AudioDeviceID deviceID)` — `kAudioDevicePropertyTransportType` value, `0` on failure.
  - `OSStatus CogResolveDefaultOutputDevice(AudioDeviceID *outDeviceID)` — system default output device.
  - `NSString *_Nullable CogDeviceUID(AudioDeviceID deviceID)` — `kAudioDevicePropertyDeviceUID`, nil on failure.
  - `BOOL CogOutputDeviceDictIsAirPlay(NSDictionary *_Nullable deviceDict)` — resolves the `outputDevice` defaults dict (`{"name": String, "deviceID": Int}`; nil or `deviceID == -1` means system default; dead IDs fall back to name match, then default) and answers whether the effective device transport is `kAudioDeviceTransportTypeAirPlay`.

- [ ] **Step 1: Write `Audio/Output/OutputDeviceRouting.h`**

```objc
//
//  OutputDeviceRouting.h
//  CogAudio
//
//  CoreAudio helpers for resolving output devices and detecting AirPlay
//  transports, shared by the output backends and the app UI.
//

#import <CoreAudio/AudioHardware.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

UInt32 CogDeviceTransportType(AudioDeviceID deviceID);
OSStatus CogResolveDefaultOutputDevice(AudioDeviceID *outDeviceID);
NSString *_Nullable CogDeviceUID(AudioDeviceID deviceID);
BOOL CogOutputDeviceDictIsAirPlay(NSDictionary *_Nullable deviceDict);

NS_ASSUME_NONNULL_END
```

- [ ] **Step 2: Write `Audio/Output/OutputDeviceRouting.m`**

```objc
//
//  OutputDeviceRouting.m
//  CogAudio
//

#import "OutputDeviceRouting.h"

UInt32 CogDeviceTransportType(AudioDeviceID deviceID) {
	AudioObjectPropertyAddress theAddress = {
		.mSelector = kAudioDevicePropertyTransportType,
		.mScope = kAudioObjectPropertyScopeGlobal,
		.mElement = kAudioObjectPropertyElementMaster
	};

	UInt32 transportType = 0;
	UInt32 size = sizeof(transportType);
	OSStatus err = AudioObjectGetPropertyData(deviceID, &theAddress, 0, NULL, &size, &transportType);
	if(err != noErr) {
		return 0;
	}
	return transportType;
}

OSStatus CogResolveDefaultOutputDevice(AudioDeviceID *outDeviceID) {
	AudioObjectPropertyAddress theAddress = {
		.mSelector = kAudioHardwarePropertyDefaultOutputDevice,
		.mScope = kAudioObjectPropertyScopeGlobal,
		.mElement = kAudioObjectPropertyElementMaster
	};

	UInt32 size = sizeof(AudioDeviceID);
	return AudioObjectGetPropertyData(kAudioObjectSystemObject, &theAddress, 0, NULL, &size, outDeviceID);
}

NSString *CogDeviceUID(AudioDeviceID deviceID) {
	AudioObjectPropertyAddress theAddress = {
		.mSelector = kAudioDevicePropertyDeviceUID,
		.mScope = kAudioObjectPropertyScopeGlobal,
		.mElement = kAudioObjectPropertyElementMaster
	};

	CFStringRef deviceUID = NULL;
	UInt32 size = sizeof(deviceUID);
	OSStatus err = AudioObjectGetPropertyData(deviceID, &theAddress, 0, NULL, &size, &deviceUID);
	if(err != noErr || !deviceUID) {
		return nil;
	}
	return (NSString *)CFBridgingRelease(deviceUID);
}

static BOOL deviceIsAlive(AudioDeviceID deviceID) {
	AudioObjectPropertyAddress theAddress = {
		.mSelector = kAudioDevicePropertyDeviceIsAlive,
		.mScope = kAudioDevicePropertyScopeOutput,
		.mElement = kAudioObjectPropertyElementMaster
	};

	UInt32 isAlive = 0;
	UInt32 size = sizeof(isAlive);
	OSStatus err = AudioObjectGetPropertyData(deviceID, &theAddress, 0, NULL, &size, &isAlive);
	return err == noErr && isAlive;
}

static AudioDeviceID deviceIDMatchingName(NSString *name) {
	if(![name length]) {
		return kAudioObjectUnknown;
	}

	AudioObjectPropertyAddress theAddress = {
		.mSelector = kAudioHardwarePropertyDevices,
		.mScope = kAudioObjectPropertyScopeGlobal,
		.mElement = kAudioObjectPropertyElementMaster
	};

	UInt32 propsize = 0;
	if(AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &theAddress, 0, NULL, &propsize) != noErr) {
		return kAudioObjectUnknown;
	}

	UInt32 nDevices = propsize / (UInt32)sizeof(AudioDeviceID);
	AudioDeviceID *devids = (AudioDeviceID *)malloc(propsize);
	if(!devids) {
		return kAudioObjectUnknown;
	}
	if(AudioObjectGetPropertyData(kAudioObjectSystemObject, &theAddress, 0, NULL, &propsize, devids) != noErr) {
		free(devids);
		return kAudioObjectUnknown;
	}

	AudioDeviceID found = kAudioObjectUnknown;
	for(UInt32 i = 0; i < nDevices; ++i) {
		CFStringRef deviceName = NULL;
		UInt32 size = sizeof(deviceName);
		theAddress.mSelector = kAudioDevicePropertyDeviceNameCFString;
		theAddress.mScope = kAudioDevicePropertyScopeOutput;
		if(AudioObjectGetPropertyData(devids[i], &theAddress, 0, NULL, &size, &deviceName) != noErr || !deviceName) {
			continue;
		}
		BOOL matches = [name isEqualToString:(__bridge NSString *)deviceName];
		CFRelease(deviceName);
		if(matches) {
			found = devids[i];
			break;
		}
	}

	free(devids);
	return found;
}

BOOL CogOutputDeviceDictIsAirPlay(NSDictionary *deviceDict) {
	AudioDeviceID deviceID = kAudioObjectUnknown;

	NSNumber *deviceIDNum = deviceDict ? [deviceDict objectForKey:@"deviceID"] : nil;
	int storedID = deviceIDNum ? [deviceIDNum intValue] : -1;

	if(storedID != -1) {
		if(deviceIsAlive((AudioDeviceID)storedID)) {
			deviceID = (AudioDeviceID)storedID;
		} else {
			deviceID = deviceIDMatchingName([deviceDict objectForKey:@"name"]);
		}
	}

	if(deviceID == kAudioObjectUnknown) {
		if(CogResolveDefaultOutputDevice(&deviceID) != noErr) {
			return NO;
		}
	}

	return CogDeviceTransportType(deviceID) == kAudioDeviceTransportTypeAirPlay;
}
```

- [ ] **Step 3: Add both files to the CogAudio project**

Edit `Audio/CogAudio.xcodeproj/project.pbxproj` (same four anchor points as Task 1 Step 4):

1. `PBXBuildFile` section, after the `CogOutput.h in Headers` line added in Task 1:
```
		A1A0C0DE2E3700000000A004 /* OutputDeviceRouting.h in Headers */ = {isa = PBXBuildFile; fileRef = A1A0C0DE2E3700000000A003 /* OutputDeviceRouting.h */; settings = {ATTRIBUTES = (Public, ); }; };
		A1A0C0DE2E3700000000A006 /* OutputDeviceRouting.m in Sources */ = {isa = PBXBuildFile; fileRef = A1A0C0DE2E3700000000A005 /* OutputDeviceRouting.m */; };
```
2. `PBXFileReference` section, after the `CogOutput.h` file reference:
```
		A1A0C0DE2E3700000000A003 /* OutputDeviceRouting.h */ = {isa = PBXFileReference; fileEncoding = 4; lastKnownFileType = sourcecode.c.h; path = OutputDeviceRouting.h; sourceTree = "<group>"; };
		A1A0C0DE2E3700000000A005 /* OutputDeviceRouting.m */ = {isa = PBXFileReference; fileEncoding = 4; lastKnownFileType = sourcecode.c.objc; path = OutputDeviceRouting.m; sourceTree = "<group>"; };
```
3. Output group children:
```
				A1A0C0DE2E3700000000A003 /* OutputDeviceRouting.h */,
				A1A0C0DE2E3700000000A005 /* OutputDeviceRouting.m */,
```
4. `Headers` phase: `A1A0C0DE2E3700000000A004 /* OutputDeviceRouting.h in Headers */,` — and in the `Sources` phase (the block containing `835DD2672ACAF1D90057E319 /* OutputCoreAudio.m in Sources */,`), add:
```
				A1A0C0DE2E3700000000A006 /* OutputDeviceRouting.m in Sources */,
```

- [ ] **Step 4: Build**

Run the Global Constraints build command. Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add Audio/Output/OutputDeviceRouting.h Audio/Output/OutputDeviceRouting.m Audio/CogAudio.xcodeproj/project.pbxproj
git commit -m "Output: add AirPlay device routing helpers"
```

---

### Task 3: `OutputAirPlay` backend

**Files:**
- Create: `Audio/Output/OutputAirPlay.h`
- Create: `Audio/Output/OutputAirPlay.m`
- Modify: `Audio/CogAudio.xcodeproj/project.pbxproj`
- Reference (read-only): `Audio/Output/OutputAVFoundation.m` (renderer lifecycle patterns), `Audio/Output/OutputCoreAudio.m` (tail-node/thread patterns)

**Interfaces:**
- Consumes: `CogOutput` protocol (Task 1), `CogDeviceUID` (Task 2), `Node`/`ChunkList`/`AudioChunk` chain API (`readChunk:`, `peekFormat:channelConfig:`, `removeSamples:`, `addChunk:`, `listDuration`, `isFull`, `isEmpty`), tail DSP nodes `DSPDownmixNode`, `DSPFaderNode`, `SimpleBuffer`, `VisualizationController` (`postLatency:`/`postFullLatency:`/`reset`), `OutputNode` controller callbacks (`shouldContinue`, `shouldReset`, `setShouldReset:`, `endOfStream`, `selectNextBuffer`, `endOfInputPlayed`, `resetAmountPlayed`, `setAmountPlayed:`, `getVisLatency`, `getTotalLatency`, `setFormat:channelConfig:`, `peekFormat:channelConfig:`, `readChunk:`).
- Produces: `OutputAirPlay : Node <CogOutput>` — instantiated by Task 4 via `[[backendClass alloc] initWithController:self]`. PCM only: `outputFormatForInputFormat:` never advertises a DoP carrier rate (DSD input → decimated PCM rate `inputRate/8`, clamped to 192 kHz), so `ConverterNode`'s existing check (`ConverterNode.m:460`) always takes the `DSD_DECIMATE` path.

- [ ] **Step 1: Write `Audio/Output/OutputAirPlay.h`**

```objc
//
//  OutputAirPlay.h
//  CogAudio
//
//  Buffered AirPlay output backend. Push model: a feeder thread pulls
//  chunks through downmix -> fader -> buffer tail nodes and enqueues
//  CMSampleBuffers into an AVSampleBufferAudioRenderer targeting the
//  selected AirPlay device by CoreAudio UID. Roughly 2 seconds of audio
//  stay in flight; only AirPlay routes ever use this backend, so wired
//  playback never pays that latency.
//

#import <AVFoundation/AVFoundation.h>
#import <Cocoa/Cocoa.h>
#import <CoreAudio/AudioHardware.h>
#import <CoreMedia/CoreMedia.h>

#import <CogAudio/ChunkList.h>
#import <CogAudio/CogOutput.h>
#import <CogAudio/DSPDownmixNode.h>
#import <CogAudio/DSPFaderNode.h>
#import <CogAudio/Node.h>
#import <CogAudio/SimpleBuffer.h>

@class OutputNode;
@class AudioChunk;

@interface OutputAirPlay : Node <CogOutput> {
	OutputNode *outputController;

	NSLock *outputLock;
	NSLock *currentPtsLock;

	BOOL stopInvoked;
	BOOL stopCompleted;
	BOOL running;
	BOOL stopping;
	BOOL stopped;
	BOOL started;
	BOOL paused;
	BOOL restarted;
	BOOL commandStop;

	BOOL cutOffInput;
	BOOL faded;
	BOOL pendingFlush;
	BOOL shouldPlayOutBuffer;

	BOOL streamFormatStarted;
	BOOL streamFormatChanged;
	BOOL resetStreamFormat;

	BOOL prebufferReached;
	BOOL prebufferSignaled;

	BOOL defaultdevicelistenerapplied;
	BOOL currentdevicelistenerapplied;
	BOOL devicealivelistenerapplied;
	BOOL observersapplied;
	BOOL rendererStatusObserverApplied;
	BOOL outputdevicechanged;

	BOOL DSPsLaunched;

	double streamTimestamp;
	double lastEnqueuedStreamTimestamp;
	double secondsLatency;
	double secondsHdcdSustained;

	float volume;

	AudioDeviceID outputDeviceID;
	AudioStreamBasicDescription deviceFormat;
	AudioStreamBasicDescription realStreamFormat;
	AudioStreamBasicDescription streamFormat;
	AudioStreamBasicDescription descriptionFormat;
	uint32_t deviceChannelConfig;
	uint32_t realStreamChannelConfig;
	uint32_t streamChannelConfig;
	uint32_t descriptionChannelConfig;

	CMAudioFormatDescriptionRef audioFormatDescription;
	AVSampleBufferAudioRenderer *audioRenderer;
	AVSampleBufferRenderSynchronizer *renderSynchronizer;
	id currentPtsObserver;
	CMTime currentPts;
	CMTime lastPts;
	CMTime outputPts;

	DSPDownmixNode *downmixNode;
	DSPFaderNode *faderNode;
	SimpleBuffer *bufferNode;
}

- (id)initWithController:(OutputNode *)c;

- (BOOL)setup;
- (OSStatus)setOutputDeviceByID:(int)deviceID;
- (BOOL)setOutputDeviceWithDeviceDict:(NSDictionary *)deviceDict;
- (void)start;
- (void)pause;
- (void)resume;
- (void)stop;

- (void)fadeOut;
- (void)fadeOutBackground;
- (void)beginSeek;
- (void)fadeIn;
- (void)faderFadeIn;

- (void)timeOut;

- (double)latency;

- (double)volume;
- (void)setVolume:(double)v;

- (void)setShouldPlayOutBuffer:(BOOL)enabled;

- (void)sustainHDCD;

- (AudioStreamBasicDescription)deviceFormat;
- (uint32_t)deviceChannelConfig;
- (AudioStreamBasicDescription)outputFormatForInputFormat:(AudioStreamBasicDescription)inputFormat;
- (BOOL)prepareForInputFormat:(AudioStreamBasicDescription)inputFormat;

- (DSPDownmixNode *)downmix;
- (DSPFaderNode *)fader;

@end
```

- [ ] **Step 2: Write `Audio/Output/OutputAirPlay.m` — part 1 (init, input side, device routing)**

Start the file with:

```objc
//
//  OutputAirPlay.m
//  CogAudio
//

#import "OutputAirPlay.h"
#import "OutputDeviceRouting.h"
#import "OutputNode.h"

#import "Logging.h"

#import <CogAudio/VisualizationController.h>

static NSNotificationName CogPlaybackDidPrebufferNotification = @"CogPlaybackDidPrebufferNotification";

static void *kOutputAirPlayContext = &kOutputAirPlayContext;

// AirPlay wants depth for dropout resistance and multi-room sync. Local
// listeners never route through this backend, so nobody else pays for it.
static const double kAirPlayMaxBufferedSeconds = 2.0;

static BOOL playbackFadesEnabled(void) {
	NSNumber *enabled = [[NSUserDefaults standardUserDefaults] objectForKey:@"enableFading"];
	return !enabled || [enabled boolValue];
}

static uint32_t configForChannelCount(uint32_t channels) {
	switch(channels) {
		case 1: return AudioConfigMono;
		case 2: return AudioConfigStereo;
		case 3: return AudioConfig3Point0;
		case 4: return AudioConfig4Point0;
		case 5: return AudioConfig5Point0;
		case 6: return AudioConfig5Point1;
		case 7: return AudioConfig6Point1;
		case 8: return AudioConfig7Point1;
		default: return AudioConfigStereo;
	}
}

@implementation OutputAirPlay {
	VisualizationController *visController;
}

- (id)initWithController:(OutputNode *)c {
	self = [super init];
	if(self) {
		buffer = [[ChunkList alloc] initWithMaximumDuration:0.5];
		writeSemaphore = [Semaphore new];
		readSemaphore = [Semaphore new];

		outputController = c;
		volume = 1.0;
		outputDeviceID = -1;

		secondsHdcdSustained = 0;

		outputLock = [NSLock new];
		currentPtsLock = [NSLock new];
	}

	return self;
}

static OSStatus
airplay_default_device_changed(AudioObjectID inObjectID, UInt32 inNumberAddresses, const AudioObjectPropertyAddress *inAddresses, void *inUserData) {
	OutputAirPlay *_self = (__bridge OutputAirPlay *)inUserData;
	return [_self setOutputDeviceByID:-1];
}

static OSStatus
airplay_current_device_listener(AudioObjectID inObjectID, UInt32 inNumberAddresses, const AudioObjectPropertyAddress *inAddresses, void *inUserData) {
	OutputAirPlay *_self = (__bridge OutputAirPlay *)inUserData;
	for(UInt32 i = 0; i < inNumberAddresses; ++i) {
		switch(inAddresses[i].mSelector) {
			case kAudioDevicePropertyDeviceIsAlive:
				return [_self setOutputDeviceByID:-1];
		}
	}
	return noErr;
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
	if(context != kOutputAirPlayContext) {
		[super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
		return;
	}

	if([keyPath isEqualToString:@"values.outputDevice"]) {
		NSDictionary *device = [[[NSUserDefaultsController sharedUserDefaultsController] defaults] objectForKey:@"outputDevice"];

		[self setOutputDeviceWithDeviceDict:device];
	} else if([keyPath isEqualToString:@"status"]) {
		if(audioRenderer && [audioRenderer status] == AVQueuedSampleBufferRenderingStatusFailed) {
			ALog(@"AirPlay renderer failed: %@", [audioRenderer error]);
			// Fall back to the system default device. This retriggers device
			// observers everywhere, including the backend re-selection in
			// AudioPlayer if the default route is not AirPlay.
			dispatch_async(dispatch_get_main_queue(), ^{
				[[[NSUserDefaultsController sharedUserDefaultsController] defaults] removeObjectForKey:@"outputDevice"];
			});
		}
	}
}

- (AudioChunk *)renderInput:(int)amountToRead {
	if(stopping == YES || [outputController shouldContinue] == NO) {
		// Chain is dead, fill out the serial number pointer forever with silence
		stopping = YES;
		return [AudioChunk new];
	}

	AudioStreamBasicDescription format;
	uint32_t config;
	if([outputController peekFormat:&format channelConfig:&config]) {
		if(!streamFormatStarted || config != realStreamChannelConfig || memcmp(&realStreamFormat, &format, sizeof(format)) != 0) {
			realStreamFormat = format;
			realStreamChannelConfig = config;
			streamFormatStarted = YES;
			streamFormatChanged = YES;
		}
	}

	if(streamFormatChanged) {
		return [AudioChunk new];
	}

	return [outputController readChunk:amountToRead];
}

- (void)updateStreamFormat {
	resetStreamFormat = NO;

	streamFormat = realStreamFormat;
	streamChannelConfig = realStreamChannelConfig;
}

- (BOOL)signalEndOfStream:(double)latency {
	stopped = YES;
	BOOL ret = [outputController selectNextBuffer];
	stopped = ret;
	if(!stopping) {
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(NSEC_PER_SEC * latency)), dispatch_get_main_queue(), ^{
			if(!self->stopping) {
				[self->outputController endOfInputPlayed];
				[self->outputController resetAmountPlayed];
			}
		});
	}
	return ret;
}

- (BOOL)processEndOfStream {
	if(stopping || ([outputController endOfStream] == YES && [self signalEndOfStream:[outputController getTotalLatency]])) {
		stopping = YES;
		return YES;
	}
	return NO;
}

- (void)renderAndConvert {
	if(resetStreamFormat) {
		[self updateStreamFormat];
		if([self processEndOfStream]) {
			return;
		}
	}

	AudioChunk *chunk = [self renderInput:512];
	size_t frameCount = 0;
	if(chunk && (frameCount = [chunk frameCount])) {
		[outputLock lock];
		[buffer addChunk:chunk];
		[outputLock unlock];
		[readSemaphore signal];
	}

	if(streamFormatChanged) {
		streamFormatChanged = NO;
		if(frameCount) {
			resetStreamFormat = YES;
		} else {
			[self updateStreamFormat];
		}
	}
	[self processEndOfStream];
}
```

Then append the device-routing methods. `setOutputDeviceByID:` follows `OutputCoreAudio.m:257-337` exactly (same listener bookkeeping with the `airplay_`-prefixed callbacks) with one difference — instead of `[_au setDeviceID:...]`, target the renderer by UID:

```objc
- (OSStatus)setOutputDeviceByID:(int)deviceIDIn {
	OSStatus err;
	BOOL defaultDevice = NO;
	AudioObjectPropertyAddress theAddress = {
		.mSelector = kAudioHardwarePropertyDefaultOutputDevice,
		.mScope = kAudioObjectPropertyScopeGlobal,
		.mElement = kAudioObjectPropertyElementMaster
	};

	AudioDeviceID deviceID = (AudioDeviceID)deviceIDIn;

	if(deviceIDIn == -1) {
		defaultDevice = YES;
		err = CogResolveDefaultOutputDevice(&deviceID);

		if(err != noErr) {
			DLog(@"THERE'S NO DEFAULT OUTPUT DEVICE");

			return err;
		}
	}

	if(audioRenderer) {
		if(defaultdevicelistenerapplied && !defaultDevice) {
			AudioObjectRemovePropertyListener(kAudioObjectSystemObject, &theAddress, airplay_default_device_changed, (__bridge void *_Nullable)(self));
			defaultdevicelistenerapplied = NO;
		}

		outputdevicechanged = NO;

		if(outputDeviceID != deviceID) {
			if(currentdevicelistenerapplied) {
				if(devicealivelistenerapplied) {
					theAddress.mSelector = kAudioDevicePropertyDeviceIsAlive;
					AudioObjectRemovePropertyListener(outputDeviceID, &theAddress, airplay_current_device_listener, (__bridge void *_Nullable)(self));
					devicealivelistenerapplied = NO;
				}
				currentdevicelistenerapplied = NO;
			}

			DLog(@"AirPlay output device: %i\n", deviceID);
			outputDeviceID = deviceID;

			NSString *deviceUID = CogDeviceUID(outputDeviceID);
			if(!deviceUID) {
				DLog(@"Unable to get UID of device");
				return -1;
			}

			[audioRenderer setAudioOutputDeviceUniqueID:deviceUID];

			outputdevicechanged = YES;
		}

		if(!currentdevicelistenerapplied) {
			if(!devicealivelistenerapplied && !defaultDevice) {
				theAddress.mSelector = kAudioDevicePropertyDeviceIsAlive;
				AudioObjectAddPropertyListener(outputDeviceID, &theAddress, airplay_current_device_listener, (__bridge void *_Nullable)(self));
				devicealivelistenerapplied = YES;
			}
			currentdevicelistenerapplied = YES;
		}

		if(!defaultdevicelistenerapplied && defaultDevice) {
			theAddress.mSelector = kAudioHardwarePropertyDefaultOutputDevice;
			AudioObjectAddPropertyListener(kAudioObjectSystemObject, &theAddress, airplay_default_device_changed, (__bridge void *_Nullable)(self));
			defaultdevicelistenerapplied = YES;
		}
	}

	return noErr;
}

- (BOOL)setOutputDeviceWithDeviceDict:(NSDictionary *)deviceDict {
	NSNumber *deviceIDNum = deviceDict ? [deviceDict objectForKey:@"deviceID"] : @(-1);
	int outputDeviceIDIn = deviceIDNum ? [deviceIDNum intValue] : -1;

	OSStatus err = [self setOutputDeviceByID:outputDeviceIDIn];

	if(err != noErr) {
		// Try matching by name.
		NSString *userDeviceName = deviceDict[@"name"];
		AudioDeviceID matched = kAudioObjectUnknown;
		if([userDeviceName length]) {
			AudioObjectPropertyAddress theAddress = {
				.mSelector = kAudioHardwarePropertyDevices,
				.mScope = kAudioObjectPropertyScopeGlobal,
				.mElement = kAudioObjectPropertyElementMaster
			};
			UInt32 propsize = 0;
			if(AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &theAddress, 0, NULL, &propsize) == noErr) {
				UInt32 nDevices = propsize / (UInt32)sizeof(AudioDeviceID);
				AudioDeviceID *devids = (AudioDeviceID *)malloc(propsize);
				if(devids && AudioObjectGetPropertyData(kAudioObjectSystemObject, &theAddress, 0, NULL, &propsize, devids) == noErr) {
					for(UInt32 i = 0; i < nDevices; ++i) {
						CFStringRef name = NULL;
						UInt32 size = sizeof(name);
						theAddress.mSelector = kAudioDevicePropertyDeviceNameCFString;
						theAddress.mScope = kAudioDevicePropertyScopeOutput;
						if(AudioObjectGetPropertyData(devids[i], &theAddress, 0, NULL, &size, &name) != noErr || !name) {
							theAddress.mSelector = kAudioHardwarePropertyDevices;
							theAddress.mScope = kAudioObjectPropertyScopeGlobal;
							continue;
						}
						BOOL matches = [userDeviceName isEqualToString:(__bridge NSString *)name];
						CFRelease(name);
						theAddress.mSelector = kAudioHardwarePropertyDevices;
						theAddress.mScope = kAudioObjectPropertyScopeGlobal;
						if(matches) {
							matched = devids[i];
							break;
						}
					}
				}
				if(devids) free(devids);
			}
		}
		if(matched != kAudioObjectUnknown) {
			err = [self setOutputDeviceByID:(int)matched];
			DLog(@"Found output device: \"%@\" (%d).", userDeviceName, matched);
		}
	}

	if(err != noErr) {
		ALog(@"No output device could be found, your random error code is %d. Have a nice day!", err);

		return NO;
	}

	return YES;
}
```

(Note: unlike `OutputCoreAudio`, no `kAudioDevicePropertyStreamFormat`/`NominalSampleRate` listeners — the renderer owns format conversion, only device-alive matters.)

- [ ] **Step 3: Write `Audio/Output/OutputAirPlay.m` — part 2 (formats, sample buffers, feeder thread)**

Append:

```objc
- (AudioStreamBasicDescription)outputFormatForInputFormat:(AudioStreamBasicDescription)inputFormat {
	AudioStreamBasicDescription outputFormat;
	bzero(&outputFormat, sizeof(outputFormat));

	double sampleRate = inputFormat.mSampleRate;
	if(inputFormat.mBitsPerChannel == 1) {
		// DSD input: advertise the decimated PCM rate, never a DoP carrier
		// rate, so ConverterNode always takes the DSD_DECIMATE path.
		sampleRate = inputFormat.mSampleRate / 8.0;
	}
	if(sampleRate > 192000.0) sampleRate = 192000.0;
	if(sampleRate < 8000.0) sampleRate = 8000.0;

	uint32_t channels = inputFormat.mChannelsPerFrame;
	if(channels > 8) channels = 8;
	if(!channels) channels = 2;

	outputFormat.mSampleRate = sampleRate;
	outputFormat.mFormatID = kAudioFormatLinearPCM;
	outputFormat.mFormatFlags = kAudioFormatFlagsNativeFloatPacked;
	outputFormat.mBitsPerChannel = 32;
	outputFormat.mChannelsPerFrame = channels;
	outputFormat.mFramesPerPacket = 1;
	outputFormat.mBytesPerFrame = (UInt32)(sizeof(float) * channels);
	outputFormat.mBytesPerPacket = outputFormat.mBytesPerFrame;

	return outputFormat;
}

- (BOOL)prepareForInputFormat:(AudioStreamBasicDescription)inputFormat {
	deviceFormat = [self outputFormatForInputFormat:inputFormat];
	deviceChannelConfig = configForChannelCount(deviceFormat.mChannelsPerFrame);
	return YES;
}

- (BOOL)updateFormatDescriptionForFormat:(AudioStreamBasicDescription)fmt channelConfig:(uint32_t)config {
	if(audioFormatDescription && memcmp(&descriptionFormat, &fmt, sizeof(fmt)) == 0 && descriptionChannelConfig == config) {
		return YES;
	}

	AudioChannelLayoutTag tag = 0;
	AudioChannelLayout layout = { 0 };
	switch(config) {
		case AudioConfigMono:
			tag = kAudioChannelLayoutTag_Mono;
			break;
		case AudioConfigStereo:
			tag = kAudioChannelLayoutTag_Stereo;
			break;
		case AudioConfig3Point0:
			tag = kAudioChannelLayoutTag_WAVE_3_0;
			break;
		case AudioConfig4Point0:
			tag = kAudioChannelLayoutTag_WAVE_4_0_A;
			break;
		case AudioConfig5Point0:
			tag = kAudioChannelLayoutTag_WAVE_5_0_A;
			break;
		case AudioConfig5Point1:
			tag = kAudioChannelLayoutTag_WAVE_5_1_A;
			break;
		case AudioConfig6Point1:
			tag = kAudioChannelLayoutTag_WAVE_6_1;
			break;
		case AudioConfig7Point1:
			tag = kAudioChannelLayoutTag_WAVE_7_1;
			break;
		default:
			tag = 0;
			break;
	}

	if(tag) {
		layout.mChannelLayoutTag = tag;
	} else {
		layout.mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelBitmap;
		layout.mChannelBitmap = config;
	}

	if(audioFormatDescription) {
		CFRelease(audioFormatDescription);
		audioFormatDescription = NULL;
	}

	if(CMAudioFormatDescriptionCreate(kCFAllocatorDefault, &fmt, sizeof(layout), &layout, 0, NULL, NULL, &audioFormatDescription) != noErr) {
		return NO;
	}

	descriptionFormat = fmt;
	descriptionChannelConfig = config;
	return YES;
}

- (CMSampleBufferRef)makeSampleBufferWithChunk:(AudioChunk *)chunk {
	AudioStreamBasicDescription chunkFormat = [chunk format];
	uint32_t chunkConfig = [chunk channelConfig];
	if(![self updateFormatDescriptionForFormat:chunkFormat channelConfig:chunkConfig]) {
		return NULL;
	}

	size_t frameCount = [chunk frameCount];
	double chunkTimestamp = [chunk streamTimestamp];
	double chunkDurationSeconds = (double)frameCount / chunkFormat.mSampleRate;
	NSData *data = [chunk removeSamples:frameCount];
	size_t byteCount = frameCount * chunkFormat.mBytesPerPacket;
	if([data length] < byteCount) {
		return NULL;
	}

	CMBlockBufferRef blockBuffer = NULL;
	if(CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, NULL, byteCount, kCFAllocatorDefault, NULL, 0, byteCount, kCMBlockBufferAssureMemoryNowFlag, &blockBuffer) != noErr || !blockBuffer) {
		return NULL;
	}
	if(CMBlockBufferReplaceDataBytes([data bytes], blockBuffer, 0, byteCount) != noErr) {
		CFRelease(blockBuffer);
		return NULL;
	}

	CMTime pts;
	[currentPtsLock lock];
	pts = outputPts;
	[currentPtsLock unlock];

	CMSampleBufferRef sampleBuffer = NULL;
	OSStatus err = CMAudioSampleBufferCreateReadyWithPacketDescriptions(kCFAllocatorDefault, blockBuffer, audioFormatDescription, frameCount, pts, NULL, &sampleBuffer);
	CFRelease(blockBuffer);
	if(err != noErr || !sampleBuffer) {
		return NULL;
	}

	[currentPtsLock lock];
	lastEnqueuedStreamTimestamp = chunkTimestamp + chunkDurationSeconds;
	[currentPtsLock unlock];

	return sampleBuffer;
}

- (void)enqueuePendingAudio {
	if(!audioRenderer) return;

	while(!stopping && [audioRenderer isReadyForMoreMediaData]) {
		double buffered;
		[currentPtsLock lock];
		buffered = CMTimeGetSeconds(CMTimeSubtract(outputPts, currentPts));
		[currentPtsLock unlock];
		if(buffered >= kAirPlayMaxBufferedSeconds) break;

		AudioChunk *chunk = nil;
		[outputLock lock];
		ChunkList *tail = [bufferNode buffer];
		if(tail && ![tail isEmpty]) {
			chunk = [tail removeSamples:512];
		}
		[outputLock unlock];
		if(!chunk || ![chunk frameCount]) break;

		CMSampleBufferRef bufferRef = [self makeSampleBufferWithChunk:chunk];
		if(!bufferRef) break;

		CMTime chunkDuration = CMSampleBufferGetDuration(bufferRef);
		[currentPtsLock lock];
		outputPts = CMTimeAdd(outputPts, chunkDuration);
		[currentPtsLock unlock];

		[audioRenderer enqueueSampleBuffer:bufferRef];
		CFRelease(bufferRef);

		prebufferReached = YES;
	}
}

- (void)flushRenderer {
	[self removeSynchronizerBlock];
	[renderSynchronizer setRate:0];
	[audioRenderer stopRequestingMediaData];
	[audioRenderer flush];

	[currentPtsLock lock];
	currentPts = kCMTimeZero;
	lastPts = kCMTimeZero;
	outputPts = kCMTimeZero;
	lastEnqueuedStreamTimestamp = 0.0;
	[currentPtsLock unlock];
	secondsLatency = 0.0;

	started = NO;
	restarted = NO;

	[self synchronizerBlock];
}

- (void)threadEntry:(id)arg {
	@autoreleasepool {
		NSThread *currentThread = [NSThread currentThread];
		[currentThread setThreadPriority:0.75];
		[currentThread setQualityOfService:NSQualityOfServiceUserInitiated];
	}

	running = YES;
	started = NO;
	shouldPlayOutBuffer = NO;
	BOOL rendered = NO;

	while(!stopping) {
		@autoreleasepool {
			if([outputController shouldReset]) {
				[outputController setShouldReset:NO];
				pendingFlush = YES;
			}
			if(pendingFlush) {
				pendingFlush = NO;
				[outputLock lock];
				[buffer reset];
				[self setShouldReset:YES];
				[outputLock unlock];
				[self flushRenderer];
			}

			if(stopping)
				break;

			if(!cutOffInput && ![buffer isFull]) {
				[self renderAndConvert];
				rendered = YES;
			} else {
				rendered = NO;
			}

			[self enqueuePendingAudio];

			if(!started && !paused) {
				[self resume];
			}

			if(prebufferReached && !prebufferSignaled) {
				prebufferSignaled = YES;
				[[NSNotificationCenter defaultCenter] postNotificationName:CogPlaybackDidPrebufferNotification object:nil];
			}

			if([outputController shouldContinue] == NO) {
				break;
			}
		}

		if(!rendered) {
			usleep(5000);
		}
	}

	stopped = YES;
	if(!stopInvoked) {
		[self doStop];
	}
}

- (void)synchronizerBlock {
	NSLock *lock = currentPtsLock;
	CMTime interval = CMTimeMakeWithSeconds(1.0 / 60.0, 1000000000);
	currentPtsObserver = [renderSynchronizer addPeriodicTimeObserverForInterval:interval
	                                                                      queue:NULL
	                                                                 usingBlock:^(CMTime time) {
		                                                                 [lock lock];
		                                                                 self->currentPts = time;
		                                                                 CMTime latencyTime = CMTimeSubtract(self->outputPts, time);
		                                                                 double enqueuedTimestamp = self->lastEnqueuedStreamTimestamp;
		                                                                 [lock unlock];
		                                                                 double latencySeconds = CMTimeGetSeconds(latencyTime);
		                                                                 if(latencySeconds < 0)
			                                                                 latencySeconds = 0;
		                                                                 self->secondsLatency = latencySeconds;
		                                                                 if(enqueuedTimestamp > 0) {
			                                                                 double position = enqueuedTimestamp - latencySeconds;
			                                                                 if(position > 0) {
				                                                                 [self->outputController setAmountPlayed:position];
			                                                                 }
		                                                                 }
		                                                                 [self->visController postLatency:[self->outputController getVisLatency]];
		                                                                 [self->visController postFullLatency:[self->outputController getTotalLatency]];
	                                                                 }];
}

- (void)removeSynchronizerBlock {
	if(renderSynchronizer && currentPtsObserver) {
		[renderSynchronizer removeTimeObserver:currentPtsObserver];
		currentPtsObserver = nil;
	}
}
```

- [ ] **Step 4: Write `Audio/Output/OutputAirPlay.m` — part 3 (setup, lifecycle, fades, accessors)**

Append:

```objc
- (BOOL)setup {
	if(audioRenderer || renderSynchronizer)
		[self stop];

	@synchronized(self) {
		stopInvoked = NO;
		stopCompleted = NO;
		commandStop = NO;
		shouldPlayOutBuffer = NO;

		audioFormatDescription = NULL;
		bzero(&descriptionFormat, sizeof(descriptionFormat));
		descriptionChannelConfig = 0;

		resetStreamFormat = NO;
		streamFormatChanged = NO;
		streamFormatStarted = NO;

		running = NO;
		stopping = NO;
		stopped = NO;
		paused = NO;
		started = NO;
		restarted = NO;
		outputDeviceID = -1;

		cutOffInput = NO;
		faded = NO;
		pendingFlush = NO;

		streamTimestamp = 0.0;
		lastEnqueuedStreamTimestamp = 0.0;
		secondsLatency = 0.0;
		prebufferReached = NO;
		prebufferSignaled = NO;

		audioRenderer = [AVSampleBufferAudioRenderer new];
		renderSynchronizer = [AVSampleBufferRenderSynchronizer new];

		if(audioRenderer == nil || renderSynchronizer == nil)
			return NO;

		// Setup the output device before mucking with settings
		NSDictionary *device = [[[NSUserDefaultsController sharedUserDefaultsController] defaults] objectForKey:@"outputDevice"];
		if(device) {
			BOOL ok = [self setOutputDeviceWithDeviceDict:device];
			if(!ok) {
				// Ruh roh.
				[self setOutputDeviceWithDeviceDict:nil];

				[[[NSUserDefaultsController sharedUserDefaultsController] defaults] removeObjectForKey:@"outputDevice"];
			}
		} else {
			[self setOutputDeviceWithDeviceDict:nil];
		}

		// Default advertised format until the first track prepares a real one
		bzero(&deviceFormat, sizeof(deviceFormat));
		deviceFormat.mSampleRate = 44100.0;
		deviceFormat.mFormatID = kAudioFormatLinearPCM;
		deviceFormat.mFormatFlags = kAudioFormatFlagsNativeFloatPacked;
		deviceFormat.mBitsPerChannel = 32;
		deviceFormat.mChannelsPerFrame = 2;
		deviceFormat.mFramesPerPacket = 1;
		deviceFormat.mBytesPerFrame = sizeof(float) * 2;
		deviceFormat.mBytesPerPacket = sizeof(float) * 2;
		deviceChannelConfig = AudioConfigStereo;

		[outputController setFormat:&deviceFormat channelConfig:deviceChannelConfig];

		visController = [VisualizationController sharedController];

		downmixNode = [[DSPDownmixNode alloc] initWithController:self previous:self latency:0.03];
		faderNode = [[DSPFaderNode alloc] initWithController:self previous:downmixNode latency:0.03];

		bufferNode = [[SimpleBuffer alloc] initWithController:self previous:faderNode latency:0.1];

		[self setShouldContinue:YES];
		[self setEndOfStream:NO];

		[downmixNode setResetBarrier:YES];
		[downmixNode setOutputFormat:deviceFormat withChannelConfig:deviceChannelConfig];

		DSPsLaunched = YES;
		[self launchDSPs];
		[bufferNode launchThread];

		[[NSUserDefaultsController sharedUserDefaultsController] addObserver:self forKeyPath:@"values.outputDevice" options:0 context:kOutputAirPlayContext];
		observersapplied = YES;

		[audioRenderer addObserver:self forKeyPath:@"status" options:0 context:kOutputAirPlayContext];
		rendererStatusObserverApplied = YES;

		[renderSynchronizer addRenderer:audioRenderer];

		[currentPtsLock lock];
		currentPts = kCMTimeZero;
		lastPts = kCMTimeZero;
		outputPts = kCMTimeZero;
		[currentPtsLock unlock];

		[self synchronizerBlock];

		[audioRenderer setVolume:volume];

		return YES;
	}
}

- (NSArray *)DSPs {
	if(DSPsLaunched) {
		return @[downmixNode, faderNode];
	} else {
		return @[];
	}
}

- (DSPDownmixNode *)downmix {
	return downmixNode;
}

- (DSPFaderNode *)fader {
	return faderNode;
}

- (void)launchDSPs {
	NSArray *DSPs = [self DSPs];

	for (Node *node in DSPs) {
		[node launchThread];
	}
}

- (double)volume {
	return volume * 100.0f;
}

- (void)setVolume:(double)v {
	volume = v * 0.01f;
	if(audioRenderer) {
		[audioRenderer setVolume:volume];
	}
}

- (double)latency {
	double tail = [buffer listDuration] + [[downmixNode buffer] listDuration] + [[faderNode buffer] listDuration] + [[bufferNode buffer] listDuration];
	double renderer = secondsLatency > 0 ? secondsLatency : 0;
	return renderer + tail;
}

- (void)start {
	[self threadEntry:nil];
}

- (void)stop {
	commandStop = YES;
	[self doStop];
}

- (void)doStop {
	if(stopInvoked) {
		return;
	}
	@synchronized(self) {
		stopInvoked = YES;
		if(observersapplied) {
			[[NSUserDefaultsController sharedUserDefaultsController] removeObserver:self forKeyPath:@"values.outputDevice" context:kOutputAirPlayContext];
			observersapplied = NO;
		}
		if(rendererStatusObserverApplied) {
			[audioRenderer removeObserver:self forKeyPath:@"status" context:kOutputAirPlayContext];
			rendererStatusObserverApplied = NO;
		}
		stopping = YES;
		paused = NO;
		if(defaultdevicelistenerapplied || currentdevicelistenerapplied || devicealivelistenerapplied) {
			AudioObjectPropertyAddress theAddress = {
				.mScope = kAudioObjectPropertyScopeGlobal,
				.mElement = kAudioObjectPropertyElementMaster
			};
			if(defaultdevicelistenerapplied) {
				theAddress.mSelector = kAudioHardwarePropertyDefaultOutputDevice;
				AudioObjectRemovePropertyListener(kAudioObjectSystemObject, &theAddress, airplay_default_device_changed, (__bridge void *_Nullable)(self));
				defaultdevicelistenerapplied = NO;
			}
			if(devicealivelistenerapplied) {
				theAddress.mSelector = kAudioDevicePropertyDeviceIsAlive;
				AudioObjectRemovePropertyListener(outputDeviceID, &theAddress, airplay_current_device_listener, (__bridge void *_Nullable)(self));
				devicealivelistenerapplied = NO;
			}
			currentdevicelistenerapplied = NO;
		}
		if(renderSynchronizer || audioRenderer) {
			if(renderSynchronizer) {
				if(shouldPlayOutBuffer && !commandStop) {
					int compareVal = 0;
					double drainLatency = self->secondsLatency >= 0 ? self->secondsLatency : 0;
					int compareMax = (((1000000 / 5000) * drainLatency) + (10000 / 5000)); // latency plus 10ms, divide by sleep intervals
					do {
						[currentPtsLock lock];
						compareVal = CMTimeCompare(outputPts, currentPts);
						[currentPtsLock unlock];
						usleep(5000);
					} while(!commandStop && compareVal > 0 && compareMax-- > 0);
				}
				[self removeSynchronizerBlock];
				[renderSynchronizer setRate:0];
				if(audioRenderer) {
					[renderSynchronizer removeRenderer:audioRenderer atTime:kCMTimeZero completionHandler:^(BOOL didRemoveRenderer) {
						if(!didRemoveRenderer) {
							DLog(@"Error removing renderer!");
						}
					}];
				}
			}
			if(audioRenderer) {
				[audioRenderer stopRequestingMediaData];
				[audioRenderer flush];
			}
			renderSynchronizer = nil;
			audioRenderer = nil;
		}
		if(running) {
			while(!stopped) {
				stopping = YES;
				usleep(5000);
			}
		}
		if(audioFormatDescription) {
			CFRelease(audioFormatDescription);
			audioFormatDescription = NULL;
		}
		if(DSPsLaunched) {
			[self setShouldContinue:NO];
			[downmixNode setShouldContinue:NO];
			[faderNode setShouldContinue:NO];
			downmixNode = nil;
			faderNode = nil;
			DSPsLaunched = NO;
		}
		if(bufferNode) {
			[bufferNode setShouldContinue:NO];
			bufferNode = nil;
		}
		outputController = nil;
		if(visController) {
			[visController reset];
			visController = nil;
		}
		prebufferReached = NO;
		prebufferSignaled = NO;
		stopCompleted = YES;
	}
}

- (void)dealloc {
	[self stop];
	// In case stop called on another thread first
	while(!stopCompleted) {
		usleep(500);
	}
}

- (void)pause {
	paused = YES;
	if(started)
		[renderSynchronizer setRate:0];
}

- (void)resume {
	[renderSynchronizer setRate:1.0 time:currentPts];
	paused = NO;
	started = YES;
}

- (void)fadeOut {
	// AirPlay routes buffer seconds ahead; an in-band fade would only be
	// audible after that buffer drains, so halt the synchronizer instead.
	faded = YES;
	[self pause];
}

- (void)fadeOutBackground {
	cutOffInput = YES;

	[bufferNode setPreviousNode:nil];
	[downmixNode setPreviousNode:nil];

	DSPDownmixNode *oldDownmix = downmixNode;
	DSPFaderNode *oldFader = faderNode;

	downmixNode = [[DSPDownmixNode alloc] initWithController:self previous:self latency:0.03];
	faderNode = [[DSPFaderNode alloc] initWithController:self previous:nil latency:0.03];
	[downmixNode setResetBarrier:YES];
	[downmixNode setOutputFormat:deviceFormat withChannelConfig:deviceChannelConfig];
	faderNode.timestamp = oldFader.timestamp;

	[oldDownmix setShouldContinue:NO];
	[oldFader setShouldContinue:NO];

	[outputLock lock];
	buffer = [[ChunkList alloc] initWithMaximumDuration:0.5];
	[outputLock unlock];

	[bufferNode setPreviousNode:faderNode];
	[bufferNode resetBuffer];
	[self launchDSPs];

	pendingFlush = YES;

	cutOffInput = NO;
}

- (void)beginSeek {
}

- (void)fadeIn {
	faded = NO;
	[self resume];
}

- (void)faderFadeIn {
	if(playbackFadesEnabled()) {
		[faderNode fadeIn];
	} else {
		[faderNode waitForReset];
	}
	[faderNode setPreviousNode:downmixNode];
	faded = NO;
	prebufferSignaled = NO;
}

- (void)timeOut {
	// Synchronizer rate 0 already halts streaming; there is no hardware
	// unit to suspend on an idle timer.
}

- (void)sustainHDCD {
	secondsHdcdSustained = 10.0;
}

- (void)setShouldPlayOutBuffer:(BOOL)s {
	shouldPlayOutBuffer = s;
}

- (AudioStreamBasicDescription)deviceFormat {
	return deviceFormat;
}

- (uint32_t)deviceChannelConfig {
	return deviceChannelConfig;
}

@end
```

- [ ] **Step 5: Add both files to the CogAudio project**

Same anchors as before in `Audio/CogAudio.xcodeproj/project.pbxproj`:

1. `PBXBuildFile`:
```
		A1A0C0DE2E3700000000A008 /* OutputAirPlay.h in Headers */ = {isa = PBXBuildFile; fileRef = A1A0C0DE2E3700000000A007 /* OutputAirPlay.h */; settings = {ATTRIBUTES = (Public, ); }; };
		A1A0C0DE2E3700000000A00A /* OutputAirPlay.m in Sources */ = {isa = PBXBuildFile; fileRef = A1A0C0DE2E3700000000A009 /* OutputAirPlay.m */; };
```
2. `PBXFileReference`:
```
		A1A0C0DE2E3700000000A007 /* OutputAirPlay.h */ = {isa = PBXFileReference; fileEncoding = 4; lastKnownFileType = sourcecode.c.h; path = OutputAirPlay.h; sourceTree = "<group>"; };
		A1A0C0DE2E3700000000A009 /* OutputAirPlay.m */ = {isa = PBXFileReference; fileEncoding = 4; lastKnownFileType = sourcecode.c.objc; path = OutputAirPlay.m; sourceTree = "<group>"; };
```
3. Output group children: add both file refs.
4. `Headers` phase: add `OutputAirPlay.h in Headers`; `Sources` phase: add `OutputAirPlay.m in Sources`.

- [ ] **Step 6: Build**

Run the Global Constraints build command. Expected: `** BUILD SUCCEEDED **`. If linking fails on CoreMedia symbols (`CMAudioSampleBufferCreateReadyWithPacketDescriptions` etc.), add `CoreMedia.framework` to the CogAudio target's Link Binary With Libraries phase (modules autolinking normally covers this).

- [ ] **Step 7: Commit**

```bash
git add Audio/Output/OutputAirPlay.h Audio/Output/OutputAirPlay.m Audio/CogAudio.xcodeproj/project.pbxproj
git commit -m "Output: add AVSampleBufferAudioRenderer AirPlay backend"
```

---

### Task 4: Transport-driven backend selection

**Files:**
- Modify: `Audio/Chain/OutputNode.h` (declare selection API)
- Modify: `Audio/Chain/OutputNode.m` (choose backend class in `setupWithInterval:`)
- Modify: `Audio/AudioPlayer.m` (rebuild output on transport-boundary changes)

**Interfaces:**
- Consumes: `CogOutputDeviceDictIsAirPlay` (Task 2), `OutputAirPlay` (Task 3), existing `restartPlaybackAtCurrentPosition` delegate flow (`AudioPlayer.m:286`, `PlaybackController.m:972`).
- Produces: `+ (Class)backendClassForCurrentDevice` and `- (BOOL)backendMatchesCurrentDevice` on `OutputNode` — Task 5's UI relies on the switching working end-to-end but calls nothing new here.

- [ ] **Step 1: Declare the selection API in `Audio/Chain/OutputNode.h`**

Add after the `- (BOOL)setupWithInterval:(BOOL)resumeInterval;` declaration:

```objc
+ (Class)backendClassForCurrentDevice;
- (BOOL)backendMatchesCurrentDevice;
```

- [ ] **Step 2: Implement selection in `Audio/Chain/OutputNode.m`**

Add imports below `#import "OutputCoreAudio.h"`:

```objc
#import "OutputAirPlay.h"
#import "OutputDeviceRouting.h"
```

Add the two methods right above `- (BOOL)setup {`:

```objc
+ (Class)backendClassForCurrentDevice {
	NSDictionary *device = [[[NSUserDefaultsController sharedUserDefaultsController] defaults] objectForKey:@"outputDevice"];
	if(CogOutputDeviceDictIsAirPlay(device)) {
		return [OutputAirPlay class];
	}
	return [OutputCoreAudio class];
}

- (BOOL)backendMatchesCurrentDevice {
	if(!output) return YES;
	return [output isKindOfClass:[OutputNode backendClassForCurrentDevice]];
}
```

In `setupWithInterval:`, replace:

```objc
	output = [[OutputCoreAudio alloc] initWithController:self];
```

with:

```objc
	Class backendClass = [OutputNode backendClassForCurrentDevice];
	DLog(@"Output backend for current device: %@", NSStringFromClass(backendClass));
	output = [[backendClass alloc] initWithController:self];
```

- [ ] **Step 3: Rebuild the output across transport boundaries in `Audio/AudioPlayer.m`**

First check whether `AudioPlayer.m` already implements `observeValueForKeyPath:` (`grep -n "observeValueForKeyPath" Audio/AudioPlayer.m`). As of this plan it does not.

Add near the top of the `@implementation` (after any existing statics):

```objc
static void *kAudioPlayerContext = &kAudioPlayerContext;
```

In `- (id)init` (the method that sets `output = NULL;`), add before `return self;`:

```objc
		[[NSUserDefaultsController sharedUserDefaultsController] addObserver:self forKeyPath:@"values.outputDevice" options:0 context:kAudioPlayerContext];
```

Add the observer method and a `dealloc` (verify no `dealloc` exists yet; merge if one does):

```objc
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
	if(context != kAudioPlayerContext) {
		[super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
		return;
	}

	if([keyPath isEqualToString:@"values.outputDevice"]) {
		if(output && ![output backendMatchesCurrentDevice]) {
			DLog(@"Output device crossed a transport boundary; restarting playback to switch backend");
			[self restartPlaybackAtCurrentPosition];
		}
	}
}

- (void)dealloc {
	[[NSUserDefaultsController sharedUserDefaultsController] removeObserver:self forKeyPath:@"values.outputDevice" context:kAudioPlayerContext];
}
```

In `- (void)play:withUserInfo:withRGInfo:startPaused:andSeekTo:andResumeInterval:`, insert after `[self waitUntilCallbacksExit];` and before `if(output) {`:

```objc
	if(output && ![output backendMatchesCurrentDevice]) {
		DLog(@"Rebuilding output for backend change");
		[output setShouldContinue:NO];
		[output close];
		output = nil;
	}
```

(The restart flow is: defaults change → observer sees mismatched backend → `restartPlaybackAtCurrentPosition` → `PlaybackController` replays the current entry at position → `play:` finds the mismatch, closes the old output, and `setupWithInterval:` instantiates the right backend class.)

- [ ] **Step 4: Build**

Run the Global Constraints build command. Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Smoke test (requires a human with an AirPlay device — skip and flag in the task report if unavailable)**

Launch the built app. In Preferences → Output, select an AirPlay device (it appears in the device list once macOS knows it; otherwise select it once in System Settings → Sound first). Play a FLAC track. Expected: audio on the AirPlay device after ~1–2 s; Console (`log stream --predicate 'process == "Cog"'` with a Debug build) shows `Output backend for current device: OutputAirPlay`. Switch back to built-in output mid-play: playback restarts at position through `OutputCoreAudio`.

- [ ] **Step 6: Commit**

```bash
git add Audio/Chain/OutputNode.h Audio/Chain/OutputNode.m Audio/AudioPlayer.m
git commit -m "Output: select backend by device transport type"
```

---

### Task 5: AirPlay toolbar button with device menu

**Files:**
- Create: `Window/AirPlayItem.h`
- Create: `Window/AirPlayItem.m`
- Modify: `Base.lproj/MainMenu.xib` (three toolbars)
- Modify: `Cog.xcodeproj/project.pbxproj`
- Modify: `Localizable.xcstrings` (only if keys are not auto-extracted by the build — see Step 5)

**Interfaces:**
- Consumes: `CogOutputDeviceDictIsAirPlay`, `CogDeviceTransportType` from `<CogAudio/OutputDeviceRouting.h>` (Task 2); the `outputDevice` defaults dict `{"name": String, "deviceID": Int}` (same shape `AudioDeviceModel.swift:122` writes); `AVRouteDetector`.
- Produces: `AirPlayItem : NSToolbarItem`, instantiated from the xib by `customClass` (no outlets). Selecting a menu entry writes the `outputDevice` default — Task 4's observer does the backend switch; nothing else to wire.

- [ ] **Step 1: Write `Window/AirPlayItem.h`**

```objc
//
//  AirPlayItem.h
//  Cog
//
//  Toolbar button that lists output devices, AirPlay routes included,
//  and routes playback by writing the shared outputDevice default.
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface AirPlayItem : NSToolbarItem
@end

NS_ASSUME_NONNULL_END
```

- [ ] **Step 2: Write `Window/AirPlayItem.m`**

```objc
//
//  AirPlayItem.m
//  Cog
//

#import "AirPlayItem.h"

#import <AVFoundation/AVFoundation.h>
#import <CoreAudio/AudioHardware.h>

#import <CogAudio/OutputDeviceRouting.h>

static void *kAirPlayItemContext = &kAirPlayItemContext;

@interface AirPlayItem ()
@property(nonatomic, strong) NSButton *button;
@property(nonatomic, strong) AVRouteDetector *routeDetector;
@end

@implementation AirPlayItem

- (void)awakeFromNib {
	[super awakeFromNib];

	NSButton *button = [NSButton new];
	[button setButtonType:NSButtonTypeMomentaryPushIn];
	button.bezelStyle = NSBezelStyleTexturedRounded;
	NSImage *image = nil;
	if(@available(macOS 11.0, *)) {
		image = [NSImage imageWithSystemSymbolName:@"airplay.audio" accessibilityDescription:NSLocalizedString(@"AirPlay", @"")];
	}
	if(image) {
		[image setTemplate:YES];
		button.image = image;
	} else {
		button.title = NSLocalizedString(@"AirPlay", @"");
	}
	button.target = self;
	button.action = @selector(showDeviceMenu:);
	button.frame = NSMakeRect(0, 0, 40, 26);
	self.button = button;
	[self setView:button];

	self.routeDetector = [AVRouteDetector new];
	self.routeDetector.routeDetectionEnabled = YES;

	[[NSUserDefaultsController sharedUserDefaultsController] addObserver:self forKeyPath:@"values.outputDevice" options:NSKeyValueObservingOptionInitial context:kAirPlayItemContext];
}

- (void)dealloc {
	[[NSUserDefaultsController sharedUserDefaultsController] removeObserver:self forKeyPath:@"values.outputDevice" context:kAirPlayItemContext];
	self.routeDetector.routeDetectionEnabled = NO;
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
	if(context == kAirPlayItemContext) {
		dispatch_async(dispatch_get_main_queue(), ^{
			[self updateActiveState];
		});
	} else {
		[super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
	}
}

- (void)updateActiveState {
	NSDictionary *device = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"outputDevice"];
	BOOL active = CogOutputDeviceDictIsAirPlay(device);
	if(@available(macOS 10.14, *)) {
		self.button.contentTintColor = active ? [NSColor controlAccentColor] : nil;
	}
}

+ (void)enumerateOutputDevices:(void (NS_NOESCAPE ^)(NSString *name, AudioDeviceID deviceID, BOOL isAirPlay))block {
	AudioObjectPropertyAddress theAddress = {
		.mSelector = kAudioHardwarePropertyDevices,
		.mScope = kAudioObjectPropertyScopeGlobal,
		.mElement = kAudioObjectPropertyElementMaster
	};

	UInt32 propsize = 0;
	if(AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &theAddress, 0, NULL, &propsize) != noErr) return;
	UInt32 nDevices = propsize / (UInt32)sizeof(AudioDeviceID);
	AudioDeviceID *devids = (AudioDeviceID *)malloc(propsize);
	if(!devids) return;
	if(AudioObjectGetPropertyData(kAudioObjectSystemObject, &theAddress, 0, NULL, &propsize, devids) != noErr) {
		free(devids);
		return;
	}

	for(UInt32 i = 0; i < nDevices; ++i) {
		AudioObjectPropertyAddress devAddress = {
			.mSelector = kAudioDevicePropertyDeviceIsAlive,
			.mScope = kAudioDevicePropertyScopeOutput,
			.mElement = kAudioObjectPropertyElementMaster
		};
		UInt32 isAlive = 0;
		UInt32 size = sizeof(isAlive);
		if(AudioObjectGetPropertyData(devids[i], &devAddress, 0, NULL, &size, &isAlive) != noErr || !isAlive) continue;

		devAddress.mSelector = kAudioDevicePropertyStreamConfiguration;
		UInt32 bufSize = 0;
		if(AudioObjectGetPropertyDataSize(devids[i], &devAddress, 0, NULL, &bufSize) != noErr || bufSize < sizeof(UInt32)) continue;
		AudioBufferList *bufferList = (AudioBufferList *)malloc(bufSize);
		if(!bufferList) continue;
		UInt32 bufferCount = 0;
		if(AudioObjectGetPropertyData(devids[i], &devAddress, 0, NULL, &bufSize, bufferList) == noErr) {
			bufferCount = bufferList->mNumberBuffers;
		}
		free(bufferList);
		if(!bufferCount) continue;

		CFStringRef name = NULL;
		size = sizeof(name);
		devAddress.mSelector = kAudioDevicePropertyDeviceNameCFString;
		if(AudioObjectGetPropertyData(devids[i], &devAddress, 0, NULL, &size, &name) != noErr || !name) continue;

		BOOL isAirPlay = CogDeviceTransportType(devids[i]) == kAudioDeviceTransportTypeAirPlay;
		block((__bridge NSString *)name, devids[i], isAirPlay);
		CFRelease(name);
	}

	free(devids);
}

- (void)showDeviceMenu:(id)sender {
	NSMenu *menu = [[NSMenu alloc] initWithTitle:NSLocalizedString(@"AirPlay", @"")];
	NSDictionary *current = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"outputDevice"];
	NSNumber *currentIDNum = current ? current[@"deviceID"] : nil;
	int currentID = currentIDNum ? [currentIDNum intValue] : -1;

	NSMenuItem *localHeader = [menu addItemWithTitle:NSLocalizedString(@"Local", @"AirPlay menu section header for wired/built-in devices") action:nil keyEquivalent:@""];
	localHeader.enabled = NO;

	NSMenuItem *defaultItem = [menu addItemWithTitle:NSLocalizedString(@"System Default Device", @"") action:@selector(selectDevice:) keyEquivalent:@""];
	defaultItem.target = self;
	defaultItem.representedObject = @{ @"name": @"", @"deviceID": @(-1) };
	if(currentID == -1) defaultItem.state = NSControlStateValueOn;

	NSMutableArray<NSMenuItem *> *airPlayItems = [NSMutableArray array];
	[AirPlayItem enumerateOutputDevices:^(NSString *name, AudioDeviceID deviceID, BOOL isAirPlay) {
		NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:name action:@selector(selectDevice:) keyEquivalent:@""];
		item.target = self;
		item.representedObject = @{ @"name": name, @"deviceID": @((int)deviceID) };
		if(currentID == (int)deviceID) item.state = NSControlStateValueOn;
		if(isAirPlay) {
			[airPlayItems addObject:item];
		} else {
			[menu addItem:item];
		}
	}];

	[menu addItem:[NSMenuItem separatorItem]];
	NSMenuItem *airPlayHeader = [menu addItemWithTitle:NSLocalizedString(@"AirPlay", @"") action:nil keyEquivalent:@""];
	airPlayHeader.enabled = NO;

	if([airPlayItems count]) {
		for(NSMenuItem *item in airPlayItems) {
			[menu addItem:item];
		}
	} else if(self.routeDetector.multipleRoutesDetected) {
		// Routes exist but macOS has not materialized them as CoreAudio
		// devices yet; send the user to Sound settings to activate one.
		NSMenuItem *item = [menu addItemWithTitle:NSLocalizedString(@"Open Sound Settings…", @"") action:@selector(openSoundSettings:) keyEquivalent:@""];
		item.target = self;
	} else {
		NSMenuItem *item = [menu addItemWithTitle:NSLocalizedString(@"No AirPlay devices found", @"") action:nil keyEquivalent:@""];
		item.enabled = NO;
	}

	[menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(0, self.button.bounds.size.height) inView:self.button];
}

- (void)selectDevice:(NSMenuItem *)sender {
	NSDictionary *device = sender.representedObject;
	[[NSUserDefaults standardUserDefaults] setObject:device forKey:@"outputDevice"];
}

- (void)openSoundSettings:(id)sender {
	[[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.sound"]];
}

@end
```

- [ ] **Step 3: Add the toolbar item to all three toolbars in `Base.lproj/MainMenu.xib`**

Three toolbars, each needs one `<toolbarItem>` in its `<allowedToolbarItems>` and one `<toolbarItem reference=.../>` in its `<defaultToolbarItems>`. All ids/identifiers below are new and unique.

**Main window toolbar** (toolbar `id="1523"`): insert into `<allowedToolbarItems>` immediately before the Spectrum item (`id="NtB-XF-g07"`):

```xml
                    <toolbarItem implicitItemIdentifier="7E2F5A10-9C4B-4D6E-8F3A-52B1C9D0E401" label="AirPlay" paletteLabel="AirPlay" tag="-1" bordered="YES" id="apm-Bt-n01" customClass="AirPlayItem">
                        <nil key="toolTip"/>
                        <size key="minSize" width="40" height="26"/>
                        <size key="maxSize" width="40" height="26"/>
                    </toolbarItem>
```

In the same toolbar's `<defaultToolbarItems>`, insert after `<toolbarItem reference="2466"/>` (Randomize):

```xml
                    <toolbarItem reference="apm-Bt-n01"/>
```

**Mini toolbar** (toolbar `id="2222"`, `userLabel="Mini Toolbar"`): insert into its `<allowedToolbarItems>` immediately before its Spectrum item (`id="sf3-l1-fJw"`):

```xml
                    <toolbarItem implicitItemIdentifier="7E2F5A10-9C4B-4D6E-8F3A-52B1C9D0E402" label="AirPlay" paletteLabel="AirPlay" tag="-1" bordered="YES" id="apm-Bt-n02" customClass="AirPlayItem">
                        <nil key="toolTip"/>
                        <size key="minSize" width="40" height="26"/>
                        <size key="maxSize" width="40" height="26"/>
                    </toolbarItem>
```

In its `<defaultToolbarItems>`, insert after `<toolbarItem reference="2279"/>` (Repeat):

```xml
                    <toolbarItem reference="apm-Bt-n02"/>
```

**Mini Plus toolbar** (toolbar `id="3101"`, `userLabel="Mini Plus Toolbar"`): insert into its `<allowedToolbarItems>` immediately after the closing `</toolbarItem>` of the Randomize item (`id="3122"`):

```xml
                    <toolbarItem implicitItemIdentifier="7E2F5A10-9C4B-4D6E-8F3A-52B1C9D0E403" label="AirPlay" paletteLabel="AirPlay" tag="-1" bordered="YES" id="apm-Bt-n03" customClass="AirPlayItem">
                        <nil key="toolTip"/>
                        <size key="minSize" width="40" height="26"/>
                        <size key="maxSize" width="40" height="26"/>
                    </toolbarItem>
```

In its `<defaultToolbarItems>`, insert after `<toolbarItem reference="3119"/>` (Repeat):

```xml
                    <toolbarItem reference="apm-Bt-n03"/>
```

Note: users who have customized their toolbar have a saved configuration; the new item appears for them in the customization palette (⌘-drag / right-click → Customize Toolbar), and in the default set for fresh configurations.

- [ ] **Step 4: Add `AirPlayItem` to `Cog.xcodeproj/project.pbxproj`**

Anchor on the SpectrumItem entries:

1. `PBXBuildFile` section, after the line containing `8377C6B927B900F000E8BC0F /* SpectrumItem.m in Sources */`:
```
		A1A0C0DE2E3700000000B003 /* AirPlayItem.m in Sources */ = {isa = PBXBuildFile; fileRef = A1A0C0DE2E3700000000B002 /* AirPlayItem.m */; };
```
2. `PBXFileReference` section, after the `8377C6B827B900F000E8BC0F /* SpectrumItem.m */` file reference:
```
		A1A0C0DE2E3700000000B001 /* AirPlayItem.h */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.c.h; name = AirPlayItem.h; path = Window/AirPlayItem.h; sourceTree = "<group>"; };
		A1A0C0DE2E3700000000B002 /* AirPlayItem.m */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.c.objc; name = AirPlayItem.m; path = Window/AirPlayItem.m; sourceTree = "<group>"; };
```
3. In the group whose children include `8377C6B727B900F000E8BC0F /* SpectrumItem.h */,`:
```
				A1A0C0DE2E3700000000B001 /* AirPlayItem.h */,
				A1A0C0DE2E3700000000B002 /* AirPlayItem.m */,
```
4. In the `Sources` phase containing `8377C6B927B900F000E8BC0F /* SpectrumItem.m in Sources */,`:
```
				A1A0C0DE2E3700000000B003 /* AirPlayItem.m in Sources */,
```

- [ ] **Step 5: Localized strings**

Build once (next step), then check whether the new keys were extracted: `grep -c "Open Sound Settings" Localizable.xcstrings`. If `0`, add the four keys manually to the JSON (top-level `"strings"` object, alphabetical position irrelevant), following the existing entry shape in that file:

```json
    "AirPlay" : {
      "extractionState" : "manual"
    },
    "Local" : {
      "comment" : "AirPlay menu section header for wired/built-in devices",
      "extractionState" : "manual"
    },
    "No AirPlay devices found" : {
      "extractionState" : "manual"
    },
    "Open Sound Settings…" : {
      "extractionState" : "manual"
    },
```

(`"System Default Device"` already exists in the catalog.)

- [ ] **Step 6: Build and run**

Run the Global Constraints build command. Expected: `** BUILD SUCCEEDED **`. Launch the app: the AirPlay button appears between the shuffle/repeat/randomize cluster and the spectrum meter; clicking opens the device menu with Local and AirPlay sections; picking a device switches output (Task 4 handles the backend). If the button renders blank on the toolbar, verify `awakeFromNib` ran (the xib item must have `customClass="AirPlayItem"` and the class must be in the app target).

- [ ] **Step 7: Commit**

```bash
git add Window/AirPlayItem.h Window/AirPlayItem.m Base.lproj/MainMenu.xib Cog.xcodeproj/project.pbxproj Localizable.xcstrings
git commit -m "Add AirPlay toolbar button with output device menu"
```

---

### Task 6: Group AirPlay devices in Preferences

**Files:**
- Modify: `Preferences/Panes/AudioDeviceModel.swift`
- Modify: `Preferences/Panes/OutputPaneView.swift`

**Interfaces:**
- Consumes: CoreAudio transport property (same semantics as `CogDeviceTransportType`; the Preferences target uses raw CoreAudio directly like the rest of `AudioDeviceModel`).
- Produces: `AudioDeviceModel.Device` gains `let isAirPlay: Bool`; the Output pane's device picker shows a separate AirPlay section. No other consumers of `Device` exist.

- [ ] **Step 1: Add transport awareness to `Preferences/Panes/AudioDeviceModel.swift`**

Change the `Device` struct:

```swift
    struct Device: Identifiable, Equatable {
        let id: Int      // AudioDeviceID stored as Int for UserDefaults compatibility
        let name: String
        let isAirPlay: Bool
    }
```

Update the two construction sites in `loadDevices()`:

```swift
        var result: [Device] = [Device(id: -1, name: NSLocalizedString("System Default Device", comment: ""), isAirPlay: false)]
```

```swift
        for deviceID in deviceIDs {
            guard let name = deviceName(deviceID) else { continue }
            guard hasOutputStreams(deviceID) else { continue }
            result.append(Device(id: Int(deviceID), name: name,
                                 isAirPlay: transportType(deviceID) == kAudioDeviceTransportTypeAirPlay))
        }
```

Add the helper below `hasOutputStreams`:

```swift
    private func transportType(_ deviceID: AudioDeviceID) -> UInt32 {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: elementMain
        )
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &transport) == noErr else { return 0 }
        return transport
    }
```

- [ ] **Step 2: Section the picker in `Preferences/Panes/OutputPaneView.swift`**

Replace the existing device picker:

```swift
            Picker("Output device:", selection: $deviceModel.selectedDeviceID) {
                ForEach(deviceModel.devices) { device in
                    Text(device.name).tag(device.id)
                }
            }
```

with:

```swift
            Picker("Output device:", selection: $deviceModel.selectedDeviceID) {
                ForEach(deviceModel.devices.filter { !$0.isAirPlay }) { device in
                    Text(device.name).tag(device.id)
                }
                if deviceModel.devices.contains(where: { $0.isAirPlay }) {
                    Section(header: Text("AirPlay")) {
                        ForEach(deviceModel.devices.filter { $0.isAirPlay }) { device in
                            Text(device.name).tag(device.id)
                        }
                    }
                }
            }
```

- [ ] **Step 3: Build**

Run the Global Constraints build command. Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add Preferences/Panes/AudioDeviceModel.swift Preferences/Panes/OutputPaneView.swift
git commit -m "Preferences: group AirPlay output devices"
```

---

### Task 7: Cleanup, universal build, verification matrix

**Files:**
- Delete: `Audio/Output/OutputAVFoundation.h`
- Delete: `Audio/Output/OutputAVFoundation.m`

**Interfaces:**
- Consumes: nothing — these files have zero references in either pbxproj (verify before deleting: `grep -c "OutputAVFoundation" Audio/CogAudio.xcodeproj/project.pbxproj Cog.xcodeproj/project.pbxproj` must print `0` for both).
- Produces: the finished feature, verified.

- [ ] **Step 1: Delete the orphaned reference implementation**

```bash
grep -c "OutputAVFoundation" Audio/CogAudio.xcodeproj/project.pbxproj Cog.xcodeproj/project.pbxproj
git rm Audio/Output/OutputAVFoundation.h Audio/Output/OutputAVFoundation.m
```

Expected grep output: `0` for both files (if non-zero, stop — something re-referenced them; investigate before deleting).

- [ ] **Step 2: Universal build (CI-equivalent)**

```sh
xcodebuild -project Cog.xcodeproj -scheme Cog -configuration Debug \
  -arch x86_64 -arch arm64 -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=NO build
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git commit -m "Remove orphaned OutputAVFoundation output"
```

- [ ] **Step 4: Manual verification matrix (requires a human with AirPlay hardware; record results, flag anything skipped)**

From the spec's verification section:

1. **Wired regression:** play/pause/seek feel unchanged on built-in output; gapless album playback intact; DoP DAC playback intact if hardware available.
2. **AirPlay playback:** FLAC 44.1 k and 96 k play on a HomePod/AirPlay 2 speaker; DSD64 track plays (as decimated PCM); pause/resume respond promptly; seek lands within ~a beat; track transitions play through.
3. **Route switching mid-play, both directions,** via all three entry points: toolbar menu, Preferences pane, Control Center default-device change (with Cog on "System Default Device"). Each switch restarts at the current position on the right backend (check `DLog` output: `Output backend for current device: …`).
4. **Route loss:** power off the AirPlay speaker mid-stream. Playback falls back to the default device and continues; log shows the renderer failure. (Known v1 limitation, documented deliberately: feedback is log-only, no user-facing alert.)
5. **Multi-room smoke test:** group the target speaker with another via Control Center while Cog plays to it.
6. **Toolbar customization:** the AirPlay item exists in all three toolbars' palettes; active route tints the icon with the accent color.

**Known v1 deferrals** (by design, from the spec): gapless across sample-rate changes on AirPlay may gap; visualization leads audible audio by the buffer depth unless existing latency compensation absorbs it; route-loss feedback is log-only.
