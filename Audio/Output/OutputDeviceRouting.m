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

AudioDeviceID CogDeviceIDMatchingName(NSString *name) {
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

double CogDeviceOutputLatencySeconds(AudioDeviceID deviceID) {
	AudioObjectPropertyAddress theAddress = {
		.mSelector = kAudioDevicePropertyLatency,
		.mScope = kAudioDevicePropertyScopeOutput,
		.mElement = kAudioObjectPropertyElementMaster
	};

	UInt32 latencyFrames = 0;
	UInt32 value = 0;
	UInt32 size = sizeof(value);
	if(AudioObjectGetPropertyData(deviceID, &theAddress, 0, NULL, &size, &value) == noErr) {
		latencyFrames += value;
	}

	theAddress.mSelector = kAudioDevicePropertySafetyOffset;
	value = 0;
	size = sizeof(value);
	if(AudioObjectGetPropertyData(deviceID, &theAddress, 0, NULL, &size, &value) == noErr) {
		latencyFrames += value;
	}

	// AirPlay bridge devices report their whole network buffer (~2 s) as
	// stream latency on the first output stream, not on the device itself.
	theAddress.mSelector = kAudioDevicePropertyStreams;
	UInt32 propsize = 0;
	if(AudioObjectGetPropertyDataSize(deviceID, &theAddress, 0, NULL, &propsize) == noErr && propsize >= sizeof(AudioStreamID)) {
		AudioStreamID *streams = (AudioStreamID *)malloc(propsize);
		if(streams) {
			if(AudioObjectGetPropertyData(deviceID, &theAddress, 0, NULL, &propsize, streams) == noErr) {
				AudioObjectPropertyAddress streamAddress = {
					.mSelector = kAudioStreamPropertyLatency,
					.mScope = kAudioObjectPropertyScopeGlobal,
					.mElement = kAudioObjectPropertyElementMaster
				};
				value = 0;
				size = sizeof(value);
				if(AudioObjectGetPropertyData(streams[0], &streamAddress, 0, NULL, &size, &value) == noErr) {
					latencyFrames += value;
				}
			}
			free(streams);
		}
	}

	if(!latencyFrames) {
		return 0.0;
	}

	theAddress.mSelector = kAudioDevicePropertyNominalSampleRate;
	theAddress.mScope = kAudioObjectPropertyScopeGlobal;
	Float64 sampleRate = 0;
	size = sizeof(sampleRate);
	if(AudioObjectGetPropertyData(deviceID, &theAddress, 0, NULL, &size, &sampleRate) != noErr || sampleRate <= 0) {
		return 0.0;
	}

	return latencyFrames / sampleRate;
}

BOOL CogOutputDeviceDictIsAirPlay(NSDictionary *deviceDict) {
	AudioDeviceID deviceID = kAudioObjectUnknown;

	NSNumber *deviceIDNum = deviceDict ? [deviceDict objectForKey:@"deviceID"] : nil;
	int storedID = deviceIDNum ? [deviceIDNum intValue] : -1;

	if(storedID != -1) {
		if(deviceIsAlive((AudioDeviceID)storedID)) {
			deviceID = (AudioDeviceID)storedID;
		} else {
			deviceID = CogDeviceIDMatchingName([deviceDict objectForKey:@"name"]);
		}
	}

	if(deviceID == kAudioObjectUnknown) {
		if(CogResolveDefaultOutputDevice(&deviceID) != noErr) {
			return NO;
		}
	}

	return CogDeviceTransportType(deviceID) == kAudioDeviceTransportTypeAirPlay;
}
