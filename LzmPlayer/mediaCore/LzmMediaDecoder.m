//
//  LzmMediaDecoder.m
//  LzmPlayer
//
//  Created by 刘智民 on 2/6/17.
//  Copyright © 2017 刘智民. All rights reserved.
//

#import "LzmMediaDecoder.h"
#import "LzmAudioManager.h"
#include "libavformat/avformat.h"
#include "libswscale/swscale.h"
#include "libswresample/swresample.h"
#include "libavutil/pixdesc.h"
#include "libavfilter/avfilter.h"

////////////////////////////////////////////////////////////////////////////////

NSString * lzmMediaErrorDomain = @"xyz.xcoderliu.lzmplayer";

static NSError * lzmmediaError (NSInteger code, id info)
{
    NSDictionary *userInfo = nil;
    
    if ([info isKindOfClass: [NSDictionary class]]) {
        
        userInfo = info;
        
    } else if ([info isKindOfClass: [NSString class]]) {
        
        userInfo = @{ NSLocalizedDescriptionKey : info };
    }
    
    return [NSError errorWithDomain:lzmMediaErrorDomain
                               code:code
                           userInfo:userInfo];
}

static NSString * errorMessage (lzmMediaError errorCode)
{
    switch (errorCode) {
        case lzmMediaErrorNone:
            return @"";
            
        case lzmMediaErrorOpenFile:
            return NSLocalizedString(@"Unable to open file", nil);
            
        case lzmMediaErrorStreamInfoNotFound:
            return NSLocalizedString(@"Unable to find stream information", nil);
            
        case lzmMediaErrorStreamNotFound:
            return NSLocalizedString(@"Unable to find stream", nil);
            
        case lzmMediaErrorCodecNotFound:
            return NSLocalizedString(@"Unable to find codec", nil);
            
        case lzmMediaErrorOpenCodec:
            return NSLocalizedString(@"Unable to open codec", nil);
            
        case lzmMediaErrorAllocateFrame:
            return NSLocalizedString(@"Unable to allocate frame", nil);
            
        case lzmMediaErroSetupScaler:
            return NSLocalizedString(@"Unable to setup scaler", nil);
            
        case lzmMediaErroReSampler:
            return NSLocalizedString(@"Unable to setup resampler", nil);
            
        case lzmMediaErroUnsupported:
            return NSLocalizedString(@"The ability is not supported", nil);
    }
}

////////////////////////////////////////////////////////////////////////////////
static void avStreamFPSTimeBase(AVStream *st, CGFloat defaultTimeBase, CGFloat *pFPS, CGFloat *pTimeBase)
{
    CGFloat fps, timebase;
    
    if (st->time_base.den && st->time_base.num)
        timebase = av_q2d(st->time_base);
    else
        timebase = defaultTimeBase;
    
    if (st->avg_frame_rate.den && st->avg_frame_rate.num)
        fps = av_q2d(st->avg_frame_rate);
    else if (st->r_frame_rate.den && st->r_frame_rate.num)
        fps = av_q2d(st->r_frame_rate);
    else
        fps = 1.0 / timebase;
    
    if (pFPS)
        *pFPS = fps;
    if (pTimeBase)
        *pTimeBase = timebase;
}

static NSArray *collectStreams(AVFormatContext *formatCtx, enum AVMediaType codecType)
{
    NSMutableArray *ma = [NSMutableArray array];
    for (NSInteger i = 0; i < formatCtx->nb_streams; ++i)
        if (codecType == formatCtx->streams[i]->codec->codec_type)
            [ma addObject: [NSNumber numberWithInteger: i]];
    return [ma copy];
}

static NSData * copyFrameData(UInt8 *src, int linesize, int width, int height)
{
    width = MIN(linesize, width);
    NSMutableData *md = [NSMutableData dataWithLength: width * height];
    Byte *dst = md.mutableBytes;
    for (NSUInteger i = 0; i < height; ++i) {
        memcpy(dst, src, width);
        dst += width;
        src += linesize;
    }
    return md;
}

static BOOL isNetworkPath (NSString *path)
{
    NSRange r = [path rangeOfString:@":"];
    if (r.location == NSNotFound)
        return NO;
    NSString *scheme = [path substringToIndex:r.length];
    if ([scheme isEqualToString:@"file"])
        return NO;
    return YES;
}

static int interrupt_callback(void *ctx);

////////////////////////////////////////////////////////////////////////////////

@interface lzmMediaFrame()
@property (readwrite, nonatomic) CGFloat position;
@property (readwrite, nonatomic) CGFloat duration;
@end

@implementation lzmMediaFrame
@end

@interface lzmAudioFrame()
@property (readwrite, nonatomic, strong) NSData *samples;
@end

@implementation lzmAudioFrame
- (lzmMediaFrameType) type { return lzmMediaFrameTypeAudio; }
@end

@interface lzmVideoFrame()
@property (readwrite, nonatomic) GLsizei width;
@property (readwrite, nonatomic) GLsizei height;
@end

@implementation lzmVideoFrame
- (lzmMediaFrameType) type { return lzmMediaFrameTypeVideo; }
@end

@interface lzmVideoFrameRGB ()
@property (readwrite, nonatomic) NSUInteger linesize;
@property (readwrite, nonatomic, strong) NSData *rgb;
@end

@implementation lzmVideoFrameRGB
- (lzmVideoFrameFormat) format { return lzmVideoFrameFormatRGB; }
- (NSImage *) asImage
{
    NSImage *image = nil;
    
    CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)(_rgb));
    if (provider) {
        CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
        if (colorSpace) {
            CGImageRef imageRef = CGImageCreate(self.width,
                                                self.height,
                                                8,
                                                24,
                                                self.linesize,
                                                colorSpace,
                                                kCGBitmapByteOrderDefault,
                                                provider,
                                                NULL,
                                                YES, // NO
                                                kCGRenderingIntentDefault);
            
            if (imageRef) {
                image = [[NSImage alloc] initWithCGImage:imageRef size:NSMakeSize(CGImageGetWidth(imageRef), CGImageGetHeight(imageRef))];
                CGImageRelease(imageRef);
            }
            CGColorSpaceRelease(colorSpace);
        }
        CGDataProviderRelease(provider);
    }
    
    return image;
}
@end

@interface lzmVideoFrameYUV()
@property (readwrite, nonatomic, strong) NSData *luma;
@property (readwrite, nonatomic, strong) NSData *chromaB;
@property (readwrite, nonatomic, strong) NSData *chromaR;
@end

@implementation lzmVideoFrameYUV
- (lzmVideoFrameFormat) format { return lzmVideoFrameFormatYUV; }
@end

@interface lzmArtworkFrame()
@property (readwrite, nonatomic, strong) NSData *picture;
@end

@implementation lzmArtworkFrame
- (lzmMediaFrameType) type { return lzmMediaFrameTypeArtwork; }
- (NSImage *) asImage
{
    NSImage *image = nil;
    
    CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)(_picture));
    if (provider) {
        
        CGImageRef imageRef = CGImageCreateWithJPEGDataProvider(provider,
                                                                NULL,
                                                                YES,
                                                                kCGRenderingIntentDefault);
        if (imageRef) {
            
            image = [[NSImage alloc] initWithCGImage:imageRef size:NSMakeSize(CGImageGetWidth(imageRef), CGImageGetHeight(imageRef))];
            CGImageRelease(imageRef);
        }
        CGDataProviderRelease(provider);
    }
    
    return image;
    
}
@end

@interface lzmSubtitleFrame()
@property (readwrite, nonatomic, strong) NSString *text;
@end

@implementation lzmSubtitleFrame
- (lzmMediaFrameType) type { return lzmMediaFrameTypeSubtitle; }
@end

////////////////////////////////////////////////////////////////////////////////

@interface LzmMediaDecoder () {
    
    AVFormatContext     *_formatCtx;
    AVCodecContext      *_videoCodecCtx;
    AVCodecContext      *_audioCodecCtx;
    AVCodecContext      *_subtitleCodecCtx;
    AVFrame             *_videoFrame;
    AVFrame             *_audioFrame;
    int                 _videoStream;
    int                 _audioStream;
    NSInteger           _subtitleStream;
    AVPicture           _picture;
    BOOL                _pictureValid;
    struct SwsContext   *_swsContext;
    CGFloat             _videoTimeBase;
    CGFloat             _audioTimeBase;
    CGFloat             _position;
    NSArray             *_videoStreams;
    NSArray             *_audioStreams;
    NSArray             *_subtitleStreams;
    SwrContext          *_swrContext;
    void                *_swrBuffer;
    NSUInteger          _swrBufferSize;
    NSDictionary        *_info;
    lzmVideoFrameFormat  _videoFrameFormat;
    NSUInteger          _artworkStream;
    NSInteger           _subtitleASSEvents;
}

@end


@implementation LzmMediaDecoder
@dynamic duration;
@dynamic position;
@dynamic frameWidth;
@dynamic frameHeight;
@dynamic sampleRate;
@dynamic audioStreamsCount;
@dynamic subtitleStreamsCount;
@dynamic selectedAudioStream;
@dynamic selectedSubtitleStream;
@dynamic validAudio;
@dynamic validVideo;
@dynamic validSubtitles;
@dynamic info;
@dynamic videoStreamFormatName;
@dynamic startTime;

- (CGFloat) duration
{
    if (!_formatCtx)
        return 0;
    if (_formatCtx->duration == AV_NOPTS_VALUE)
        return MAXFLOAT;
    return (CGFloat)_formatCtx->duration / AV_TIME_BASE;
}

- (CGFloat) position
{
    return _position;
}

- (void) setPosition: (CGFloat)seconds
{
    _position = seconds;
    _isEOF = NO;
	   
    if (_videoStream != -1) {
        int64_t ts = (int64_t)(seconds / _videoTimeBase);
        avformat_seek_file(_formatCtx, _videoStream, ts, ts, ts, AVSEEK_FLAG_FRAME);
        avcodec_flush_buffers(_videoCodecCtx);
    }
    
    if (_audioStream != -1) {
        int64_t ts = (int64_t)(seconds / _audioTimeBase);
        avformat_seek_file(_formatCtx, _audioStream, ts, ts, ts, AVSEEK_FLAG_FRAME);
        avcodec_flush_buffers(_audioCodecCtx);
    }
}

- (int) frameWidth
{
    return _videoCodecCtx ? _videoCodecCtx->width : 0;
}

- (int) frameHeight
{
    return _videoCodecCtx ? _videoCodecCtx->height : 0;
}

- (CGFloat) sampleRate
{
    return _audioCodecCtx ? _audioCodecCtx->sample_rate : 0;
}

- (NSUInteger) audioStreamsCount
{
    return [_audioStreams count];
}

- (NSUInteger) subtitleStreamsCount
{
    return [_subtitleStreams count];
}

- (NSInteger) selectedAudioStream
{
    if (_audioStream == -1)
        return -1;
    NSNumber *n = [NSNumber numberWithInteger:_audioStream];
    return [_audioStreams indexOfObject:n];
}

- (void) setSelectedAudioStream:(NSInteger)selectedAudioStream
{
//    NSInteger audioStream = [_audioStreams[selectedAudioStream] integerValue];
//    [self closeAudioStream];
//    lzmMediaError errCode = [self openAudioStream: audioStream];
//    if (lzmMediaErrorNone != errCode) {
//        NSLog(@"%@", errorMessage(errCode));
//    }
}

- (NSInteger) selectedSubtitleStream
{
    if (_subtitleStream == -1)
        return -1;
    return [_subtitleStreams indexOfObject:@(_subtitleStream)];
}

- (void) setSelectedSubtitleStream:(NSInteger)selected
{
    [self closeSubtitleStream];
    
    if (selected == -1) {
        
        _subtitleStream = -1;
        
    } else {
        
        NSInteger subtitleStream = [_subtitleStreams[selected] integerValue];
        lzmMediaError errCode = [self openSubtitleStream:subtitleStream];
        if (lzmMediaErrorNone != errCode) {
            NSLog(@"%@", errorMessage(errCode));
        }
    }
}

- (BOOL) validAudio
{
    return _audioStream != -1;
}

- (BOOL) validVideo
{
    return _videoStream != -1;
}

- (BOOL) validSubtitles
{
    return _subtitleStream != -1;
}

- (NSDictionary *) info
{
    if (!_info) {
        
        NSMutableDictionary *md = [NSMutableDictionary dictionary];
        
        if (_formatCtx) {
            
            const char *formatName = _formatCtx->iformat->name;
            [md setValue: [NSString stringWithCString:formatName encoding:NSUTF8StringEncoding]
                  forKey: @"format"];
            
            if (_formatCtx->bit_rate) {
                
                [md setValue: [NSNumber numberWithInt:_formatCtx->bit_rate]
                      forKey: @"bitrate"];
            }
            
            if (_formatCtx->metadata) {
                
                NSMutableDictionary *md1 = [NSMutableDictionary dictionary];
                
                AVDictionaryEntry *tag = NULL;
                while((tag = av_dict_get(_formatCtx->metadata, "", tag, AV_DICT_IGNORE_SUFFIX))) {
                    
                    [md1 setValue: [NSString stringWithCString:tag->value encoding:NSUTF8StringEncoding]
                           forKey: [NSString stringWithCString:tag->key encoding:NSUTF8StringEncoding]];
                }
                
                [md setValue: [md1 copy] forKey: @"metadata"];
            }
            
            char buf[256];
            
            if (_videoStreams.count) {
                NSMutableArray *ma = [NSMutableArray array];
                for (NSNumber *n in _videoStreams) {
                    AVStream *st = _formatCtx->streams[n.integerValue];
                    avcodec_string(buf, sizeof(buf), st->codec, 1);
                    NSString *s = [NSString stringWithCString:buf encoding:NSUTF8StringEncoding];
                    if ([s hasPrefix:@"Video: "])
                        s = [s substringFromIndex:@"Video: ".length];
                    [ma addObject:s];
                }
                md[@"video"] = ma.copy;
            }
            
            if (_audioStreams.count) {
                NSMutableArray *ma = [NSMutableArray array];
                for (NSNumber *n in _audioStreams) {
                    AVStream *st = _formatCtx->streams[n.integerValue];
                    
                    NSMutableString *ms = [NSMutableString string];
                    AVDictionaryEntry *lang = av_dict_get(st->metadata, "language", NULL, 0);
                    if (lang && lang->value) {
                        [ms appendFormat:@"%s ", lang->value];
                    }
                    
                    avcodec_string(buf, sizeof(buf), st->codec, 1);
                    NSString *s = [NSString stringWithCString:buf encoding:NSUTF8StringEncoding];
                    if ([s hasPrefix:@"Audio: "])
                        s = [s substringFromIndex:@"Audio: ".length];
                    [ms appendString:s];
                    
                    [ma addObject:ms.copy];
                }
                md[@"audio"] = ma.copy;
            }
            
            if (_subtitleStreams.count) {
                NSMutableArray *ma = [NSMutableArray array];
                for (NSNumber *n in _subtitleStreams) {
                    AVStream *st = _formatCtx->streams[n.integerValue];
                    
                    NSMutableString *ms = [NSMutableString string];
                    AVDictionaryEntry *lang = av_dict_get(st->metadata, "language", NULL, 0);
                    if (lang && lang->value) {
                        [ms appendFormat:@"%s ", lang->value];
                    }
                    
                    avcodec_string(buf, sizeof(buf), st->codec, 1);
                    NSString *s = [NSString stringWithCString:buf encoding:NSUTF8StringEncoding];
                    if ([s hasPrefix:@"Subtitle: "])
                        s = [s substringFromIndex:@"Subtitle: ".length];
                    [ms appendString:s];
                    
                    [ma addObject:ms.copy];
                }
                md[@"subtitles"] = ma.copy;
            }
            
        }
        
        _info = [md copy];
    }
    
    return _info;
}
- (NSString *) videoStreamFormatName
{
    if (!_videoCodecCtx)
        return nil;
    
    if (_videoCodecCtx->pix_fmt == AV_PIX_FMT_NONE)
        return @"";
    
    const char *name = av_get_pix_fmt_name(_videoCodecCtx->pix_fmt);
    return name ? [NSString stringWithCString:name encoding:NSUTF8StringEncoding] : @"?";
}

- (CGFloat) startTime
{
    if (_videoStream != -1) {
        
        AVStream *st = _formatCtx->streams[_videoStream];
        if (AV_NOPTS_VALUE != st->start_time)
            return st->start_time * _videoTimeBase;
        return 0;
    }
    
    if (_audioStream != -1) {
        
        AVStream *st = _formatCtx->streams[_audioStream];
        if (AV_NOPTS_VALUE != st->start_time)
            return st->start_time * _audioTimeBase;
        return 0;
    }
    
    return 0;
}

+ (void)initialize
{
    av_register_all();
    avformat_network_init();
}

+ (id) movieDecoderWithContentPath: (NSString *) path
                             error: (NSError **) perror
{
    LzmMediaDecoder *mp = [[LzmMediaDecoder alloc] init];
    if (mp) {
        [mp openFile:path error:perror];
    }
    return mp;
}

- (void) dealloc
{
    NSLog(@"%@ dealloc", self);
    [self closeFile];
}

#pragma mark - private

- (BOOL) openFile: (NSString *) path
            error: (NSError **) perror
{
    NSAssert(path, @"nil path");
    NSAssert(!_formatCtx, @"already open");
    
    _isNetwork = isNetworkPath(path);
    
    static BOOL needNetworkInit = YES;
    if (needNetworkInit && _isNetwork) {
        
        needNetworkInit = NO;
        avformat_network_init();
    }
    
    _path = path;
    
    lzmMediaError errCode = [self openInput: path];
    
    if (errCode == lzmMediaErrorNone) {
        
        lzmMediaError videoErr = [self openVideoStream];
        lzmMediaError audioErr = [self openAudioStream];
        
        _subtitleStream = -1;
        
        if (videoErr != lzmMediaErrorNone &&
            audioErr != lzmMediaErrorNone) {
            
            errCode = videoErr; // both fails
            
        } else {
            
            _subtitleStreams = collectStreams(_formatCtx, AVMEDIA_TYPE_SUBTITLE);
        }
    }
    
    if (errCode != lzmMediaErrorNone) {
        
        [self closeFile];
        NSString *errMsg = errorMessage(errCode);
        NSLog(@"%@, %@", errMsg, path.lastPathComponent);
        if (perror)
            *perror = lzmmediaError(errCode, errMsg);
        return NO;
    }
    
    return YES;
}

- (lzmMediaError) openInput: (NSString *) path
{
    AVFormatContext *formatCtx = NULL;
    
    if (_interruptCallback) {
        
        formatCtx = avformat_alloc_context();
        if (!formatCtx)
            return lzmMediaErrorOpenFile;
        
        AVIOInterruptCB cb = {interrupt_callback, (__bridge void *)(self)};
        formatCtx->interrupt_callback = cb;
    }
    int err_code = avformat_open_input(&formatCtx, [path cStringUsingEncoding:NSUTF8StringEncoding], NULL, NULL);
    if (err_code != 0) {
        if (formatCtx)
            avformat_free_context(formatCtx);
        char* buf[1024];
        av_strerror(err_code, buf, 1024);
        printf("Couldn't open file %s: %d(%s)", [path cStringUsingEncoding: NSUTF8StringEncoding], err_code, buf);
        return lzmMediaErrorOpenFile;
    }
    
    if (avformat_find_stream_info(formatCtx, NULL) < 0) {
        
        avformat_close_input(&formatCtx);
        return lzmMediaErrorStreamInfoNotFound;
    }
    
    av_dump_format(formatCtx, 0, [path.lastPathComponent cStringUsingEncoding: NSUTF8StringEncoding], false);
    
    _formatCtx = formatCtx;
    return lzmMediaErrorNone;
}

- (lzmMediaError) openVideoStream
{
    lzmMediaError errCode = lzmMediaErrorStreamNotFound;
    _videoStream = -1;
    _artworkStream = -1;
    _videoStreams = collectStreams(_formatCtx, AVMEDIA_TYPE_VIDEO);
    for (NSNumber *n in _videoStreams) {
        
        const NSUInteger iStream = n.integerValue;
        
        if (0 == (_formatCtx->streams[iStream]->disposition & AV_DISPOSITION_ATTACHED_PIC)) {
            
            errCode = [self openVideoStream: iStream];
            if (errCode == lzmMediaErrorNone)
                break;
            
        } else {
            
            _artworkStream = iStream;
        }
    }
    
    return errCode;
}

- (lzmMediaError) openVideoStream: (NSInteger) videoStream
{
    // get a pointer to the codec context for the video stream
    AVCodecContext *codecCtx = _formatCtx->streams[videoStream]->codec;
    
    // find the decoder for the video stream
    AVCodec *codec = avcodec_find_decoder(codecCtx->codec_id);
    if (!codec)
        return lzmMediaErrorCodecNotFound;
    
    // inform the codec that we can handle truncated bitstreams -- i.e.,
    // bitstreams where frame boundaries can fall in the middle of packets
    //if(codec->capabilities & CODEC_CAP_TRUNCATED)
    //    _codecCtx->flags |= CODEC_FLAG_TRUNCATED;
    
    // open codec
    if (avcodec_open2(codecCtx, codec, NULL) < 0)
        return lzmMediaErrorOpenCodec;
    
    _videoFrame = av_frame_alloc();
    
    if (!_videoFrame) {
        avcodec_close(codecCtx);
        return lzmMediaErrorAllocateFrame;
    }
    
    _videoStream = videoStream;
    _videoCodecCtx = codecCtx;
    
    // determine fps
    
    AVStream *st = _formatCtx->streams[_videoStream];
    avStreamFPSTimeBase(st, 0.04, &_fps, &_videoTimeBase);
    
    NSLog(@"video codec size: %d:%d fps: %.3f tb: %f",
                self.frameWidth,
                self.frameHeight,
                _fps,
                _videoTimeBase);
    
    NSLog(@"video start time %f", st->start_time * _videoTimeBase);
    NSLog(@"video disposition %d", st->disposition);
    
    return lzmMediaErrorNone;
}

- (lzmMediaError) openAudioStream
{
    lzmMediaError errCode = lzmMediaErrorStreamNotFound;
    _audioStream = -1;
    _audioStreams = collectStreams(_formatCtx, AVMEDIA_TYPE_AUDIO);
    for (NSNumber *n in _audioStreams) {
        
//        errCode = [self openAudioStream: n.integerValue];
//        if (errCode == lzmMediaErrorNone)
//            break;
    }
    return errCode;
}

//- (lzmMediaError) openAudioStream: (NSInteger) audioStream
//{
//    AVCodecContext *codecCtx = _formatCtx->streams[audioStream]->codec;
//    SwrContext *swrContext = NULL;
//    
//    AVCodec *codec = avcodec_find_decoder(codecCtx->codec_id);
//    if(!codec)
//        return lzmMediaErrorCodecNotFound;
//    
//    if (avcodec_open2(codecCtx, codec, NULL) < 0)
//        return lzmMediaErrorOpenCodec;
//    
//    if (!audioCodecIsSupported(codecCtx)) {
//        
//        id<LzmAudioManager> audioManager = [LzmAudioManager audioManager];
//        swrContext = swr_alloc_set_opts(NULL,
//                                        av_get_default_channel_layout(audioManager.numOutputChannels),
//                                        AV_SAMPLE_FMT_S16,
//                                        audioManager.samplingRate,
//                                        av_get_default_channel_layout(codecCtx->channels),
//                                        codecCtx->sample_fmt,
//                                        codecCtx->sample_rate,
//                                        0,
//                                        NULL);
//        
//        if (!swrContext ||
//            swr_init(swrContext)) {
//            
//            if (swrContext)
//                swr_free(&swrContext);
//            avcodec_close(codecCtx);
//            
//            return lzmMediaErroReSampler;
//        }
//    }
//    
//    _audioFrame = av_frame_alloc();
//    
//    if (!_audioFrame) {
//        if (swrContext)
//            swr_free(&swrContext);
//        avcodec_close(codecCtx);
//        return lzmMediaErrorAllocateFrame;
//    }
//    
//    _audioStream = audioStream;
//    _audioCodecCtx = codecCtx;
//    _swrContext = swrContext;
//    
//    AVStream *st = _formatCtx->streams[_audioStream];
//    avStreamFPSTimeBase(st, 0.025, 0, &_audioTimeBase);
//    
//    NSLog(@"audio codec smr: %.d fmt: %d chn: %d tb: %f %@",
//                _audioCodecCtx->sample_rate,
//                _audioCodecCtx->sample_fmt,
//                _audioCodecCtx->channels,
//                _audioTimeBase,
//                _swrContext ? @"resample" : @"");
//    
//    return lzmMediaErrorNone;
//}

- (lzmMediaError) openSubtitleStream: (NSInteger) subtitleStream
{
    AVCodecContext *codecCtx = _formatCtx->streams[subtitleStream]->codec;
    
    AVCodec *codec = avcodec_find_decoder(codecCtx->codec_id);
    if(!codec)
        return lzmMediaErrorCodecNotFound;
    
    const AVCodecDescriptor *codecDesc = avcodec_descriptor_get(codecCtx->codec_id);
    if (codecDesc && (codecDesc->props & AV_CODEC_PROP_BITMAP_SUB)) {
        // Only text based subtitles supported
        return lzmMediaErroUnsupported;
    }
    
    if (avcodec_open2(codecCtx, codec, NULL) < 0)
        return lzmMediaErrorOpenCodec;
    
    _subtitleStream = subtitleStream;
    _subtitleCodecCtx = codecCtx;
    
    NSLog(@"subtitle codec: '%s' mode: %d enc: %s",
                 codecDesc->name,
                 codecCtx->sub_charenc_mode,
                 codecCtx->sub_charenc);
    
    _subtitleASSEvents = -1;
    
    if (codecCtx->subtitle_header_size) {
        
        NSString *s = [[NSString alloc] initWithBytes:codecCtx->subtitle_header
                                               length:codecCtx->subtitle_header_size
                                             encoding:NSASCIIStringEncoding];
        
        if (s.length) {
            
            NSArray *fields = [lzmMediaSubtitleASSParser parseEvents:s];
            if (fields.count && [fields.lastObject isEqualToString:@"Text"]) {
                _subtitleASSEvents = fields.count;
                NSLog(@"subtitle ass events: %@", [fields componentsJoinedByString:@","]);
            }
        }
    }
    
    return lzmMediaErrorNone;
}

-(void) closeFile
{
    [self closeAudioStream];
    [self closeVideoStream];
    [self closeSubtitleStream];
    
    _videoStreams = nil;
    _audioStreams = nil;
    _subtitleStreams = nil;
    
    if (_formatCtx) {
        
        _formatCtx->interrupt_callback.opaque = NULL;
        _formatCtx->interrupt_callback.callback = NULL;
        
        avformat_close_input(&_formatCtx);
        _formatCtx = NULL;
    }
}

- (void) closeVideoStream
{
    _videoStream = -1;
    
    [self closeScaler];
    
    if (_videoFrame) {
        
        av_free(_videoFrame);
        _videoFrame = NULL;
    }
    
    if (_videoCodecCtx) {
        
        avcodec_close(_videoCodecCtx);
        _videoCodecCtx = NULL;
    }
}

- (void) closeAudioStream
{
    _audioStream = -1;
    
    if (_swrBuffer) {
        
        free(_swrBuffer);
        _swrBuffer = NULL;
        _swrBufferSize = 0;
    }
    
    if (_swrContext) {
        
        swr_free(&_swrContext);
        _swrContext = NULL;
    }
    
    if (_audioFrame) {
        
        av_free(_audioFrame);
        _audioFrame = NULL;
    }
    
    if (_audioCodecCtx) {
        
        avcodec_close(_audioCodecCtx);
        _audioCodecCtx = NULL;
    }
}

- (void) closeSubtitleStream
{
    _subtitleStream = -1;
    
    if (_subtitleCodecCtx) {
        
        avcodec_close(_subtitleCodecCtx);
        _subtitleCodecCtx = NULL;
    }
}

- (void) closeScaler
{
    if (_swsContext) {
        sws_freeContext(_swsContext);
        _swsContext = NULL;
    }
    
    if (_pictureValid) {
        avpicture_free(&_picture);
        _pictureValid = NO;
    }
}

- (BOOL) setupScaler
{
    [self closeScaler];
    
    _pictureValid = avpicture_alloc(&_picture,
                                    AV_PIX_FMT_RGB24,
                                    _videoCodecCtx->width,
                                    _videoCodecCtx->height) == 0;
    
    if (!_pictureValid)
        return NO;
    
    _swsContext = sws_getCachedContext(_swsContext,
                                       _videoCodecCtx->width,
                                       _videoCodecCtx->height,
                                       _videoCodecCtx->pix_fmt,
                                       _videoCodecCtx->width,
                                       _videoCodecCtx->height,
                                       AV_PIX_FMT_RGB24,
                                       SWS_FAST_BILINEAR,
                                       NULL, NULL, NULL);
    
    return _swsContext != NULL;
}

- (lzmVideoFrame *) handleVideoFrame
{
    if (!_videoFrame->data[0])
        return nil;
    
    lzmVideoFrame *frame;
    
    if (_videoFrameFormat == lzmVideoFrameFormatYUV) {
        
        lzmVideoFrameYUV * yuvFrame = [[lzmVideoFrameYUV alloc] init];
        
        yuvFrame.luma = copyFrameData(_videoFrame->data[0],
                                      _videoFrame->linesize[0],
                                      _videoCodecCtx->width,
                                      _videoCodecCtx->height);
        
        yuvFrame.chromaB = copyFrameData(_videoFrame->data[1],
                                         _videoFrame->linesize[1],
                                         _videoCodecCtx->width / 2,
                                         _videoCodecCtx->height / 2);
        
        yuvFrame.chromaR = copyFrameData(_videoFrame->data[2],
                                         _videoFrame->linesize[2],
                                         _videoCodecCtx->width / 2,
                                         _videoCodecCtx->height / 2);
        
        frame = yuvFrame;
        
    } else {
        
        if (!_swsContext &&
            ![self setupScaler]) {
            
            NSLog(@"fail setup video scaler");
            return nil;
        }
        
        sws_scale(_swsContext,
                  (const uint8_t **)_videoFrame->data,
                  _videoFrame->linesize,
                  0,
                  _videoCodecCtx->height,
                  _picture.data,
                  _picture.linesize);
        
        
        lzmVideoFrameRGB *rgbFrame = [[lzmVideoFrameRGB alloc] init];
        
        rgbFrame.linesize = _picture.linesize[0];
        rgbFrame.rgb = [NSData dataWithBytes:_picture.data[0]
                                      length:rgbFrame.linesize * _videoCodecCtx->height];
        frame = rgbFrame;
    }
    
    frame.width = _videoCodecCtx->width;
    frame.height = _videoCodecCtx->height;
    frame.position = av_frame_get_best_effort_timestamp(_videoFrame) * _videoTimeBase;
    
    const int64_t frameDuration = av_frame_get_pkt_duration(_videoFrame);
    if (frameDuration) {
        
        frame.duration = frameDuration * _videoTimeBase;
        frame.duration += _videoFrame->repeat_pict * _videoTimeBase * 0.5;
        
        //if (_videoFrame->repeat_pict > 0) {
        //    LoggerVideo(0, @"_videoFrame.repeat_pict %d", _videoFrame->repeat_pict);
        //}
        
    } else {
        
        // sometimes, ffmpeg unable to determine a frame duration
        // as example yuvj420p stream from web camera
        frame.duration = 1.0 / _fps;
    }
    
#if 0
    NSLog(@"VFD: %.4f %.4f | %lld ",
                frame.position,
                frame.duration,
                av_frame_get_pkt_pos(_videoFrame));
#endif
    
    return frame;
}

//- (lzmAudioFrame *) handleAudioFrame
//{
//    if (!_audioFrame->data[0])
//        return nil;
//    
//    id<LzmAudioManager> audioManager = [LzmAudioManager audioManager];
//    
//    const NSUInteger numChannels = audioManager.numOutputChannels;
//    NSInteger numFrames;
//    
//    void * audioData;
//    
//    if (_swrContext) {
//        
//        const NSUInteger ratio = MAX(1, audioManager.samplingRate / _audioCodecCtx->sample_rate) *
//        MAX(1, audioManager.numOutputChannels / _audioCodecCtx->channels) * 2;
//        
//        const int bufSize = av_samples_get_buffer_size(NULL,
//                                                       audioManager.numOutputChannels,
//                                                       _audioFrame->nb_samples * ratio,
//                                                       AV_SAMPLE_FMT_S16,
//                                                       1);
//        
//        if (!_swrBuffer || _swrBufferSize < bufSize) {
//            _swrBufferSize = bufSize;
//            _swrBuffer = realloc(_swrBuffer, _swrBufferSize);
//        }
//        
//        Byte *outbuf[2] = { _swrBuffer, 0 };
//        
//        numFrames = swr_convert(_swrContext,
//                                outbuf,
//                                _audioFrame->nb_samples * ratio,
//                                (const uint8_t **)_audioFrame->data,
//                                _audioFrame->nb_samples);
//        
//        if (numFrames < 0) {
//            NSLog(@"fail resample audio");
//            return nil;
//        }
//        
//        //int64_t delay = swr_get_delay(_swrContext, audioManager.samplingRate);
//        //if (delay > 0)
//        //    LoggerAudio(0, @"resample delay %lld", delay);
//        
//        audioData = _swrBuffer;
//        
//    } else {
//        
//        if (_audioCodecCtx->sample_fmt != AV_SAMPLE_FMT_S16) {
//            NSAssert(false, @"bucheck, audio format is invalid");
//            return nil;
//        }
//        
//        audioData = _audioFrame->data[0];
//        numFrames = _audioFrame->nb_samples;
//    }
//    
//    const NSUInteger numElements = numFrames * numChannels;
//    NSMutableData *data = [NSMutableData dataWithLength:numElements * sizeof(float)];
//    
//    float scale = 1.0 / (float)INT16_MAX ;
//    vDSP_vflt16((SInt16 *)audioData, 1, data.mutableBytes, 1, numElements);
//    vDSP_vsmul(data.mutableBytes, 1, &scale, data.mutableBytes, 1, numElements);
//    
//    lzmAudioFrame *frame = [[lzmAudioFrame alloc] init];
//    frame.position = av_frame_get_best_effort_timestamp(_audioFrame) * _audioTimeBase;
//    frame.duration = av_frame_get_pkt_duration(_audioFrame) * _audioTimeBase;
//    frame.samples = data;
//    
//    if (frame.duration == 0) {
//        // sometimes ffmpeg can't determine the duration of audio frame
//        // especially of wma/wmv format
//        // so in this case must compute duration
//        frame.duration = frame.samples.length / (sizeof(float) * numChannels * audioManager.samplingRate);
//    }
//    
//#if 0
//    LoggerAudio(2, @"AFD: %.4f %.4f | %.4f ",
//                frame.position,
//                frame.duration,
//                frame.samples.length / (8.0 * 44100.0));
//#endif
//    
//    return frame;
//}

- (lzmSubtitleFrame *) handleSubtitle: (AVSubtitle *)pSubtitle
{
    NSMutableString *ms = [NSMutableString string];
    
    for (NSUInteger i = 0; i < pSubtitle->num_rects; ++i) {
        
        AVSubtitleRect *rect = pSubtitle->rects[i];
        if (rect) {
            
            if (rect->text) { // rect->type == SUBTITLE_TEXT
                
                NSString *s = [NSString stringWithUTF8String:rect->text];
                if (s.length) [ms appendString:s];
                
            } else if (rect->ass && _subtitleASSEvents != -1) {
                
                NSString *s = [NSString stringWithUTF8String:rect->ass];
                if (s.length) {
                    
                    NSArray *fields = [lzmMediaSubtitleASSParser parseDialogue:s numFields:_subtitleASSEvents];
                    if (fields.count && [fields.lastObject length]) {
                        
                        s = [lzmMediaSubtitleASSParser removeCommandsFromEventText: fields.lastObject];
                        if (s.length) [ms appendString:s];
                    }
                }
            }
        }
    }
    
    if (!ms.length)
        return nil;
    
    lzmSubtitleFrame *frame = [[lzmSubtitleFrame alloc] init];
    frame.text = [ms copy];
    frame.position = pSubtitle->pts / AV_TIME_BASE + pSubtitle->start_display_time;
    frame.duration = (CGFloat)(pSubtitle->end_display_time - pSubtitle->start_display_time) / 1000.f;
    
#if 0
    NSLog(@"SUB: %.4f %.4f | %@",
                 frame.position,
                 frame.duration,
                 frame.text);
#endif
    
    return frame;
}

- (BOOL) interruptDecoder
{
    if (_interruptCallback)
        return _interruptCallback();
    return NO;
}

#pragma mark - public

- (BOOL) setupVideoFrameFormat: (lzmVideoFrameFormat) format
{
    if (format == lzmVideoFrameFormatYUV &&
        _videoCodecCtx &&
        (_videoCodecCtx->pix_fmt == AV_PIX_FMT_YUV420P || _videoCodecCtx->pix_fmt == AV_PIX_FMT_YUVJ420P)) {
        
        _videoFrameFormat = lzmVideoFrameFormatYUV;
        return YES;
    }
    
    _videoFrameFormat = lzmVideoFrameFormatRGB;
    return _videoFrameFormat == format;
}

- (NSArray *) decodeFrames: (CGFloat) minDuration
{
    if (_videoStream == -1 &&
        _audioStream == -1)
        return nil;
    
    NSMutableArray *result = [NSMutableArray array];
    
    AVPacket packet;
    
    CGFloat decodedDuration = 0;
    
    BOOL finished = NO;
    
    while (!finished) {
        
        if (av_read_frame(_formatCtx, &packet) < 0) {
            _isEOF = YES;
            break;
        }
        
        if (packet.stream_index ==_videoStream) {
            
            int pktSize = packet.size;
            
            while (pktSize > 0) {
                
                int len = 0;
                len = avcodec_send_packet(_videoCodecCtx,&packet);
                len = avcodec_receive_frame(_videoCodecCtx,_videoFrame);
                
                if (len < 0) {
                    NSLog(@"decode video error, skip packet");
                    break;
                }
                
                if (len == 0) {
                    
                    if (!_disableDeinterlacing &&
                        _videoFrame->interlaced_frame) {
                        
                        //                        avpicture_deinterlace((AVPicture*)_videoFrame,
                        //                                              (AVPicture*)_videoFrame,
                        //                                              _videoCodecCtx->pix_fmt,
                        //                                              _videoCodecCtx->width,
                        //                                              _videoCodecCtx->height);
                        
                    }
                    
                    lzmVideoFrame *frame = [self handleVideoFrame];
                    if (frame) {
                        
                        [result addObject:frame];
                        
                        _position = frame.position;
                        decodedDuration += frame.duration;
                        if (decodedDuration > minDuration)
                            finished = YES;
                    }
                }
                
                if (0 == len)
                    break;
                
                pktSize -= len;
            }
            
        } else if (packet.stream_index == _audioStream) {
            
            int pktSize = packet.size;
            
            while (pktSize > 0) {
                
                int gotframe = 0;
                int len = avcodec_decode_audio4(_audioCodecCtx,
                                                _audioFrame,
                                                &gotframe,
                                                &packet);
                
                if (len < 0) {
                    NSLog(@"decode audio error, skip packet");
                    break;
                }
                
                if (gotframe) {
                    
//                    lzmAudioFrame * frame = [self handleAudioFrame];
//                    if (frame) {
//                        
//                        [result addObject:frame];
//                        
//                        if (_videoStream == -1) {
//                            
//                            _position = frame.position;
//                            decodedDuration += frame.duration;
//                            if (decodedDuration > minDuration)
//                                finished = YES;
//                        }
//                    }
                }
                
                if (0 == len)
                    break;
                
                pktSize -= len;
            }
            
        } else if (packet.stream_index == _artworkStream) {
            
            if (packet.size) {
                
                lzmArtworkFrame *frame = [[lzmArtworkFrame alloc] init];
                frame.picture = [NSData dataWithBytes:packet.data length:packet.size];
                [result addObject:frame];
            }
            
        } else if (packet.stream_index == _subtitleStream) {
            
            int pktSize = packet.size;
            
            while (pktSize > 0) {
                
                AVSubtitle subtitle;
                int gotsubtitle = 0;
                int len = avcodec_decode_subtitle2(_subtitleCodecCtx,
                                                   &subtitle,
                                                   &gotsubtitle,
                                                   &packet);
                
                if (len < 0) {
                    NSLog(@"decode subtitle error, skip packet");
                    break;
                }
                
                if (gotsubtitle) {
                    
                    lzmSubtitleFrame *frame = [self handleSubtitle: &subtitle];
                    if (frame) {
                        [result addObject:frame];
                    }
                    avsubtitle_free(&subtitle);
                }
                
                if (0 == len)
                    break;
                
                pktSize -= len;
            }
        }
        
        av_packet_unref(&packet);
    }
    
    return result;
}

@end

//////////////////////////////////////////////////////////////////////////////
//////////////////////////////////////////////////////////////////////////////

static int interrupt_callback(void *ctx)
{
    if (!ctx)
        return 0;
    __unsafe_unretained LzmMediaDecoder *p = (__bridge LzmMediaDecoder *)ctx;
    const BOOL r = [p interruptDecoder];
    if (r) NSLog(@"DEBUG: INTERRUPT_CALLBACK!");
    return r;
}

//////////////////////////////////////////////////////////////////////////////
//////////////////////////////////////////////////////////////////////////////

@implementation lzmMediaSubtitleASSParser

+ (NSArray *) parseEvents: (NSString *) events
{
    NSRange r = [events rangeOfString:@"[Events]"];
    if (r.location != NSNotFound) {
        
        NSUInteger pos = r.location + r.length;
        
        r = [events rangeOfString:@"Format:"
                          options:0
                            range:NSMakeRange(pos, events.length - pos)];
        
        if (r.location != NSNotFound) {
            
            pos = r.location + r.length;
            r = [events rangeOfCharacterFromSet:[NSCharacterSet newlineCharacterSet]
                                        options:0
                                          range:NSMakeRange(pos, events.length - pos)];
            
            if (r.location != NSNotFound) {
                
                NSString *format = [events substringWithRange:NSMakeRange(pos, r.location - pos)];
                NSArray *fields = [format componentsSeparatedByString:@","];
                if (fields.count > 0) {
                    
                    NSCharacterSet *ws = [NSCharacterSet whitespaceCharacterSet];
                    NSMutableArray *ma = [NSMutableArray array];
                    for (NSString *s in fields) {
                        [ma addObject:[s stringByTrimmingCharactersInSet:ws]];
                    }
                    return ma;
                }
            }
        }
    }
    
    return nil;
}

+ (NSArray *) parseDialogue: (NSString *) dialogue
                  numFields: (NSUInteger) numFields
{
    if ([dialogue hasPrefix:@"Dialogue:"]) {
        
        NSMutableArray *ma = [NSMutableArray array];
        
        NSRange r = {@"Dialogue:".length, 0};
        NSUInteger n = 0;
        
        while (r.location != NSNotFound && n++ < numFields) {
            
            const NSUInteger pos = r.location + r.length;
            
            r = [dialogue rangeOfString:@","
                                options:0
                                  range:NSMakeRange(pos, dialogue.length - pos)];
            
            const NSUInteger len = r.location == NSNotFound ? dialogue.length - pos : r.location - pos;
            NSString *p = [dialogue substringWithRange:NSMakeRange(pos, len)];
            p = [p stringByReplacingOccurrencesOfString:@"\\N" withString:@"\n"];
            [ma addObject: p];
        }
        
        return ma;
    }
    
    return nil;
}

+ (NSString *) removeCommandsFromEventText: (NSString *) text
{
    NSMutableString *ms = [NSMutableString string];
    
    NSScanner *scanner = [NSScanner scannerWithString:text];
    while (!scanner.isAtEnd) {
        
        NSString *s;
        if ([scanner scanUpToString:@"{\\" intoString:&s]) {
            
            [ms appendString:s];
        }
        
        if (!([scanner scanString:@"{\\" intoString:nil] &&
              [scanner scanUpToString:@"}" intoString:nil] &&
              [scanner scanString:@"}" intoString:nil])) {
            
            break;
        }
    }
    
    return ms;
}

@end
