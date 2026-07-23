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
