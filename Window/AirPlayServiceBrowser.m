//
//  AirPlayServiceBrowser.m
//  Cog
//

#import "AirPlayServiceBrowser.h"

#import <CoreAudio/AudioHardware.h>

#import <CogAudio/OutputDeviceRouting.h>
#import <Network/Network.h>

#import "Logging.h"

NSNotificationName const AirPlayServiceBrowserDidUpdateNotification = @"AirPlayServiceBrowserDidUpdateNotification";

@implementation AirPlayServiceBrowser {
	nw_browser_t browser;
	NSMutableSet<NSString *> *names;
	NSInteger browseRefCount;
	NSString *pendingName;
	BOOL halListenerInstalled;
	BOOL writingSelection;
	AudioObjectPropertyListenerBlock halListenerBlock;
	NSDictionary *lastSeenSelection;
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
	// Refcounted: browsing runs while at least one picker holds a begin.
	++browseRefCount;
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
	// Release this picker's hold after a ~5 s grace so a prompt re-open reuses
	// the warm browser; stop only when the last hold is released.
	__weak AirPlayServiceBrowser *weakSelf = self;
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
		AirPlayServiceBrowser *strongSelf = weakSelf;
		if(!strongSelf) return;
		if(strongSelf->browseRefCount > 0) --strongSelf->browseRefCount;
		if(strongSelf->browseRefCount > 0) return;
		if(strongSelf->browser) {
			nw_browser_cancel(strongSelf->browser);
			strongSelf->browser = NULL;
		}
		// Notify consumers so an open picker refreshes instead of showing the
		// now-cleared names.
		if([strongSelf->names count]) {
			[strongSelf->names removeAllObjects];
			[[NSNotificationCenter defaultCenter] postNotificationName:AirPlayServiceBrowserDidUpdateNotification object:strongSelf];
		}
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
	// macOS materializes a single generic bridge device (transport airp,
	// literally named "AirPlay") that follows the system's AirPlay route; it
	// never carries the sink's Bonjour name. Prefer an exact name match in
	// case that ever changes, but fall back to any live AirPlay-transport
	// device: while a switch is armed, whatever bridge appears is the route
	// the user just activated.
	AudioDeviceID matched = CogDeviceIDMatchingName(pendingName);
	if(matched == kAudioObjectUnknown || CogDeviceTransportType(matched) != kAudioDeviceTransportTypeAirPlay) {
		matched = CogFirstAirPlayDeviceID();
	}
	if(matched == kAudioObjectUnknown) return;

	DLog(@"Pending AirPlay sink \"%@\" reachable via device %u; switching output", pendingName, matched);
	[self disarmPendingSwitch];
	// Store the bridge's real device name, not the Bonjour name: bridge IDs
	// churn across materializations, and the name fallback in the output
	// backends only works if the stored name matches an actual device.
	NSString *deviceName = CogDeviceName(matched) ?: @"AirPlay";
	writingSelection = YES;
	[[NSUserDefaults standardUserDefaults] setObject:@{ @"name": deviceName, @"deviceID": @((int)matched) }
	                                          forKey:@"outputDevice"];
	writingSelection = NO;
}

@end
