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
	BOOL flushNotificationObserverApplied;
	BOOL outputdevicechanged;

	BOOL rendererFailed;
	BOOL rendererFlushedAutomatically;

	BOOL DSPsLaunched;

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
