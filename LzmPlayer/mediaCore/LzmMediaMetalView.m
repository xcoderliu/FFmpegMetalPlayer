//
//  LzmMediaMetalView.m
//  LzmPlayer
//
//  Created by 刘智民 on 2/6/17.
//  Copyright © 2017 刘智民. All rights reserved.
//
#import <Masonry/Masonry.h>
#import "LzmMediaMetalView.h"
#import <QuartzCore/QuartzCore.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import "LzmMediaDecoder.h"

//////////////////////////////////////////////////////////

@implementation NSImage (ProportionalScaling)

- (NSImage*)imageByScalingProportionallyToSize:(NSSize)targetSize
{
    NSImage* sourceImage = self;
    NSImage* newImage = nil;
    if ([sourceImage isValid])
    {
        NSSize imageSize = [sourceImage size];
        float width  = imageSize.width;
        float height = imageSize.height;
        
        float targetWidth  = targetSize.width;
        float targetHeight = targetSize.height;
        
        float scaleFactor  = 0.0;
        float scaledWidth  = targetWidth;
        float scaledHeight = targetHeight;
        
        NSPoint thumbnailPoint = NSZeroPoint;
        
        if ( NSEqualSizes( imageSize, targetSize ) == NO )
        {
            
            float widthFactor  = targetWidth / width;
            float heightFactor = targetHeight / height;
            
            if ( widthFactor < heightFactor )
                scaleFactor = widthFactor;
            else
                scaleFactor = heightFactor;
            
            scaledWidth  = width  * scaleFactor;
            scaledHeight = height * scaleFactor;
            
            if ( widthFactor < heightFactor )
                thumbnailPoint.y = (targetHeight - scaledHeight) * 0.5;
            
            else if ( widthFactor > heightFactor )
                thumbnailPoint.x = (targetWidth - scaledWidth) * 0.5;
        }
        
        newImage = [[NSImage alloc] initWithSize:targetSize];
        
        [newImage lockFocus];
        
        NSRect thumbnailRect;
        thumbnailRect.origin = thumbnailPoint;
        thumbnailRect.size.width = scaledWidth;
        thumbnailRect.size.height = scaledHeight;
        
        [sourceImage drawInRect: thumbnailRect
                       fromRect: NSZeroRect
                      operation: NSCompositeSourceOver
                       fraction: 1.0];
        
        [newImage unlockFocus];
    }
    return newImage;
}

@end

#pragma mark - frame renderers

@protocol lzmMovieGLRenderer
- (void) setFrame: (lzmVideoFrame *) frame;
- (BOOL) prepareRender;
@end

@interface lzmMovieGLRenderer_RGB : NSObject<lzmMovieGLRenderer> {
    
 
}
@end

@implementation lzmMovieGLRenderer_RGB

- (void) setFrame: (lzmVideoFrame *) frame{
    lzmVideoFrameRGB *rgbFrame = (lzmVideoFrameRGB *)frame;
    assert(rgbFrame.rgb.length == rgbFrame.width * rgbFrame.height * 3);
    
}

- (BOOL) prepareRender{
    return YES;
}



@end

@interface lzmMovieGLRenderer_YUV : NSObject<lzmMovieGLRenderer> {
    
}
@end

@implementation lzmMovieGLRenderer_YUV

- (void) setFrame: (lzmVideoFrame *) frame
{
    lzmVideoFrameYUV *yuvFrame = (lzmVideoFrameYUV *)frame;
    
    assert(yuvFrame.luma.length == yuvFrame.width * yuvFrame.height);
    assert(yuvFrame.chromaB.length == (yuvFrame.width * yuvFrame.height) / 4);
    assert(yuvFrame.chromaR.length == (yuvFrame.width * yuvFrame.height) / 4);
    
}

- (BOOL) prepareRender{
    return YES;
}


@end

//////////////////////////////////////////////////////////


@interface LzmMediaMetalView ()<MTKViewDelegate>

@end


@implementation LzmMediaMetalView {
    
    LzmMediaDecoder            *_decoder;
    id<lzmMovieGLRenderer>      _renderer;
    id<MTLDevice>               device;
    id <MTLCommandQueue>        commandQueue;
    MTKView                     *metalView;
    id<MTLCommandBuffer>        commandBuffer;
    id <MTLTexture>             _texture;
    MTKTextureLoader            *textureLoad;
}


- (id) initWithFrame:(CGRect)frame
             decoder: (LzmMediaDecoder *) decoder
{
    self = [super initWithFrame:frame];
    if (self) {
        
        _decoder = decoder;
        
        if (/*[decoder setupVideoFrameFormat:lzmVideoFrameFormatYUV]*//* DISABLES CODE */ (0)) {
            
            _renderer = [[lzmMovieGLRenderer_YUV alloc] init];
            NSLog(@"OK use YUV GL renderer");
            
        } else {
            
            _renderer = [[lzmMovieGLRenderer_RGB alloc] init];
            NSLog(@"OK use RGB GL renderer");
        }
        
        if (![self initMetal:frame]) {
            self = nil;
            return nil;
        }
        
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(windowResized:) name:NSWindowDidResizeNotification object:[self window]];
       
    }
    return self;
}

- (BOOL)initMetal:(CGRect)frame {
    device =  MTLCreateSystemDefaultDevice();
    commandQueue = [device newCommandQueue];
    commandBuffer = [commandQueue commandBuffer];
    textureLoad = [[MTKTextureLoader alloc] initWithDevice:device];
    metalView = [[MTKView alloc] initWithFrame:self.bounds device:device];
    [self addSubview:metalView];
    [metalView mas_makeConstraints:^(MASConstraintMaker *make) {
        make.centerX.equalTo(self);
        make.centerY.equalTo(self);
        make.width.equalTo(self);
        make.height.equalTo(self);
    }];
    [metalView setFramebufferOnly:NO];
    metalView.delegate = self;
    metalView.depthStencilPixelFormat = /*MTLPixelFormatBGRG422*/MTLPixelFormatStencil8;
    metalView.colorPixelFormat = MTLPixelFormatBGRA8Unorm;
    [metalView setAutoResizeDrawable:YES];
    [metalView setClearColor:MTLClearColorMake(0.15f, 0.15f, 0.15f, 1)];
    return YES;
}



- (void)dealloc
{
    _renderer = nil;
    [metalView setPaused:YES];
    [metalView releaseDrawables];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    [metalView setPaused:NO];
}

- (void)windowResized:(NSNotification *)notification
{
    NSSize size = [[self window] frame].size;
    NSLog(@"window width = %f, window height = %f", size.width, size.height);
    [metalView releaseDrawables];
    [metalView setPaused:NO];
}

- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {
    [metalView releaseDrawables];
    [metalView setPaused:YES];
}

- (void)drawInMTKView:(nonnull MTKView *)view
{
    //得到MetalPerformanceShaders需要使用的命令缓存区
    commandBuffer = [commandQueue commandBuffer];
    
    id<MTLRenderCommandEncoder> commandEncoder = [commandBuffer renderCommandEncoderWithDescriptor:view.currentRenderPassDescriptor];
    [commandEncoder endEncoding];
    
    if (_texture) {
        metalView.colorPixelFormat = [_texture pixelFormat];
        id <MTLTexture> desTexture = [view.currentDrawable texture];
        if ([[_texture device] isEqual:[[view.currentDrawable texture] device]] && [_texture width] == [desTexture width] && [_texture height] == [desTexture height]) {
            
             id<MTLBlitCommandEncoder> blitEncoder = [commandBuffer blitCommandEncoder];
            
            [blitEncoder copyFromTexture:_texture sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake([_texture width], [_texture height], [_texture depth]) toTexture:desTexture destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
            [blitEncoder endEncoding];
            
        } else {
            [metalView releaseDrawables];
        }
    }
    [commandBuffer presentDrawable:view.currentDrawable];
    [commandBuffer commit];
}



- (void)metalrender: (lzmVideoFrame *) frame {
    if (frame) {
        lzmVideoFrameRGB *rgbFrame = (lzmVideoFrameRGB *)frame;
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
            [self loadTexture:rgbFrame];
        });
    }
}

- (BOOL)loadTexture:(lzmVideoFrameRGB*)rgbFrame {
    BOOL loadSuccess = NO;
    NSError *error = nil;
    NSImage *image = [rgbFrame asImage];
    NSData *imageData = [[image imageByScalingProportionallyToSize:self.bounds.size] TIFFRepresentation];
    _texture = [textureLoad newTextureWithData:imageData options:nil error:&error];
    if (!error) {
        loadSuccess = YES;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!metalView.isPaused) {
            [metalView draw];
        } else {
            [metalView releaseDrawables];
        }
    });
    
    return loadSuccess;
}

@end


