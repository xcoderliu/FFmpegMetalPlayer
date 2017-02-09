//
//  ViewController.m
//  LzmPlayer
//
//  Created by 刘智民 on 2/6/17.
//  Copyright © 2017 刘智民. All rights reserved.
//

#import "ViewController.h"
#import "LzmPlayerViewController.h"
#import <Masonry/Masonry.h>

@implementation ViewController


- (void)viewDidLoad {
    [super viewDidLoad];

    // Do any additional setup after loading the view.
    [self setUpViews];
}


- (void)setRepresentedObject:(id)representedObject {
    [super setRepresentedObject:representedObject];
    
    // Update the view, if already loaded.
}

- (void)setUpViews {
    // add a button for select file
    NSButton *openFileBtn = [[NSButton alloc] init];
    [openFileBtn setTitle:@"Choose movie"];
    [self.view addSubview:openFileBtn];
    [openFileBtn mas_makeConstraints:^(MASConstraintMaker *make) {
        make.width.equalTo(@100);
        make.height.equalTo(@50);
        make.left.equalTo(self.view);
        make.top.equalTo(self.view);
    }];
    [openFileBtn setTarget:self];
    [openFileBtn setAction:@selector(chooseMovie)];
    //test code
    [self openMediaWithUrl:[NSURL fileURLWithPath:@"/Users/liuzhimin/Downloads/SE1101.mp4"]];
}

- (void)chooseMovie {
    NSLog(@"choose 🎬");
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    [panel setCanChooseFiles:YES];
    [panel setCanChooseDirectories:NO];
    [panel setAllowsMultipleSelection:NO];
    [panel setAllowedFileTypes:@[@"mp4",@"mkv",@"avi",@"rmvb"]];
    [panel setTitle:@"choose a movie"];
    NSInteger clicked = [panel runModal];
    
    if (clicked == NSFileHandlingPanelOKButton) {
        for (NSURL *url in [panel URLs]) {
            // do something with the url here.
            NSLog(@"🎬 :%@",url);
            [self openMediaWithUrl:url];
        }
    }
}

- (void)openMediaWithUrl:(NSURL *)url {
    LzmPlayerViewController *Player = [[LzmPlayerViewController alloc] initWithMovieUrl:url];
    [self.view addSubview:Player.view];
    [Player.view mas_makeConstraints:^(MASConstraintMaker *make) {
        make.centerX.equalTo(self.view);
        make.width.equalTo(@800);
        make.height.equalTo(@450);
        make.centerY.equalTo(self.view);
    }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [Player play];
    });
}


@end
