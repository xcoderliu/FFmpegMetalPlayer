//
//  LzmPlayerViewController.m
//  LzmPlayer
//
//  Created by 刘智民 on 2/6/17.
//  Copyright © 2017 刘智民. All rights reserved.
//

#import "LzmPlayerViewController.h"
#import <MediaPlayer/MediaPlayer.h>
#import <QuartzCore/QuartzCore.h>
#import "LzmMediaDecoder.h"
#import "LzmAudioManager.h"
#import "LzmMediaGLView.h"

NSString * const lzmMovieParameterMinBufferedDuration = @"lzmMovieParameterMinBufferedDuration";
NSString * const lzmMovieParameterMaxBufferedDuration = @"lzmMovieParameterMaxBufferedDuration";
NSString * const lzmMovieParameterDisableDeinterlacing = @"lzmMovieParameterDisableDeinterlacing";

////////////////////////////////////////////////////////////////////////////////

static NSString * formatTimeInterval(CGFloat seconds, BOOL isLeft)
{
    seconds = MAX(0, seconds);
    
    NSInteger s = seconds;
    NSInteger m = s / 60;
    NSInteger h = m / 60;
    
    s = s % 60;
    m = m % 60;
    
    NSMutableString *format = [(isLeft && seconds >= 0.5 ? @"-" : @"") mutableCopy];
    if (h != 0) [format appendFormat:@"%d:%0.2d", h, m];
    else        [format appendFormat:@"%d", m];
    [format appendFormat:@":%0.2d", s];
    
    return format;
}

////////////////////////////////////////////////////////////////////////////////

enum {
    
    lzmMovieInfoSectionGeneral,
    lzmMovieInfoSectionVideo,
    lzmMovieInfoSectionAudio,
    lzmMovieInfoSectionSubtitles,
    lzmMovieInfoSectionMetadata,
    lzmMovieInfoSectionCount,
};

enum {
    
    lzmMovieInfoGeneralFormat,
    lzmMovieInfoGeneralBitrate,
    lzmMovieInfoGeneralCount,
};

////////////////////////////////////////////////////////////////////////////////

static NSMutableDictionary * gHistory;

#define LOCAL_MIN_BUFFERED_DURATION   0.2
#define LOCAL_MAX_BUFFERED_DURATION   0.4
#define NETWORK_MIN_BUFFERED_DURATION 2.0
#define NETWORK_MAX_BUFFERED_DURATION 4.0


@interface LzmPlayerViewController () {
    
    LzmMediaDecoder      *_decoder;
    dispatch_queue_t    _dispatchQueue;
    NSMutableArray      *_videoFrames;
    NSMutableArray      *_audioFrames;
    NSMutableArray      *_subtitles;
    NSData              *_currentAudioFrame;
    NSUInteger          _currentAudioFramePos;
    CGFloat             _moviePosition;
    BOOL                _disableUpdateHUD;
    NSTimeInterval      _tickCorrectionTime;
    NSTimeInterval      _tickCorrectionPosition;
    NSUInteger          _tickCounter;
    BOOL                _fullscreen;
    BOOL                _hiddenHUD;
    BOOL                _fitMode;
    BOOL                _infoMode;
    BOOL                _restoreIdleTimer;
    BOOL                _interrupted;
    
    LzmMediaGLView       *_glView;
    NSImageView         *_imageView;
    NSView              *_topHUD;
    NSToolbar           *_topBar;
    NSToolbar           *_bottomBar;
    NSSlider            *_progressSlider;
    
    NSToolbarItem    *_playBtn;
    NSToolbarItem     *_pauseBtn;
    NSToolbarItem     *_rewindBtn;
    NSToolbarItem     *_fforwardBtn;
    NSToolbarItem     *_spaceItem;
    NSToolbarItem     *_fixedSpaceItem;
    
    NSBundle            *_doneButton;
    //    UILabel             *_progressLabel;
    //    UILabel             *_leftLabel;
    NSBundle            *_infoButton;
    NSTableView         *_tableView;
    //    UIActivityIndicatorView *_activityIndicatorView;
    //    UILabel             *_subtitlesLabel;
    
    //    UITapGestureRecognizer *_tapGestureRecognizer;
    //    UITapGestureRecognizer *_doubleTapGestureRecognizer;
    //    UIPanGestureRecognizer *_panGestureRecognizer;
    
#ifdef DEBUG
    //    UILabel             *_messageLabel;
    NSTimeInterval      _debugStartTime;
    NSUInteger          _debugAudioStatus;
    NSDate              *_debugAudioStatusTS;
#endif
    
    CGFloat             _bufferedDuration;
    CGFloat             _minBufferedDuration;
    CGFloat             _maxBufferedDuration;
    BOOL                _buffered;
    
    BOOL                _savedIdleTimer;
    
    NSDictionary        *_parameters;
    NSURL *_mediaUrl;
}
@property (readwrite) BOOL playing;
@property (readwrite) BOOL decoding;
@property (readwrite, strong) lzmArtworkFrame *artworkFrame;
@end

@implementation LzmPlayerViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    // Do view setup here.
}

- (void)viewWillAppear {
    [super viewWillAppear];
}

- (id)initWithMovieUrl:(NSURL *)url {
    if (self = [super init]) {
        _mediaUrl = url;
        {
            
            _moviePosition = 0;
            
            __weak LzmPlayerViewController *weakSelf = self;
            
            LzmMediaDecoder *decoder = [[LzmMediaDecoder alloc] init];
            
            decoder.interruptCallback = ^BOOL(){
                
                __strong LzmPlayerViewController *strongSelf = weakSelf;
                return strongSelf ? [strongSelf interruptDecoder] : YES;
            };
            
            dispatch_async(dispatch_get_global_queue(0, 0), ^{
                
                NSError *error = nil;
                [decoder openFile: [url isFileURL] ? [url path] : [url absoluteString] error:&error];
                
                __strong LzmPlayerViewController *strongSelf = weakSelf;
                
                if (strongSelf) {
                    
                    dispatch_sync(dispatch_get_main_queue(), ^{
                        
                        [strongSelf setMediaDecoder:decoder withError:error];
                    });
                }
            });
        }
    }
    return self;
}

- (NSView *) frameView
{
    return _glView ? _glView : _imageView;
}


- (void) setupPresentView
{
    CGRect bounds = self.view.bounds;
    
    if (_decoder.validVideo) {
        _glView = [[LzmMediaGLView alloc] initWithFrame:bounds decoder:_decoder];
    }
    
    if (!_glView) {
        
        [_decoder setupVideoFrameFormat:lzmVideoFrameFormatRGB];
        _imageView = [[NSImageView alloc] initWithFrame:bounds];
        [_imageView.layer setBackgroundColor:CGColorCreateGenericRGB(1, 1, 1, 1)];
    }
    
    NSView *frameView = [self frameView];
//    frameView.contentMode = UIViewContentModeScaleAspectFit;
//    frameView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleHeight | UIViewAutoresizingFlexibleBottomMargin;
//    
//    [self.view insertSubview:frameView atIndex:0];
    [self.view addSubview:frameView positioned:NSWindowAbove relativeTo:nil];
    
    if (_decoder.validVideo) {
        
//        [self setupUserInteraction];
        
    } else {
        
        _imageView.image = [NSImage imageNamed:@"kxmovie.bundle/music_icon.png"];
//        _imageView.contentMode = UIViewContentModeCenter;
    }
    
    self.view.layer.backgroundColor = CGColorGetConstantColor(kCGColorClear);
    
    if (_decoder.duration == MAXFLOAT) {
        
//        _leftLabel.text = @"\u221E"; // infinity
//        _leftLabel.font = [UIFont systemFontOfSize:14];
        
//        CGRect frame;
        
//        frame = _leftLabel.frame;
//        frame.origin.x += 40;
//        frame.size.width -= 40;
//        _leftLabel.frame = frame;
        
//        frame =_progressSlider.frame;
//        frame.size.width += 40;
//        _progressSlider.frame = frame;
        
    } else {
        
//        [_progressSlider addTarget:self
//                            action:@selector(progressDidChange:)
//                  forControlEvents:UIControlEventValueChanged];
    }
    
    if (_decoder.subtitleStreamsCount) {
        
//        CGSize size = self.view.bounds.size;
//        
//        _subtitlesLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, size.height, size.width, 0)];
//        _subtitlesLabel.numberOfLines = 0;
//        _subtitlesLabel.backgroundColor = [UIColor clearColor];
//        _subtitlesLabel.opaque = NO;
//        _subtitlesLabel.adjustsFontSizeToFitWidth = NO;
//        _subtitlesLabel.textAlignment = NSTextAlignmentCenter;
//        _subtitlesLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
//        _subtitlesLabel.textColor = [UIColor whiteColor];
//        _subtitlesLabel.font = [UIFont systemFontOfSize:16];
//        _subtitlesLabel.hidden = YES;
//        
//        [self.view addSubview:_subtitlesLabel];
    }
}

- (void)loadView {
    self.view = [[NSView alloc] init];
    [self setUpViews];
}

- (void)setUpViews {
    
}

- (BOOL) interruptDecoder
{
    //if (!_decoder)
    //    return NO;
    return _interrupted;
}
#pragma mark - private

- (void) setMediaDecoder: (LzmMediaDecoder *) decoder
               withError: (NSError *) error
{
    if (!error && decoder) {
        
        _decoder        = decoder;
        _dispatchQueue  = dispatch_queue_create("KxMovie", DISPATCH_QUEUE_SERIAL);
        _videoFrames    = [NSMutableArray array];
        _audioFrames    = [NSMutableArray array];
        
        if (_decoder.subtitleStreamsCount) {
            _subtitles = [NSMutableArray array];
        }
        
        if (_decoder.isNetwork) {
            
            _minBufferedDuration = NETWORK_MIN_BUFFERED_DURATION;
            _maxBufferedDuration = NETWORK_MAX_BUFFERED_DURATION;
            
        } else {
            
            _minBufferedDuration = LOCAL_MIN_BUFFERED_DURATION;
            _maxBufferedDuration = LOCAL_MAX_BUFFERED_DURATION;
        }
        
        if (!_decoder.validVideo)
            _minBufferedDuration *= 10.0; // increase for audio
        
        // allow to tweak some parameters at runtime
        if (_parameters.count) {
            
            id val;
            
            val = [_parameters valueForKey: lzmMovieParameterMinBufferedDuration];
            if ([val isKindOfClass:[NSNumber class]])
                _minBufferedDuration = [val floatValue];
            
            val = [_parameters valueForKey: lzmMovieParameterMaxBufferedDuration];
            if ([val isKindOfClass:[NSNumber class]])
                _maxBufferedDuration = [val floatValue];
            
            val = [_parameters valueForKey: lzmMovieParameterDisableDeinterlacing];
            if ([val isKindOfClass:[NSNumber class]])
                _decoder.disableDeinterlacing = [val boolValue];
            
            if (_maxBufferedDuration < _minBufferedDuration)
                _maxBufferedDuration = _minBufferedDuration * 2;
        }
    
        
        if (self.isViewLoaded) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [self setupPresentView];
            });
            
//
//            _progressLabel.hidden   = NO;
//            _progressSlider.hidden  = NO;
//            _leftLabel.hidden       = NO;
//            _infoButton.hidden      = NO;
            
//            if (_activityIndicatorView.isAnimating) {
//                
//                [_activityIndicatorView stopAnimating];
//                // if (self.view.window)
//                [self restorePlay];
//            }
        }
        
    } else {
        
        if (self.isViewLoaded && self.view.window) {
            
//            [_activityIndicatorView stopAnimating];
//            if (!_interrupted)
//                [self handleDecoderMovieError: error];
        }
    }
}

- (void) restorePlay
{
    NSNumber *n = [gHistory valueForKey:_decoder.path];
    if (n)
        [self updatePosition:n.floatValue playMode:YES];
    else
        [self play];
}

- (void) updatePosition: (CGFloat) position
               playMode: (BOOL) playMode
{
    [self freeBufferedFrames];
    
    position = MIN(_decoder.duration - 1, MAX(0, position));
    
    __weak LzmPlayerViewController *weakSelf = self;
    
    dispatch_async(_dispatchQueue, ^{
        
        if (playMode) {
            
            {
                __strong LzmPlayerViewController *strongSelf = weakSelf;
                if (!strongSelf) return;
                [strongSelf setDecoderPosition: position];
            }
            
            dispatch_async(dispatch_get_main_queue(), ^{
                
                __strong LzmPlayerViewController *strongSelf = weakSelf;
                if (strongSelf) {
                    [strongSelf setMoviePositionFromDecoder];
                    [strongSelf play];
                }
            });
            
        } else {
            
            {
                __strong LzmPlayerViewController *strongSelf = weakSelf;
                if (!strongSelf) return;
                [strongSelf setDecoderPosition: position];
                [strongSelf decodeFrames];
            }
            
            dispatch_async(dispatch_get_main_queue(), ^{
                
                __strong LzmPlayerViewController *strongSelf = weakSelf;
                if (strongSelf) {
                    
                    [strongSelf enableUpdateHUD];
                    [strongSelf setMoviePositionFromDecoder];
                    [strongSelf presentFrame];
//                    [strongSelf updateHUD];
                }
            });
        }        
    });
}

- (void) freeBufferedFrames
{
    @synchronized(_videoFrames) {
        [_videoFrames removeAllObjects];
    }
    
    @synchronized(_audioFrames) {
        
        [_audioFrames removeAllObjects];
        _currentAudioFrame = nil;
    }
    
    if (_subtitles) {
        @synchronized(_subtitles) {
            [_subtitles removeAllObjects];
        }
    }
    
    _bufferedDuration = 0;
}

- (void) setMoviePositionFromDecoder
{
    _moviePosition = _decoder.position;
}

- (void) setDecoderPosition: (CGFloat) position
{
    _decoder.position = position;
}

- (void) enableUpdateHUD
{
    _disableUpdateHUD = NO;
}

-(void) play
{
    if (self.playing)
        return;
    
    if (!_decoder.validVideo &&
        !_decoder.validAudio) {
        
        return;
    }
    
    if (_interrupted)
        return;
    
    self.playing = YES;
    _interrupted = NO;
    _disableUpdateHUD = NO;
    _tickCorrectionTime = 0;
    _tickCounter = 0;
    
#ifdef DEBUG
    _debugStartTime = -1;
#endif
    
    [self asyncDecodeFrames];
//    [self updatePlayButton];
    
    dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, 0.1 * NSEC_PER_SEC);
    dispatch_after(popTime, dispatch_get_main_queue(), ^(void){
        [self tick];
    });
    
    if (_decoder.validAudio)
//        [self enableAudio:YES];
    
    NSLog(@"play movie");
}

- (BOOL) decodeFrames
{
    //NSAssert(dispatch_get_current_queue() == _dispatchQueue, @"bugcheck");
    
    NSArray *frames = nil;
    
    if (_decoder.validVideo ||
        _decoder.validAudio) {
        
        frames = [_decoder decodeFrames:0];
    }
    
    if (frames.count) {
        return [self addFrames: frames];
    }
    return NO;
}

- (void) asyncDecodeFrames
{
    if (self.decoding)
        return;
    
    __weak LzmPlayerViewController *weakSelf = self;
    __weak LzmMediaDecoder *weakDecoder = _decoder;
    
    const CGFloat duration = _decoder.isNetwork ? .0f : 0.1f;
    
    self.decoding = YES;
    dispatch_async(_dispatchQueue, ^{
        
        {
            __strong LzmPlayerViewController *strongSelf = weakSelf;
            if (!strongSelf.playing)
                return;
        }
        
        BOOL good = YES;
        while (good) {
            
            good = NO;
            
            @autoreleasepool {
                
                __strong LzmMediaDecoder *decoder = weakDecoder;
                
                if (decoder && (decoder.validVideo || decoder.validAudio)) {
                    
                    NSArray *frames = [decoder decodeFrames:duration];
                    if (frames.count) {
                        
                        __strong LzmPlayerViewController *strongSelf = weakSelf;
                        if (strongSelf)
                            good = [strongSelf addFrames:frames];
                    }
                }
            }
        }
        
        {
            __strong LzmPlayerViewController *strongSelf = weakSelf;
            if (strongSelf) strongSelf.decoding = NO;
        }
    });
}

- (void) pause
{
    if (!self.playing)
        return;
    
    self.playing = NO;
    //_interrupted = YES;
//    [self enableAudio:NO];
//    [self updatePlayButton];
    NSLog(@"pause movie");
}


- (void) tick
{
    if (_buffered && ((_bufferedDuration > _minBufferedDuration) || _decoder.isEOF)) {
        
        _tickCorrectionTime = 0;
        _buffered = NO;
//        [_activityIndicatorView stopAnimating];
    }
    
    CGFloat interval = 0;
    if (!_buffered)
        interval = [self presentFrame];
    
    if (self.playing) {
        
        const NSUInteger leftFrames =
        (_decoder.validVideo ? _videoFrames.count : 0) +
        (_decoder.validAudio ? _audioFrames.count : 0);
        
        if (0 == leftFrames) {
            
            if (_decoder.isEOF) {
                
                [self pause];
//                [self updateHUD];
                return;
            }
            
            if (_minBufferedDuration > 0 && !_buffered) {
                
                _buffered = YES;
//                [_activityIndicatorView startAnimating];
            }
        }
        
        if (!leftFrames ||
            !(_bufferedDuration > _minBufferedDuration)) {
            
            [self asyncDecodeFrames];
        }
        
        const NSTimeInterval correction = [self tickCorrection];
        const NSTimeInterval time = MAX(interval + correction, 0.01);
        dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, time * NSEC_PER_SEC);
        dispatch_after(popTime, dispatch_get_main_queue(), ^(void){
            [self tick];
        });
    }
    
    if ((_tickCounter++ % 3) == 0) {
//        [self updateHUD];
    }
}

- (CGFloat) tickCorrection
{
    if (_buffered)
        return 0;
    
    const NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    
    if (!_tickCorrectionTime) {
        
        _tickCorrectionTime = now;
        _tickCorrectionPosition = _moviePosition;
        return 0;
    }
    
    NSTimeInterval dPosition = _moviePosition - _tickCorrectionPosition;
    NSTimeInterval dTime = now - _tickCorrectionTime;
    NSTimeInterval correction = dPosition - dTime;
    
    //if ((_tickCounter % 200) == 0)
    //    LoggerStream(1, @"tick correction %.4f", correction);
    
    if (correction > 1.f || correction < -1.f) {
        
        NSLog(@"tick correction reset %.2f", correction);
        correction = 0;
        _tickCorrectionTime = 0;
    }
    
    return correction;
}


- (BOOL) addFrames: (NSArray *)frames
{
    if (_decoder.validVideo) {
        
        @synchronized(_videoFrames) {
            
            for (lzmMediaFrame *frame in frames)
                if (frame.type == lzmMediaFrameTypeVideo) {
                    [_videoFrames addObject:frame];
                    _bufferedDuration += frame.duration;
                }
        }
    }
    
    if (_decoder.validAudio) {
        
        @synchronized(_audioFrames) {
            
            for (lzmMediaFrame *frame in frames)
                if (frame.type == lzmMediaFrameTypeAudio) {
                    [_audioFrames addObject:frame];
                    if (!_decoder.validVideo)
                        _bufferedDuration += frame.duration;
                }
        }
        
        if (!_decoder.validVideo) {
            
            for (lzmMediaFrame *frame in frames)
                if (frame.type == lzmMediaFrameTypeArtwork)
                    self.artworkFrame = (lzmArtworkFrame *)frame;
        }
    }
    
    if (_decoder.validSubtitles) {
        
        @synchronized(_subtitles) {
            
            for (lzmMediaFrame *frame in frames)
                if (frame.type == lzmMediaFrameTypeSubtitle) {
                    [_subtitles addObject:frame];
                }
        }
    }
    
    return self.playing && _bufferedDuration < _maxBufferedDuration;
}
- (CGFloat) presentFrame
{
    CGFloat interval = 0;
    
    if (_decoder.validVideo) {
        
        lzmMediaFrame *frame;
        
        @synchronized(_videoFrames) {
            
            if (_videoFrames.count > 0) {
                
                frame = _videoFrames[0];
                [_videoFrames removeObjectAtIndex:0];
                _bufferedDuration -= frame.duration;
            }
        }
        
        if (frame)
            interval = [self presentVideoFrame:frame];
        
    } else if (_decoder.validAudio) {
        
        //interval = _bufferedDuration * 0.5;
        
        if (self.artworkFrame) {
            
            _imageView.image = [self.artworkFrame asImage];
            self.artworkFrame = nil;
        }
    }
    
    if (_decoder.validSubtitles)
        [self presentSubtitles];
    
#ifdef DEBUG
    if (self.playing && _debugStartTime < 0)
        _debugStartTime = [NSDate timeIntervalSinceReferenceDate] - _moviePosition;
#endif
    
    return interval;
}

- (CGFloat) presentVideoFrame: (lzmVideoFrame *) frame
{
    if (_glView) {
        
        [_glView render:frame];
        
    } else {
        
        lzmVideoFrameRGB *rgbFrame = (lzmVideoFrameRGB *)frame;
        _imageView.image = [rgbFrame asImage];
    }
    
    _moviePosition = frame.position;
    
    return frame.duration;
}

- (void) presentSubtitles
{
    NSArray *actual, *outdated;
    
    if ([self subtitleForPosition:_moviePosition
                           actual:&actual
                         outdated:&outdated]){
        
        if (outdated.count) {
            @synchronized(_subtitles) {
                [_subtitles removeObjectsInArray:outdated];
            }
        }
        
//        if (actual.count) {
//            
//            NSMutableString *ms = [NSMutableString string];
//            for (KxSubtitleFrame *subtitle in actual.reverseObjectEnumerator) {
//                if (ms.length) [ms appendString:@"\n"];
//                [ms appendString:subtitle.text];
//            }
//            
//            if (![_subtitlesLabel.text isEqualToString:ms]) {
//                
//                CGSize viewSize = self.view.bounds.size;
//                CGSize size = [ms sizeWithFont:_subtitlesLabel.font
//                             constrainedToSize:CGSizeMake(viewSize.width, viewSize.height * 0.5)
//                                 lineBreakMode:NSLineBreakByTruncatingTail];
//                _subtitlesLabel.text = ms;
//                _subtitlesLabel.frame = CGRectMake(0, viewSize.height - size.height - 10,
//                                                   viewSize.width, size.height);
//                _subtitlesLabel.hidden = NO;
//            }
//            
//        } else {
//            
//            _subtitlesLabel.text = nil;
//            _subtitlesLabel.hidden = YES;
//        }
    }
}

- (BOOL) subtitleForPosition: (CGFloat) position
                      actual: (NSArray **) pActual
                    outdated: (NSArray **) pOutdated
{
    if (!_subtitles.count)
        return NO;
    
    NSMutableArray *actual = nil;
    NSMutableArray *outdated = nil;
    
    for (lzmSubtitleFrame *subtitle in _subtitles) {
        
        if (position < subtitle.position) {
            
            break; // assume what subtitles sorted by position
            
        } else if (position >= (subtitle.position + subtitle.duration)) {
            
            if (pOutdated) {
                if (!outdated)
                    outdated = [NSMutableArray array];
                [outdated addObject:subtitle];
            }
            
        } else {
            
            if (pActual) {
                if (!actual)
                    actual = [NSMutableArray array];
                [actual addObject:subtitle];
            }
        }
    }
    
    if (pActual) *pActual = actual;
    if (pOutdated) *pOutdated = outdated;
    
    return actual.count || outdated.count;
}

@end
