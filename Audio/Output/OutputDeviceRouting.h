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
double CogDeviceOutputLatencySeconds(AudioDeviceID deviceID);
AudioDeviceID CogDeviceIDMatchingName(NSString *_Nullable name);
BOOL CogOutputDeviceDictIsAirPlay(NSDictionary *_Nullable deviceDict);

NS_ASSUME_NONNULL_END
