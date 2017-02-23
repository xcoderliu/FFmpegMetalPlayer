//
//  LzmMediaMetalView.m
//  LzmPlayer
//
//  Created by 刘智民 on 2/6/17.
//  Copyright © 2017 刘智民. All rights reserved.
//
#import <simd/simd.h>
#import "LzmMediaMetalView.h"
#import <QuartzCore/QuartzCore.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
//#import <simd/simd.h>
#import "LzmMediaDecoder.h"

//////////////////////////////////////////////////////////


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
    id <CAMetalDrawable>        metaldrawable;

    id <MTLTexture>             _texture;
    MTKTextureLoader *textureLoad;
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
       
    }
    return self;
}

- (BOOL)initMetal:(CGRect)frame {
    device =  MTLCreateSystemDefaultDevice();
    commandQueue = [device newCommandQueue];
    commandBuffer = [commandQueue commandBuffer];
    textureLoad = [[MTKTextureLoader alloc] initWithDevice:device];
    return YES;
}

- (void)dealloc
{
    _renderer = nil;
    
    
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)mtkView:(nonnull MTKView *)view drawableSizeWillChange:(CGSize)size
{
    
}
- (void)drawInMTKView:(nonnull MTKView *)view
{
    //得到MetalPerformanceShaders需要使用的命令缓存区
    commandBuffer = [commandQueue commandBuffer];
    id<MTLBlitCommandEncoder> encoder = [commandBuffer blitCommandEncoder];
    [encoder copyFromTexture:_texture sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake([_texture width], [_texture height], [_texture depth]) toTexture:[view.currentDrawable texture] destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
    [encoder endEncoding];
    [commandBuffer presentDrawable:view.currentDrawable];
    [commandBuffer commit];
}



- (void)metalrender: (lzmVideoFrame *) frame {
    if (!metalView) {
        metalView = [[MTKView alloc] initWithFrame:self.bounds device:device];
        [self addSubview:metalView];
        [metalView setFramebufferOnly:NO];
        metalView.delegate = self;
        metalView.depthStencilPixelFormat = MTLPixelFormatBGRG422;
        metalView.colorPixelFormat = MTLPixelFormatBGRA8Unorm_sRGB;
    }
    if (frame) {
        lzmVideoFrameRGB *rgbFrame = (lzmVideoFrameRGB *)frame;
        [self loadTexture:rgbFrame];
    }
}

- (BOOL)loadTexture:(lzmVideoFrameRGB*)rgbFrame {
    BOOL loadSuccess = NO;
    NSError *error = nil;
    NSImage *image = [rgbFrame asImage];
    NSData *imageData = [image TIFFRepresentation];
    _texture = [textureLoad newTextureWithData:imageData options:nil error:&error];
    if (!error) {
        loadSuccess = YES;
    }
    [metalView draw];
    return loadSuccess;
}

@end
