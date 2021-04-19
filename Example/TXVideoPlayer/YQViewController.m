//
//  YQViewController.m
//  TXVideoPlayer
//
//  Created by wyqpadding@gmail.com on 04/16/2021.
//  Copyright (c) 2021 wyqpadding@gmail.com. All rights reserved.
//

#import "YQViewController.h"
#import <SuperPlayer.h>

@import Masonry;

@interface YQViewController ()

@end

@implementation YQViewController

- (void)viewDidLoad
{
    [super viewDidLoad];
	// Do any additional setup after loading the view, typically from a nib.
    SuperPlayerView *view = [[SuperPlayerView alloc] init];
    [self.view addSubview:view];
    [view mas_makeConstraints:^(MASConstraintMaker *make) {
        make.leading.trailing.top.equalTo(self.view);
        make.height.mas_equalTo(200);
    }];
    view.backgroundColor = UIColor.blackColor;
    SuperPlayerView *player = view;
    player.fatherView = self.view;
    player.autoPlay = YES;
    SuperPlayerModel *model = [[SuperPlayerModel alloc] init];
    model.videoURL = @"http://200024424.vod.myqcloud.com/200024424_709ae516bdf811e6ad39991f76a4df69.f20.mp4";
    [player playWithModel:model];
    
}

- (void)didReceiveMemoryWarning
{
    [super didReceiveMemoryWarning];
    // Dispose of any resources that can be recreated.
}

@end
