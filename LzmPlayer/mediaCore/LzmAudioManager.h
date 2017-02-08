//
//  LzmAudioManager.h
//  LzmPlayer
//
//  Created by 刘智民 on 2/6/17.
//  Copyright © 2017 刘智民. All rights reserved.
//

#import <Cocoa/Cocoa.h>

typedef void (^LzmAudioManagerOutputBlock)(float *data, UInt32 numFrames, UInt32 numChannels);

@protocol LzmAudioManager <NSObject>

@property (readonly) UInt32             numOutputChannels;
@property (readonly) Float64            samplingRate;
@property (readonly) UInt32             numBytesPerSample;
@property (readonly) Float32            outputVolume;
@property (readonly) BOOL               playing;
@property (readonly, strong) NSString   *audioRoute;

@property (readwrite, copy) LzmAudioManagerOutputBlock outputBlock;

- (BOOL) activateAudioSession;
- (void) deactivateAudioSession;
- (BOOL) play;
- (void) pause;

@end

@interface LzmAudioManager : NSObject
//+ (id<LzmAudioManager>) audioManager;
@end
