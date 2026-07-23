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
			DLog(@"AirPlay renderer failed: %@", [audioRenderer error]);

			// If an explicit AirPlay device was selected, fall back to the
			// system default. This retriggers device observers everywhere,
			// including the backend re-selection in AudioPlayer if the resolved
			// default route is not AirPlay (that path rebuilds the whole output
			// via KVO/restart).
			NSDictionary *device = [[[NSUserDefaultsController sharedUserDefaultsController] defaults] objectForKey:@"outputDevice"];
			if(device) {
				DLog(@"AirPlay renderer recovery: clearing explicit device, falling back to system default");
				dispatch_async(dispatch_get_main_queue(), ^{
					[[[NSUserDefaultsController sharedUserDefaultsController] defaults] removeObjectForKey:@"outputDevice"];
				});
			}

			// Always flag the renderer dead so the feeder thread recreates it in
			// place. This covers the quadrants where the fallback yields no
			// backend-class change (default absent, or default still AirPlay),
			// where the KVO/restart flow above would otherwise never fire.
			DLog(@"AirPlay renderer recovery: flagging renderer for in-place rebuild");
			[currentPtsLock lock];
			rendererFailed = YES;
			[currentPtsLock unlock];
		}
	}
}

- (void)rendererWasFlushedAutomatically:(NSNotification *)notification {
	// The system flushed the renderer out from under us (route hiccup); our
	// outputPts bookkeeping still believes ~2 s is enqueued, which would stall
	// enqueue gating until currentPts catches up. Flag the feeder thread to
	// reset PTS/prebuffer bookkeeping instead of doing heavy work here on the
	// notification queue.
	DLog(@"AirPlay renderer was flushed automatically; resetting enqueue bookkeeping");
	[currentPtsLock lock];
	rendererFlushedAutomatically = YES;
	[currentPtsLock unlock];
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
	secondsLatency = 0.0;
	[currentPtsLock unlock];

	started = NO;
	restarted = NO;

	prebufferReached = NO;
	prebufferSignaled = NO;

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

			// Renderer self-heal, driven off flags the KVO status observer and
			// the automatic-flush notification set. A dead renderer wins over an
			// automatic flush (the rebuild resets the same bookkeeping).
			BOOL doRebuild;
			BOOL doAutoFlush;
			[currentPtsLock lock];
			doRebuild = rendererFailed;
			doAutoFlush = rendererFlushedAutomatically;
			rendererFailed = NO;
			rendererFlushedAutomatically = NO;
			[currentPtsLock unlock];
			if(doRebuild) {
				[self rebuildRenderer];
			} else if(doAutoFlush) {
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

			// Auto-start once the prebuffer fills. The started check alone is
			// not enough: a user resume racing an in-place rebuild can set rate
			// on the dead synchronizer and leave started == YES, so a live
			// synchronizer still sitting at rate 0 also needs the restart here.
			if(!paused && prebufferReached && (!started || [renderSynchronizer rate] == 0)) {
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
	__weak OutputAirPlay *weakSelf = self;
	currentPtsObserver = [renderSynchronizer addPeriodicTimeObserverForInterval:interval
	                                                                      queue:NULL
	                                                                 usingBlock:^(CMTime time) {
		                                                                 OutputAirPlay *strongSelf = weakSelf;
		                                                                 if(!strongSelf) return;

		                                                                 OutputNode *localOutputController;
		                                                                 VisualizationController *localVisController;
		                                                                 double latencySeconds;
		                                                                 double enqueuedTimestamp;

		                                                                 [lock lock];
		                                                                 strongSelf->currentPts = time;
		                                                                 CMTime latencyTime = CMTimeSubtract(strongSelf->outputPts, time);
		                                                                 enqueuedTimestamp = strongSelf->lastEnqueuedStreamTimestamp;
		                                                                 latencySeconds = CMTimeGetSeconds(latencyTime);
		                                                                 if(latencySeconds < 0)
			                                                                 latencySeconds = 0;
		                                                                 strongSelf->secondsLatency = latencySeconds;
		                                                                 localOutputController = strongSelf->outputController;
		                                                                 localVisController = strongSelf->visController;
		                                                                 [lock unlock];

		                                                                 if(enqueuedTimestamp > 0) {
			                                                                 double position = enqueuedTimestamp - latencySeconds;
			                                                                 if(position > 0) {
				                                                                 [localOutputController setAmountPlayed:position];
			                                                                 }
		                                                                 }
		                                                                 [localVisController postLatency:[localOutputController getVisLatency]];
		                                                                 [localVisController postFullLatency:[localOutputController getTotalLatency]];
	                                                                 }];
}

- (void)removeSynchronizerBlock {
	if(renderSynchronizer && currentPtsObserver) {
		[renderSynchronizer removeTimeObserver:currentPtsObserver];
		currentPtsObserver = nil;
	}
}

// Construct the AVSampleBufferAudioRenderer + AVSampleBufferRenderSynchronizer
// pair and wire every observer the running backend depends on. Shared by the
// setup path and the in-place failure rebuild so both produce identically wired
// renderers. Callers hold @synchronized(self).
- (BOOL)buildRenderer {
	audioRenderer = [AVSampleBufferAudioRenderer new];
	renderSynchronizer = [AVSampleBufferRenderSynchronizer new];

	if(audioRenderer == nil || renderSynchronizer == nil)
		return NO;

	// Re-resolve the output device from current defaults and bind it to the
	// freshly created renderer.
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

	// setOutputDeviceByID short-circuits when the resolved device ID is
	// unchanged, so force the UID onto this brand-new renderer.
	NSString *deviceUID = CogDeviceUID(outputDeviceID);
	if(deviceUID) {
		[audioRenderer setAudioOutputDeviceUniqueID:deviceUID];
	}

	[audioRenderer addObserver:self forKeyPath:@"status" options:0 context:kOutputAirPlayContext];
	rendererStatusObserverApplied = YES;

	[[NSNotificationCenter defaultCenter] addObserver:self
	                                         selector:@selector(rendererWasFlushedAutomatically:)
	                                             name:AVSampleBufferAudioRendererWasFlushedAutomaticallyNotification
	                                           object:audioRenderer];
	flushNotificationObserverApplied = YES;

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

// Tear down a failed renderer/synchronizer pair and recreate it in place on the
// feeder thread, so a route-death that does not cross a backend-class boundary
// still recovers to a working renderer. Runs under @synchronized(self) to
// serialize with doStop's teardown.
- (void)rebuildRenderer {
	@synchronized(self) {
		if(stopping || stopInvoked)
			return;

		DLog(@"AirPlay renderer rebuild: recreating failed renderer in place");

		// Detach the periodic block and observers from the dead objects.
		[self removeSynchronizerBlock];
		if(rendererStatusObserverApplied) {
			[audioRenderer removeObserver:self forKeyPath:@"status" context:kOutputAirPlayContext];
			rendererStatusObserverApplied = NO;
		}
		if(flushNotificationObserverApplied) {
			[[NSNotificationCenter defaultCenter] removeObserver:self name:AVSampleBufferAudioRendererWasFlushedAutomaticallyNotification object:audioRenderer];
			flushNotificationObserverApplied = NO;
		}

		// Halt and release the dead pair.
		[renderSynchronizer setRate:0];
		if(renderSynchronizer && audioRenderer) {
			[renderSynchronizer removeRenderer:audioRenderer atTime:kCMTimeZero completionHandler:nil];
		}
		if(audioRenderer) {
			[audioRenderer stopRequestingMediaData];
			[audioRenderer flush];
		}
		audioRenderer = nil;
		renderSynchronizer = nil;

		// Reset PTS/prebuffer bookkeeping so re-enqueue starts from zero and the
		// prebuffer-gated auto-start restarts the synchronizer once the fresh
		// renderer fills.
		[currentPtsLock lock];
		currentPts = kCMTimeZero;
		lastPts = kCMTimeZero;
		outputPts = kCMTimeZero;
		lastEnqueuedStreamTimestamp = 0.0;
		secondsLatency = 0.0;
		[currentPtsLock unlock];

		started = NO;
		restarted = NO;
		prebufferReached = NO;
		prebufferSignaled = NO;

		if(![self buildRenderer]) {
			DLog(@"AirPlay renderer rebuild: replacement renderer creation failed");
			return;
		}

		DLog(@"AirPlay renderer rebuild: replacement renderer live, awaiting prebuffer to resume");
	}
}

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

		visController = [VisualizationController sharedController];

		// Create and wire the renderer/synchronizer pair (also resolves the
		// output device against current defaults).
		if(![self buildRenderer])
			return NO;

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
	double latencySnapshot;
	[currentPtsLock lock];
	latencySnapshot = secondsLatency;
	[currentPtsLock unlock];
	double renderer = latencySnapshot > 0 ? latencySnapshot : 0;
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
	// Phase 1 (monitor held): publish the stop request and detach every observer
	// and CoreAudio listener, atomically with respect to the feeder thread's own
	// monitor-guarded work (rebuildRenderer). We MUST NOT wait for the feeder to
	// exit while holding the monitor: the feeder acquires this same monitor on
	// entry to rebuildRenderer, and a feeder blocked there would never reach the
	// point where it publishes `stopped`, deadlocking this busy-wait.
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
		if(flushNotificationObserverApplied) {
			[[NSNotificationCenter defaultCenter] removeObserver:self name:AVSampleBufferAudioRendererWasFlushedAutomaticallyNotification object:audioRenderer];
			flushNotificationObserverApplied = NO;
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
	}

	// Phase 2 (monitor released): join the feeder thread. With `stopping`
	// published and the monitor free, a feeder about to rebuild early-returns
	// from rebuildRenderer, and a feeder anywhere in its loop hits `if(stopping)
	// break`; either way it reaches `stopped = YES`. The renderer is still alive
	// here, so nothing the feeder touches while draining has been freed yet.
	if(running) {
		while(!stopped) {
			stopping = YES;
			usleep(5000);
		}
	}

	// Phase 3 (monitor re-acquired): the feeder has exited (or never launched),
	// so teardown can no longer race it. Drain any audio still queued in the live
	// renderer, then release the renderer/synchronizer pair and the rest of the
	// graph. Re-entering the monitor keeps this serialized against a concurrent
	// doStop (benign, idempotent) and any lingering monitor-guarded caller.
	@synchronized(self) {
		if(renderSynchronizer || audioRenderer) {
			if(renderSynchronizer) {
				if(shouldPlayOutBuffer && !commandStop) {
					int compareVal = 0;
					double drainLatency;
					[currentPtsLock lock];
					drainLatency = self->secondsLatency >= 0 ? self->secondsLatency : 0;
					[currentPtsLock unlock];
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
		[currentPtsLock lock];
		outputController = nil;
		VisualizationController *localVisController = visController;
		visController = nil;
		[currentPtsLock unlock];
		if(localVisController) {
			[localVisController reset];
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
	// Never advance the timeline before the prebuffer has filled, or the first
	// chunks play out against an empty renderer and get dropped. If we are still
	// inside the prebuffer window (user unpaused early, playback started paused,
	// or a renderer rebuild is refilling), just clear paused and let the feeder
	// thread's auto-start (!started && !paused && prebufferReached) start the
	// synchronizer once the prebuffer is reached.
	if(!prebufferReached) {
		paused = NO;
		return;
	}
	CMTime resumePts;
	[currentPtsLock lock];
	resumePts = currentPts;
	[currentPtsLock unlock];
	[renderSynchronizer setRate:1.0 time:resumePts];
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
