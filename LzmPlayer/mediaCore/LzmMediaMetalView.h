//
//  LzmMediaMetalView.h
//  LzmPlayer
//
//  Created by 刘智民 on 2/6/17.
//  Copyright © 2017 刘智民. All rights reserved.
//

#import <Cocoa/Cocoa.h>
@class lzmVideoFrame;
@class LzmMediaDecoder;

@interface LzmMediaMetalView : NSView
- (id) initWithFrame:(CGRect)frame
             decoder: (LzmMediaDecoder *) decoder;

- (void)metalrender: (lzmVideoFrame *) frame;

@end
