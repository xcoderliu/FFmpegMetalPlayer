//
//  LzmPlayerViewController.h
//  LzmPlayer
//
//  Created by 刘智民 on 2/6/17.
//  Copyright © 2017 刘智民. All rights reserved.
//

#import <Cocoa/Cocoa.h>

@interface LzmPlayerViewController : NSViewController

- (id)initWithMovieUrl:(NSURL *)url;
@property (readonly) BOOL playing;

- (void) play;
- (void) pause;
@end
