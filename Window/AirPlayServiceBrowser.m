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
