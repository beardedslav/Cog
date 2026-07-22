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
