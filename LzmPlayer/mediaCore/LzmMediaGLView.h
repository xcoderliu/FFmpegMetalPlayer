//
//  LzmMediaGLView.h
//  LzmPlayer
//
//  Created by 刘智民 on 2/6/17.
//  Copyright © 2017 刘智民. All rights reserved.
//

#import <Cocoa/Cocoa.h>
@class lzmVideoFrame;
@class LzmMediaDecoder;

@interface LzmMediaGLView : NSView
- (id) initWithFrame:(CGRect)frame
             decoder: (LzmMediaDecoder *) decoder;

- (void) render: (lzmVideoFrame *) frame;
@end
