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

// Pending auto-switch: remembers an un-materialized sink the user picked and
// selects it the moment macOS materializes a matching AirPlay CoreAudio
// device. Armed until superseded (any other outputDevice selection or a
// newer pick) or app quit. Session-scoped; never persisted.
- (void)armPendingSwitchForDeviceName:(NSString *)name;
@property (nonatomic, readonly, nullable) NSString *pendingDeviceName;

@end

NS_ASSUME_NONNULL_END
