//
//  LzmAudioManager.m
//  LzmPlayer
//
//  Created by 刘智民 on 2/6/17.
//  Copyright © 2017 刘智民. All rights reserved.
//

#import "LzmAudioManager.h"
#import "TargetConditionals.h"
#import <AudioToolbox/AudioToolbox.h>
#import <Accelerate/Accelerate.h>

#define MAX_FRAME_SIZE 4096
#define MAX_CHAN       2

#define MAX_SAMPLE_DUMPED 5

static BOOL checkError(OSStatus error, const char *operation);
static void sessionPropertyListener(void *inClientData, AudioFilePropertyID inID, UInt32 inDataSize, const void *inData);
static void sessionInterruptionListener(void *inClientData, UInt32 inInterruption);
static OSStatus renderCallback (void *inRefCon, AudioUnitRenderActionFlags	*ioActionFlags, const AudioTimeStamp * inTimeStamp, UInt32 inOutputBusNumber, UInt32 inNumberFrames, AudioBufferList* ioData);

@implementation LzmAudioManager

@end
