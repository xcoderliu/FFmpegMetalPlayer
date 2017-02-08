//
//  LzmMediaDecoder.h
//  LzmPlayer
//
//  Created by 刘智民 on 2/6/17.
//  Copyright © 2017 刘智民. All rights reserved.
//

#import <Cocoa/Cocoa.h>
#import <CoreGraphics/CoreGraphics.h>
extern NSString * lzmMediaErrorDomain;

typedef enum {
    lzmMediaErrorNone,
    lzmMediaErrorOpenFile,
    lzmMediaErrorStreamInfoNotFound,
    lzmMediaErrorStreamNotFound,
    lzmMediaErrorCodecNotFound,
    lzmMediaErrorOpenCodec,
    lzmMediaErrorAllocateFrame,
    lzmMediaErroSetupScaler,
    lzmMediaErroReSampler,
    lzmMediaErroUnsupported,
    
} lzmMediaError;

typedef enum {
    lzmMediaFrameTypeAudio,
    lzmMediaFrameTypeVideo,
    lzmMediaFrameTypeArtwork,
    lzmMediaFrameTypeSubtitle,
    
} lzmMediaFrameType;

typedef enum {
    lzmVideoFrameFormatRGB,
    lzmVideoFrameFormatYUV,
    
} lzmVideoFrameFormat;

@interface lzmMediaFrame : NSObject
@property (readonly, nonatomic) lzmMediaFrameType type;
@property (readonly, nonatomic) CGFloat position;
@property (readonly, nonatomic) CGFloat duration;
@end

@interface lzmAudioFrame : lzmMediaFrame
@property (readonly, nonatomic, strong) NSData *samples;
@end

@interface lzmVideoFrame : lzmMediaFrame
@property (readonly, nonatomic) lzmVideoFrameFormat format;
@property (readonly, nonatomic) GLsizei width;
@property (readonly, nonatomic) GLsizei height;
@end

@interface lzmVideoFrameRGB : lzmVideoFrame
@property (readonly, nonatomic) NSUInteger linesize;
@property (readonly, nonatomic, strong) NSData *rgb;
- (NSImage *) asImage;
@end

@interface lzmVideoFrameYUV : lzmVideoFrame
@property (readonly, nonatomic, strong) NSData *luma;
@property (readonly, nonatomic, strong) NSData *chromaB;
@property (readonly, nonatomic, strong) NSData *chromaR;
@end

@interface lzmArtworkFrame : lzmMediaFrame
@property (readonly, nonatomic, strong) NSData *picture;
- (NSImage *) asImage;
@end

@interface lzmSubtitleFrame : lzmMediaFrame
@property (readonly, nonatomic, strong) NSString *text;
@end

typedef BOOL(^lzmMediaDecoderInterruptCallback)();

@interface LzmMediaDecoder : NSObject
@property (readonly, nonatomic, strong) NSString *path;
@property (readonly, nonatomic) BOOL isEOF;
@property (readwrite,nonatomic) CGFloat position;
@property (readonly, nonatomic) CGFloat duration;
@property (readonly, nonatomic) CGFloat fps;
@property (readonly, nonatomic) CGFloat sampleRate;
@property (readonly, nonatomic) NSUInteger frameWidth;
@property (readonly, nonatomic) NSUInteger frameHeight;
@property (readonly, nonatomic) NSUInteger audioStreamsCount;
@property (readwrite,nonatomic) NSInteger selectedAudioStream;
@property (readonly, nonatomic) NSUInteger subtitleStreamsCount;
@property (readwrite,nonatomic) NSInteger selectedSubtitleStream;
@property (readonly, nonatomic) BOOL validVideo;
@property (readonly, nonatomic) BOOL validAudio;
@property (readonly, nonatomic) BOOL validSubtitles;
@property (readonly, nonatomic, strong) NSDictionary *info;
@property (readonly, nonatomic, strong) NSString *videoStreamFormatName;
@property (readonly, nonatomic) BOOL isNetwork;
@property (readonly, nonatomic) CGFloat startTime;
@property (readwrite, nonatomic) BOOL disableDeinterlacing;
@property (readwrite, nonatomic, strong) lzmMediaDecoderInterruptCallback interruptCallback;

+ (id) movieDecoderWithContentPath: (NSString *) path
                             error: (NSError **) perror;

- (BOOL) openFile: (NSString *) path
            error: (NSError **) perror;

-(void) closeFile;

- (BOOL) setupVideoFrameFormat: (lzmVideoFrameFormat) format;

- (NSArray *) decodeFrames: (CGFloat) minDuration;

@end

@interface lzmMediaSubtitleASSParser : NSObject

+ (NSArray *) parseEvents: (NSString *) events;
+ (NSArray *) parseDialogue: (NSString *) dialogue
                  numFields: (NSUInteger) numFields;
+ (NSString *) removeCommandsFromEventText: (NSString *) text;
@end
