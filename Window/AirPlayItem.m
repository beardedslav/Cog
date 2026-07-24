//
//  AirPlayItem.m
//  Cog
//

#import "AirPlayItem.h"

#import <AVFoundation/AVFoundation.h>
#import <CoreAudio/AudioHardware.h>

#import <CogAudio/OutputDeviceRouting.h>

#import "AirPlayServiceBrowser.h"

static void *kAirPlayItemContext = &kAirPlayItemContext;

// One detector shared by every toolbar item: active route detection is
// documented as significantly increasing power consumption, so it only runs
// while a device menu is open, plus a short grace period so an immediate
// re-open sees completed detection.
static AVRouteDetector *sharedRouteDetector(void) {
	static AVRouteDetector *detector;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		detector = [AVRouteDetector new];
	});
	return detector;
}

// Main-thread only; invalidates any pending delayed disable when bumped.
static NSUInteger routeDetectionGeneration = 0;

@interface AirPlayItem ()
@property(nonatomic, strong) NSButton *button;
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

	[[NSUserDefaultsController sharedUserDefaultsController] addObserver:self forKeyPath:@"values.outputDevice" options:NSKeyValueObservingOptionInitial context:kAirPlayItemContext];
}

- (void)dealloc {
	[[NSUserDefaultsController sharedUserDefaultsController] removeObserver:self forKeyPath:@"values.outputDevice" context:kAirPlayItemContext];
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

+ (void)enumerateOutputDevices:(void (NS_NOESCAPE ^)(NSString *name, AudioDeviceID deviceID, UInt32 transportType))block {
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

		block((__bridge NSString *)name, devids[i], CogDeviceTransportType(devids[i]));
		CFRelease(name);
	}

	free(devids);
}

- (void)showDeviceMenu:(id)sender {
	AVRouteDetector *routeDetector = sharedRouteDetector();
	++routeDetectionGeneration;
	routeDetector.routeDetectionEnabled = YES;

	AirPlayServiceBrowser *serviceBrowser = [AirPlayServiceBrowser sharedBrowser];
	[serviceBrowser beginBrowsing];
	// Bounded warm-up so a cold first open can still list devices; near-zero
	// cost when results are already in from the grace window.
	[serviceBrowser waitForFirstResultsUpTo:0.7];

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

	NSString *currentName = current ? current[@"name"] : nil;
	NSMutableArray<NSMenuItem *> *airPlayItems = [NSMutableArray array];
	__block BOOL matchedByID = NO;
	__block NSMenuItem *nameFallbackItem = nil;
	[AirPlayItem enumerateOutputDevices:^(NSString *name, AudioDeviceID deviceID, UInt32 transportType) {
		BOOL isAirPlay = transportType == kAudioDeviceTransportTypeAirPlay;
		// Conference apps publish virtual loopback devices (Microsoft Teams
		// Audio, ZoomAudioDevice) that nobody plays music to. Keep virtual
		// transports out of the quick picker unless one is the current
		// selection; the Output pane in Preferences still lists every device.
		if(transportType == kAudioDeviceTransportTypeVirtual && currentID != (int)deviceID) return;
		NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:name action:@selector(selectDevice:) keyEquivalent:@""];
		item.target = self;
		item.representedObject = @{ @"name": name, @"deviceID": @((int)deviceID) };
		if(currentID == (int)deviceID) {
			item.state = NSControlStateValueOn;
			matchedByID = YES;
		} else if(!nameFallbackItem && [currentName length] && [currentName isEqualToString:name]) {
			nameFallbackItem = item;
		}
		if(isAirPlay) {
			[airPlayItems addObject:item];
		} else {
			[menu addItem:item];
		}
	}];

	// The stored deviceID can go stale across reboots/route churn. The button
	// tint (CogOutputDeviceDictIsAirPlay) already falls back to name matching
	// in that case; mirror it for the checkmark.
	if(currentID != -1 && !matchedByID && nameFallbackItem) {
		nameFallbackItem.state = NSControlStateValueOn;
	}

	[menu addItem:[NSMenuItem separatorItem]];
	NSMenuItem *airPlayHeader = [menu addItemWithTitle:NSLocalizedString(@"AirPlay", @"") action:nil keyEquivalent:@""];
	airPlayHeader.enabled = NO;

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

	[menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(0, self.button.bounds.size.height) inView:self.button];

	// popUpMenuPositioningItem blocks while the menu tracks, so the menu is
	// closed here. A freshly enabled detector may not have completed detection
	// before the menu above was built, so hold detection on for a grace window
	// — a prompt re-open then reflects the finished scan — before disabling.
	NSUInteger generation = ++routeDetectionGeneration;
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
		if(generation == routeDetectionGeneration) {
			sharedRouteDetector().routeDetectionEnabled = NO;
		}
	});

	[serviceBrowser endBrowsingSoon];
}

- (void)selectDevice:(NSMenuItem *)sender {
	NSDictionary *device = sender.representedObject;
	[[NSUserDefaults standardUserDefaults] setObject:device forKey:@"outputDevice"];
}

- (void)selectDiscoveredDevice:(NSMenuItem *)sender {
	NSString *name = sender.representedObject;
	// The sink is not a CoreAudio device yet; remember the pick and send the
	// user to Sound settings to activate it. The browser switches the output
	// automatically the moment the device materializes.
	[[AirPlayServiceBrowser sharedBrowser] armPendingSwitchForDeviceName:name];
	[self openSoundSettings:sender];
}

- (void)openSoundSettings:(id)sender {
	[[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.sound"]];
}

@end
