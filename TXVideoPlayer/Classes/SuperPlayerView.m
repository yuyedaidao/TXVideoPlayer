#import "SuperPlayerView.h"
#import <AVFoundation/AVFoundation.h>
#import "SuperPlayer.h"
#import "SuperPlayerControlViewDelegate.h"
#import "J2Obj.h"
#import "SuperPlayerView+Private.h"
#import "DataReport.h"
#import "TXCUrl.h"
#import "StrUtils.h"
#import "UIView+Fade.h"
#import "TXBitrateItemHelper.h"
#import "UIView+MMLayout.h"
#import "SPDefaultControlView.h"
#import "SuperPlayerModelInternal.h"
#import "NSString+URL.h"
// TODO: 处理头部引用
#import "TXAudioCustomProcessDelegate.h"
#import "TXAudioRawDataDelegate.h"
#import "TXBitrateItem.h"
#import "TXImageSprite.h"
#import "TXLiteAVCode.h"
#import "TXLiveAudioSessionDelegate.h"
#import "TXLiveBase.h"
#import "TXLivePlayConfig.h"
#import "TXLivePlayListener.h"
#import "TXLivePlayer.h"
#import "TXLiveRecordListener.h"
#import "TXLiveRecordTypeDef.h"
#import "TXLiveSDKEventDef.h"
#import "TXLiveSDKTypeDef.h"
#import "TXPlayerAuthParams.h"
#ifdef ENABLE_UGC
#import "TXUGCBase.h"
#import "TXUGCPartsManager.h"
#import "TXUGCRecord.h"
#import "TXUGCRecordListener.h"
#import "TXUGCRecordTypeDef.h"
#endif
#import "TXVideoCustomProcessDelegate.h"
#import "TXVodPlayConfig.h"
#import "TXVodPlayListener.h"
#import "TXVodPlayer.h"

#define CellPlayerFatherViewTag  200
#define SUPPORT_PARAM_MAJOR_VERSION (8)
#define SUPPORT_PARAM_MINOR_VERSION (2)

//忽略编译器的警告
#pragma clang diagnostic push
#pragma clang diagnostic ignored"-Wdeprecated-declarations"

@interface VolumeViewManager: NSObject {
    UISlider *_slider;
}
@property (strong) MPVolumeView *volumeView;
@property (readonly) UISlider *volumeSlider;
@end

@implementation VolumeViewManager
+ (instancetype)shared {
    static VolumeViewManager *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[VolumeViewManager alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    CGRect frame = CGRectMake(0, -100, 10, 0);
    self.volumeView = [[MPVolumeView alloc] initWithFrame:frame];
    [self.volumeView sizeToFit];
    for (UIView *view in [self.volumeView subviews]){
        if ([view.class.description isEqualToString:@"MPVolumeSlider"]){
            _slider = (UISlider *)view;
            break;
        }
    }
    return self;
}

- (UISlider *)volumeSlider {
    if(_volumeView.superview == nil) {
        for (UIWindow *window in [[UIApplication sharedApplication] windows]) {
            if (!window.isHidden) {
                [window addSubview:self.volumeView];
                break;
            }
        }
    }
    return _slider;
}
@end


@interface SuperPlayerView()
@property (assign, nonatomic) BOOL isFirstFrameLoaded; //FIRST_I_FRAME;
@property (nonatomic, copy) dispatch_block_t delayResumeBlock;
@end

@implementation SuperPlayerView {
    SuperPlayerControlView *_controlView;
    NSURLSessionTask *_currentLoadingTask;
}


#pragma mark - life Cycle

/**
 *  代码初始化调用此方法
 */
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) { [self initializeThePlayer]; }
    return self;
}

/**
 *  storyboard、xib加载playerView会调用此方法
 */
- (void)awakeFromNib {
    [super awakeFromNib];
    [self initializeThePlayer];
}

/**
 *  初始化player
 */
- (void)initializeThePlayer {
    _replaceSystemVolumeView = YES;
    LOG_ME;
    self.netWatcher = [[NetWatcher alloc] init];
    
    _fullScreenBlackView = [UIView new];
    _fullScreenBlackView.backgroundColor = [UIColor blackColor];
  
    // 默认允许拖动进度
    _sliderEnable = YES;
    _playerConfig = [[SuperPlayerViewConfig alloc] init];
    // 添加通知
    [self addNotifications];
    // 添加手势
    [self createGesture];
    
    self.autoPlay = YES;
    self.allowAutoObserveOrientationChange = NO;
}


- (void)dealloc {
    LOG_ME;
    if (self.delayResumeBlock) {
        dispatch_block_cancel(self.delayResumeBlock);
    }
    // 移除通知
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [[UIDevice currentDevice] endGeneratingDeviceOrientationNotifications];
    
    [self reportPlay];
    [self.netWatcher stopWatch];
}

- (void)setAllowShowFastView:(BOOL)allowShowFastView {
    if (_allowShowFastView != allowShowFastView) {
        _allowShowFastView = allowShowFastView;
        if (!allowShowFastView) {
            _fastView.hidden = YES;
        }
    }
}

#pragma mark - 观察者、通知

/**
 *  添加观察者、通知
 */
- (void)addNotifications {
    // app退到后台
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(appDidEnterBackground:) name:UIApplicationDidEnterBackgroundNotification object:nil];
    // app进入前台
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(appDidEnterPlayground:) name:UIApplicationWillEnterForegroundNotification object:nil];
    
    // 监测设备方向
    [[UIDevice currentDevice] beginGeneratingDeviceOrientationNotifications];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(onDeviceOrientationChange)
                                                 name:UIDeviceOrientationDidChangeNotification
                                               object:nil];
    
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(onStatusBarOrientationChange)
                                                 name:UIApplicationDidChangeStatusBarOrientationNotification
                                               object:nil];
}

#pragma mark - layoutSubviews

- (void)layoutSubviews {
    [super layoutSubviews];
    if (self.subviews.count > 0) {
        UIView *innerView = self.subviews[0];
        if ([innerView isKindOfClass:NSClassFromString(@"TXIJKSDLGLView")] ||
            [innerView isKindOfClass:NSClassFromString(@"TXCAVPlayerView")]) {
            innerView.frame = self.bounds;
        }
    }
}

#pragma mark - Public Method

- (void)playWithModel:(SuperPlayerModel *)playerModel {
    LOG_ME;
    self.isShiftPlayback = NO;
    self.imageSprite = nil;
    self.originalDuration = 0;
    [self reportPlay];
    self.reportTime = [NSDate date];
    [self _removeOldPlayer];
    self.isFirstFrameLoaded = NO;
    [self _playWithModel:playerModel];
    self.coverImageView.alpha = 1;
    self.repeatBtn.hidden = YES;
    self.repeatBackBtn.hidden = YES;
    // 播放时添加监听
    [self addNotifications];
}

- (void)reloadModel {
    SuperPlayerModel *model = _playerModel;
    if (model) {
        [self resetPlayer];
        [self _playWithModel:_playerModel];
        [self addNotifications];
    }
}

- (void)_playWithModel:(SuperPlayerModel *)playerModel {
    [_currentLoadingTask cancel];
    _currentLoadingTask = nil;

    _playerModel = playerModel;

    [self pause];
    
    NSString *videoURL = playerModel.playingDefinitionUrl;
    if (videoURL != nil) {
        [self configTXPlayer];
    } else if (playerModel.videoId || playerModel.videoIdV2) {
        self.isLive = NO;
        __weak __typeof(self) weakSelf = self;
        _currentLoadingTask = [_playerModel requestWithCompletion:
                               ^(NSError *error,SuperPlayerModel *model) {
            if (error) {
                [weakSelf _onModelLoadFailed:model error:error];
            } else {
                weakSelf.imageSprite = model.imageSprite;
                weakSelf.keyFrameDescList = model.keyFrameDescList;
                weakSelf.originalDuration = model.originalDuration;
                [weakSelf _onModelLoadSucceed:model];
            }
        }];
        return;
    } else {
        NSLog(@"无播放地址");
        return;
    }
}

- (void)_onModelLoadSucceed:(SuperPlayerModel *)model {
    if (model == _playerModel) {
        [self _playWithModel:_playerModel];
    }
}

- (void)_onModelLoadFailed:(SuperPlayerModel *)model error:(NSError *)error {
    if (model != _playerModel) {
        return;
    }
    // error 错误信息
    [self showMiddleBtnMsg:kStrLoadFaildRetry withAction:ActionRetry];
    [self.spinner stopAnimating];
    NSLog(@"Load play model failed. fileID: %@, error: %@",
          _playerModel.videoId.fileId, error);
    if ([self.delegate respondsToSelector:@selector(superPlayerError:errCode:errMessage:)]) {
        NSString *message = [NSString stringWithFormat:@"网络请求失败 %d %@",
                             (int)error.code, error.localizedDescription];
        [self.delegate superPlayerError:self
                                errCode:(int)error.code
                             errMessage:message];
    }
    return;
}

/**
 *  player添加到fatherView上
 */
- (void)addPlayerToFatherView:(UIView *)view {
    [self removeFromSuperview];
    if (view) {
        [view addSubview:self];
        [self mas_remakeConstraints:^(MASConstraintMaker *make) {
            make.edges.mas_offset(UIEdgeInsetsZero);
        }];
    }
}

- (void)setFatherView:(UIView *)fatherView {
    if (fatherView != _fatherView) {
        [self addPlayerToFatherView:fatherView];
    }
    _fatherView = fatherView;
}

/**
 *  重置player
 */
- (void)resetPlayer {
    LOG_ME;
    // 移除通知
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    // 暂停
    [self pause];
    
    [self.vodPlayer stopPlay];
    [self.vodPlayer removeVideoWidget];
    self.vodPlayer = nil;
    
    [self.livePlayer stopPlay];
    [self.livePlayer removeVideoWidget];
    self.livePlayer = nil;
    
    [self reportPlay];
    _isFirstFrameLoaded = NO;
    self.state = StateStopped;
    if (_autoEnableIdleTimer) {
        UIApplication.sharedApplication.idleTimerDisabled = NO;
    }
}

/**
 *  播放
 */
- (void)resume {
    LOG_ME;
    [self.controlView setPlayState:YES];
    self.isPauseByUser = NO;
    self.state = StatePlaying;
    if (self.isLive) {
        [_livePlayer resume];
    } else {
        [_vodPlayer resume];
    }
}

/**
 * 暂停
 */
- (void)pause {
    LOG_ME;
    if (!self.isLoaded)
        return;
    [self.controlView setPlayState:NO];
    self.isPauseByUser = YES;
    self.state = StatePause;
    if (self.isLive) {
        [_livePlayer pause];
    } else {
        [_vodPlayer pause];
    }
}
#pragma mark - Control View Configuration
- (void)resetControlViewWithLive:(BOOL)isLive
                   shiftPlayback:(BOOL)isShiftPlayback
                       isPlaying:(BOOL)isPlaying
{
    [_controlView resetWithResolutionNames:self.playerModel.playDefinitions
                    currentResolutionIndex:self.playerModel.playingDefinitionIndex
                                    isLive:isLive
                            isTimeShifting:isShiftPlayback
                                 isPlaying:isPlaying];
}

#pragma mark - Private Method
- (BOOL)isSupportAppendParam {
    NSString* version = [TXLiveBase getSDKVersionStr];
    NSArray* vers = [version componentsSeparatedByString:@"."];
    if (vers.count <= 1) {
        return NO;
    }
    NSInteger majorVer = [vers[0] integerValue]?:0;
    NSInteger minorVer = [vers[1] integerValue]?:0;
    return majorVer >= SUPPORT_PARAM_MAJOR_VERSION && minorVer >= SUPPORT_PARAM_MINOR_VERSION;
}

/**
 *  设置Player相关参数
 */
- (void)configTXPlayer {
    LOG_ME;
    self.backgroundColor = [UIColor blackColor];
    
    if (_playerConfig.enableLog) {
        [TXLiveBase setLogLevel:LOGLEVEL_DEBUG];
        [TXLiveBase sharedInstance].delegate = self;
        [TXLiveBase setConsoleEnabled:YES];
    } else {
        [TXLiveBase setConsoleEnabled:NO];
    }
    
    [self.vodPlayer stopPlay];
    [self.vodPlayer removeVideoWidget];
    [self.livePlayer stopPlay];
    [self.livePlayer removeVideoWidget];
    
    self.liveProgressTime = self.maxLiveProgressTime = 0;
    
    int liveType = [self livePlayerType];
    if (liveType >= 0) {
        self.isLive = YES;
    } else {
        self.isLive = NO;
    }
    self.isLoaded = NO;
    
    self.netWatcher.playerModel = self.playerModel;
    //时移播放需要原始分辨率播放流地址
//    if (self.playerModel.playingDefinition == nil) {
//        self.playerModel.playingDefinition = self.netWatcher.adviseDefinition;
//    }
    NSString *videoURL = self.playerModel.playingDefinitionUrl;
    // 时移
    [TXLiveBase setAppID:[NSString stringWithFormat:@"%ld", _playerModel.appId]];
    if (self.isLive) {
        if (!self.livePlayer) {
            self.livePlayer = [[TXLivePlayer alloc] init];
            self.livePlayer.delegate = self;
        }
        TXLivePlayConfig *config = [[TXLivePlayConfig alloc] init];
        config.bAutoAdjustCacheTime = NO;
        config.maxAutoAdjustCacheTime = 5.0f;
        config.minAutoAdjustCacheTime = 5.0f;
        config.headers = self.playerConfig.headers;
        [self.livePlayer setConfig:config];
        
        
        self.livePlayer.enableHWAcceleration = self.playerConfig.hwAcceleration;
        [self.livePlayer startPlay:videoURL type:liveType];
        TXCUrl *curl = [[TXCUrl alloc] initWithString:videoURL];
        [self.livePlayer prepareLiveSeek:self.playerConfig.playShiftDomain bizId:curl.bizid];
        [self.livePlayer setMute:self.playerConfig.mute];
        [self.livePlayer setRenderMode:self.playerConfig.renderMode];
    } else {
        if (!self.vodPlayer) {
            self.vodPlayer = [[TXVodPlayer alloc] init];
            self.vodPlayer.vodDelegate = self;
        }
        
        TXVodPlayConfig *config = [[TXVodPlayConfig alloc] init];
        config.smoothSwitchBitrate = YES;
        if (self.playerConfig.maxCacheItem) {
            // https://github.com/tencentyun/SuperPlayer_iOS/issues/64
            config.cacheFolderPath = [[NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) objectAtIndex:0] stringByAppendingString:@"/TXCache"];
            config.maxCacheItems = (int)self.playerConfig.maxCacheItem;
        }
        config.progressInterval = 0.02;
        self.vodPlayer.token = self.playerModel.drmToken;

        config.headers = self.playerConfig.headers;
        
        [self.vodPlayer setConfig:config];
        
        self.vodPlayer.enableHWAcceleration = self.playerConfig.hwAcceleration;
        [self.vodPlayer setStartTime:self.startTime]; self.startTime = 0;

        NSString *appParameter = [NSString stringWithFormat:@"spappid=%ld",self.playerModel.appId];
        NSString *fileidParameter = [NSString stringWithFormat:@"spfileid=%@",self.playerModel.videoId.fileId];
        NSString *drmtypeParameter = [NSString stringWithFormat:@"spdrmtype=%@",
                                      self.playerModel.drmType == SPDrmTypeSimpleAES ? @"SimpleAES" : @"plain"];
        NSString *vodParamVideoUrl = [NSString appendParameter:appParameter WithOriginUrl:videoURL];
        vodParamVideoUrl = [NSString appendParameter:fileidParameter WithOriginUrl:vodParamVideoUrl];
        vodParamVideoUrl = [NSString appendParameter:drmtypeParameter WithOriginUrl:vodParamVideoUrl];
        
        [self.vodPlayer startPlay:([self isSupportAppendParam] ? vodParamVideoUrl : videoURL)];
        [self.vodPlayer setBitrateIndex:self.playerModel.playingDefinitionIndex];
        
        [self.vodPlayer setRate:self.playerConfig.playRate];
        [self.vodPlayer setMirror:self.playerConfig.mirror];
        [self.vodPlayer setMute:self.playerConfig.mute];
        [self.vodPlayer setRenderMode:self.playerConfig.renderMode];
        [self.vodPlayer setLoop:self.loop];
    }
    [self.netWatcher startWatch];
    __weak SuperPlayerView *weakSelf = self;
    [self.netWatcher setNotifyTipsBlock:^(NSString *msg) {
        SuperPlayerView *strongSelf = weakSelf;
        if (strongSelf) {
            [strongSelf showMiddleBtnMsg:msg withAction:ActionSwitch];
            [strongSelf.middleBlackBtn fadeOut:2];
        }
    }];
    self.state = StateBuffering;
    self.isPauseByUser = NO;
    [self resetControlViewWithLive:self.isLive
                     shiftPlayback:self.isShiftPlayback
                         isPlaying:self.autoPlay];
    self.controlView.playerConfig = self.playerConfig;
    self.repeatBtn.hidden = YES;
    self.repeatBackBtn.hidden = YES;
    self.playDidEnd = NO;
    [self.middleBlackBtn fadeOut:0.1];
}

/**
 *  创建手势
 */
- (void)createGesture {
    // 单击
    self.singleTap = [[UITapGestureRecognizer alloc]initWithTarget:self action:@selector(singleTapAction:)];
    self.singleTap.delegate                = self;
    self.singleTap.numberOfTouchesRequired = 1; //手指数
    self.singleTap.numberOfTapsRequired    = 1;
    [self addGestureRecognizer:self.singleTap];
    
    // 双击(播放/暂停)
    self.doubleTap = [[UITapGestureRecognizer alloc]initWithTarget:self action:@selector(doubleTapAction:)];
    self.doubleTap.delegate                = self;
    self.doubleTap.numberOfTouchesRequired = 1; //手指数
    self.doubleTap.numberOfTapsRequired    = 2;
    [self addGestureRecognizer:self.doubleTap];

    // 解决点击当前view时候响应其他控件事件
    [self.singleTap setDelaysTouchesBegan:YES];
    [self.doubleTap setDelaysTouchesBegan:YES];
    // 双击失败响应单击事件
    [self.singleTap requireGestureRecognizerToFail:self.doubleTap];
    
    // 加载完成后，再添加平移手势
    // 添加平移手势，用来控制音量、亮度、快进快退
    UIPanGestureRecognizer *panRecognizer = [[UIPanGestureRecognizer alloc]initWithTarget:self action:@selector(panDirection:)];
    panRecognizer.delegate = self;
    [panRecognizer setMaximumNumberOfTouches:1];
    [panRecognizer setDelaysTouchesBegan:YES];
    [panRecognizer setDelaysTouchesEnded:YES];
    [panRecognizer setCancelsTouchesInView:YES];
    [self addGestureRecognizer:panRecognizer];
    self.panGesture = panRecognizer;
}

- (void)touchesEnded:(NSSet *)touches withEvent:(UIEvent *)event {

}

#pragma mark - KVO

/**
 *  设置横屏的约束
 */
- (void)setOrientationLandscapeConstraint:(UIInterfaceOrientation)orientation {
    _isFullScreen = YES;
//    [self _switchToLayoutStyle:orientation];
}

/**
 *  设置竖屏的约束
 */
- (void)setOrientationPortraitConstraint {

    [self addPlayerToFatherView:self.fatherView];
    _isFullScreen = NO;
//    [self _switchToLayoutStyle:UIInterfaceOrientationPortrait];
}

- (UIDeviceOrientation)_orientationForFullScreen:(BOOL)fullScreen {
    UIDeviceOrientation targetOrientation = [UIDevice currentDevice].orientation;
    if (fullScreen) {
        if (!UIDeviceOrientationIsLandscape(targetOrientation)) {
            targetOrientation = UIDeviceOrientationLandscapeLeft;
        }
    } else {
        if (!UIDeviceOrientationIsPortrait(targetOrientation)) {
            targetOrientation = UIDeviceOrientationPortrait;
        }
    //    targetOrientation = (UIDeviceOrientation)[UIApplication sharedApplication].statusBarOrientation;
    }
    return targetOrientation;
}

- (void)_switchToFullScreen:(BOOL)fullScreen {
    if (_isFullScreen == fullScreen) {
        return;
    }
    _isFullScreen = fullScreen;
    [self.fatherView.viewController setNeedsStatusBarAppearanceUpdate];

    UIDeviceOrientation targetOrientation = [self _orientationForFullScreen:fullScreen];// [UIDevice currentDevice].orientation;

    if (fullScreen) {
        [self removeFromSuperview];
        [[UIApplication sharedApplication].keyWindow addSubview:_fullScreenBlackView];
        [_fullScreenBlackView mas_makeConstraints:^(MASConstraintMaker *make) {
            make.width.equalTo(@(ScreenHeight));
            make.height.equalTo(@(ScreenWidth));
            make.center.equalTo([UIApplication sharedApplication].keyWindow);
        }];

        [[UIApplication sharedApplication].keyWindow addSubview:self];
        [self mas_remakeConstraints:^(MASConstraintMaker *make) {
            if (IsIPhoneX) {
                make.width.equalTo(@(ScreenHeight - self.mm_safeAreaTopGap * 2));
            } else {
                make.width.equalTo(@(ScreenHeight));
            }
            make.height.equalTo(@(ScreenWidth));
            make.center.equalTo([UIApplication sharedApplication].keyWindow);
        }];
        [self.superview setNeedsLayout];
    } else {
        [_fullScreenBlackView removeFromSuperview];
        [self addPlayerToFatherView:self.fatherView];
    }
}

- (void)_switchToLayoutStyle:(SuperPlayerLayoutStyle)style {
    // 获取到当前状态条的方向

//    UIInterfaceOrientation currentOrientation = [UIDevice currentDevice].orientation;
    // 判断如果当前方向和要旋转的方向一致,那么不做任何操作
//    if (currentOrientation == orientation) { return; }
    
    // 根据要旋转的方向,使用Masonry重新修改限制
    if (style == SuperPlayerLayoutStyleFullScreen) {//
        // 这个地方加判断是为了从全屏的一侧,直接到全屏的另一侧不用修改限制,否则会出错;
        if (_layoutStyle != SuperPlayerLayoutStyleFullScreen)  { //UIInterfaceOrientationIsPortrait(currentOrientation)) {
            [self removeFromSuperview];
            [[UIApplication sharedApplication].keyWindow addSubview:_fullScreenBlackView];
            [_fullScreenBlackView mas_remakeConstraints:^(MASConstraintMaker *make) {
                make.width.equalTo(@(ScreenHeight));
                make.height.equalTo(@(ScreenWidth));
                make.center.equalTo([UIApplication sharedApplication].keyWindow);
            }];

            [[UIApplication sharedApplication].keyWindow addSubview:self];
            [self mas_remakeConstraints:^(MASConstraintMaker *make) {
                if (IsIPhoneX) {
                    make.width.equalTo(@(ScreenHeight - self.mm_safeAreaTopGap * 2));
                } else {
                    make.width.equalTo(@(ScreenHeight));
                }
                make.height.equalTo(@(ScreenWidth));
                make.center.equalTo([UIApplication sharedApplication].keyWindow);
            }];
        }
    } else {
        [_fullScreenBlackView removeFromSuperview];
    }
    self.controlView.compact = style == SuperPlayerLayoutStyleCompact;

    [[UIApplication sharedApplication].keyWindow  layoutIfNeeded];

}

- (void)_adjustTransform:(UIDeviceOrientation)orientation {

    [UIView beginAnimations:nil context:nil];
    [UIView setAnimationDuration:0.3];

    self.transform = [self getTransformRotationAngleOfOrientation:orientation];
    _fullScreenBlackView.transform = self.transform;
    [UIView commitAnimations];
}

/**
 * 获取变换的旋转角度
 *
 * @return 变换矩阵
 */
- (CGAffineTransform)getTransformRotationAngleOfOrientation:(UIDeviceOrientation)orientation {
    // 状态条的方向已经设置过,所以这个就是你想要旋转的方向
    UIInterfaceOrientation interfaceOrientation = [UIApplication sharedApplication].statusBarOrientation;
    if (interfaceOrientation == (UIInterfaceOrientation)orientation) {
        return CGAffineTransformIdentity;
    }
    // 根据要进行旋转的方向来计算旋转的角度
    if (orientation == UIInterfaceOrientationPortrait) {
        return CGAffineTransformIdentity;
    } else if (orientation == UIInterfaceOrientationLandscapeLeft){
        return CGAffineTransformMakeRotation(-M_PI_2);
    } else if(orientation == UIInterfaceOrientationLandscapeRight){
        return CGAffineTransformMakeRotation(M_PI_2);
    }
    return CGAffineTransformIdentity;
}

#pragma mark 屏幕转屏相关

/**
 *  屏幕转屏
 *
 *  @param orientation 屏幕方向
 */
- (void)interfaceOrientation:(UIInterfaceOrientation)orientation {
    if (orientation == UIInterfaceOrientationLandscapeRight || orientation == UIInterfaceOrientationLandscapeLeft) {
        // 设置横屏
        [self setOrientationLandscapeConstraint:orientation];
    } else if (orientation == UIInterfaceOrientationPortrait) {
        // 设置竖屏
        [self setOrientationPortraitConstraint];
    }
}

- (SuperPlayerLayoutStyle)defaultStyleForDeviceOrientation:(UIDeviceOrientation)orientation {
    if (UIDeviceOrientationIsPortrait(orientation)) {
        return SuperPlayerLayoutStyleCompact;
    } else {
        return SuperPlayerLayoutStyleFullScreen;
    }
}

#pragma mark - Action

/**
 *   轻拍方法
 *
 *  @param gesture UITapGestureRecognizer
 */
- (void)singleTapAction:(UIGestureRecognizer *)gesture {
    if (gesture.state == UIGestureRecognizerStateRecognized) {
        
        if (self.playDidEnd && !_allowRecognizeSingleTapWhenPlayEnd) {
            return;
        }
        if (SuperPlayerWindowShared.isShowing)
            return;
        
        if (self.controlView.hidden) {
            [[self.controlView fadeShow] fadeOut:5];
        } else {
            [self.controlView fadeOut:0.2];
        }
    }
}

/**
 *  双击播放/暂停
 *
 *  @param gesture UITapGestureRecognizer
 */
- (void)doubleTapAction:(UIGestureRecognizer *)gesture {
    if (self.playDidEnd) { return;  }
    // 显示控制层
    [self.controlView fadeShow];
    if (self.isPauseByUser) {
        [self resume];
    } else {
        [self pause];
    }
}



/** 全屏 */
- (void)setFullScreen:(BOOL)fullScreen {

    if (_isFullScreen != fullScreen) {
        [self _adjustTransform:[self _orientationForFullScreen:fullScreen]];
        [self _switchToFullScreen:fullScreen];
        [self _switchToLayoutStyle:fullScreen ? SuperPlayerLayoutStyleFullScreen : SuperPlayerLayoutStyleCompact];
    }
    _isFullScreen = fullScreen;
}

/**
 *  播放完了
 *
 */
- (void)moviePlayDidEnd {
    self.state = StateStopped;
    self.playDidEnd = YES;
    // 播放结束隐藏
    if (SuperPlayerWindowShared.isShowing) {
        [SuperPlayerWindowShared hide];
        [self resetPlayer];
    }
    if (self.allowShowRepeatView) {
        [self.controlView fadeOut:0.2];
    }
    [self fastViewUnavaliable];
    if (self.playEndHandler) {
        @m_weakify(self);
        self.playEndHandler(^{
            @m_strongify(self);
            [self playEndAfter];
        });
    } else {
        [self playEndAfter];
    }
}

- (void)playEndAfter {
    [self.netWatcher stopWatch];
    if (self.allowShowRepeatView) {
        self.repeatBtn.hidden = NO;
        self.repeatBackBtn.hidden = NO;
    } else {
        [self.controlView setPlayState:NO];
        [self.controlView setProgressTime:0 totalTime:0 progressValue:0 playableValue:0];
        [self.controlView fadeShow];
    }
    
    if ([self.delegate respondsToSelector:@selector(superPlayerDidEnd:)]) {
        [self.delegate superPlayerDidEnd:self];
    }
}

#pragma mark - UIKit Notifications

/**
 *  应用退到后台
 */
- (void)appDidEnterBackground:(NSNotification *)notify {
    self.didEnterBackground = YES;
    if (self.isLive) {
        return;
    }
    if (!self.isPauseByUser && (self.state != StateStopped && self.state != StateFailed)) {
        if (self.delayResumeBlock) {
            dispatch_block_cancel(self.delayResumeBlock);
        }
        [_vodPlayer pause];
        self.state = StatePause;
    }
}

/**
 *  应用进入前台
 */
- (void)appDidEnterPlayground:(NSNotification *)notify {
    self.didEnterBackground = NO;
    if (self.isLive) {
        return;
    }
    if (!self.isPauseByUser && (self.state != StateStopped && self.state != StateFailed)) {
        __weak __typeof(self)weakSelf = self;
        [_controlView setPlayState:NO];
        self.delayResumeBlock = dispatch_block_create(0, ^{
            __strong __typeof(weakSelf)self = weakSelf;
            UIResponder *responder = self;
            while (responder = responder.nextResponder) {
                if ([responder isKindOfClass:UIViewController.class]) {
                    UIViewController *vc = (UIViewController *)responder;
                    if (vc.navigationController.visibleViewController == vc) {
                        self.state = StatePlaying;
                        [self.vodPlayer resume];
                        [self.controlView setPlayState:YES];
                        return;
                    }
                }
            }
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1500 * NSEC_PER_MSEC)), dispatch_get_main_queue(), _delayResumeBlock);
    }
}

// 状态条变化通知（在前台播放才去处理）
- (void)onStatusBarOrientationChange {
    if (!self.allowAutoObserveOrientationChange) {
        return;
    }
    [self onDeviceOrientationChange];
    return;
    if (!self.didEnterBackground) {
        UIInterfaceOrientation orientation = (UIInterfaceOrientation)[UIDevice currentDevice].orientation;
        SuperPlayerLayoutStyle style = [self defaultStyleForDeviceOrientation:orientation];
//        [[UIApplication sharedApplication] setStatusBarOrientation:orientation animated:NO];
        if ([UIApplication sharedApplication].statusBarOrientation != orientation) {
            [self _adjustTransform:(UIInterfaceOrientation)[UIDevice currentDevice].orientation];
        }
        [self _switchToFullScreen:style == SuperPlayerLayoutStyleFullScreen];
        [self _switchToLayoutStyle:style];
    }
}

/**
 *  屏幕方向发生变化会调用这里
 */
- (void)onDeviceOrientationChange {
    if (!self.allowAutoObserveOrientationChange) {
        return;
    }
    if (!self.isLoaded) { return; }
    if (self.isLockScreen) { return; }
    if (self.didEnterBackground) { return; };
    if (SuperPlayerWindowShared.isShowing) { return; }
    UIDeviceOrientation orientation = [UIDevice currentDevice].orientation;
    if (orientation == UIDeviceOrientationFaceUp || orientation == UIDeviceOrientationFaceDown) {
        return;
    }
    SuperPlayerLayoutStyle style = [self defaultStyleForDeviceOrientation:[UIDevice currentDevice].orientation];

    BOOL shouldFullScreen = UIDeviceOrientationIsLandscape(orientation);
    [self _switchToFullScreen:shouldFullScreen];
    [self _adjustTransform:[self _orientationForFullScreen:shouldFullScreen]];
    [self _switchToLayoutStyle:style];
}

#pragma mark -
- (void)seekToTime:(NSInteger)dragedSeconds {
    if (!self.isLoaded || self.state == StateStopped) {
        return;
    }
    if (self.isLive) {
        [DataReport report:@"timeshift" param:nil];
        int ret = [self.livePlayer seek:dragedSeconds];
        if (ret != 0) {
            [self showMiddleBtnMsg:kStrTimeShiftFailed withAction:ActionNone];
            [self.middleBlackBtn fadeOut:2];
            [self resetControlViewWithLive:self.isLive
                             shiftPlayback:self.isShiftPlayback
                                 isPlaying:YES];
        } else {
            if (!self.isShiftPlayback)
                self.isLoaded = NO;
            self.isShiftPlayback = YES;
            self.state = StateBuffering;
            [self resetControlViewWithLive:YES
                             shiftPlayback:self.isShiftPlayback
                                 isPlaying:YES]; //时移播放不能切码率
        }
    } else {
        [self.vodPlayer resume];
        [self.vodPlayer seek:dragedSeconds];
        [self.controlView setPlayState:YES];
    }
}

#pragma mark - UIPanGestureRecognizer手势方法
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    return [self.gestureDelegate superPlayerGestureRecognizerShouldBegin: gestureRecognizer];
}
/**
 *  pan手势事件
 *
 *  @param pan UIPanGestureRecognizer
 */
- (void)panDirection:(UIPanGestureRecognizer *)pan {

    //根据在view上Pan的位置，确定是调音量还是亮度
    CGPoint locationPoint = [pan locationInView:self];
    
    // 我们要响应水平移动和垂直移动
    // 根据上次和本次移动的位置，算出一个速率的point
    CGPoint veloctyPoint = [pan velocityInView:self];
    
    if (self.state == StateStopped)
        return;
    
    // 判断是垂直移动还是水平移动
    switch (pan.state) {
        case UIGestureRecognizerStateBegan:{ // 开始移动
            // 使用绝对值来判断移动的方向
            CGFloat x = fabs(veloctyPoint.x);
            CGFloat y = fabs(veloctyPoint.y);
            if (x > y) { // 水平移动
                if (self.isSliderEnable) {
                    // 取消隐藏
                    self.panDirection = PanDirectionHorizontalMoved;
                    self.sumTime      = [self playCurrentTime];
                }
            }
            else if (x < y){ // 垂直移动
                self.panDirection = PanDirectionVerticalMoved;
                // 开始滑动的时候,状态改为正在控制音量
                if (locationPoint.x > self.bounds.size.width / 2) {
                    self.isVolume = YES;
                }else { // 状态改为显示亮度调节
                    self.isVolume = NO;
                }
            }
            self.isDragging = YES;
            [self.controlView fadeOut:0.2];
            break;
        }
        case UIGestureRecognizerStateChanged:{ // 正在移动
            switch (self.panDirection) {
                case PanDirectionHorizontalMoved:{
                    if (self.isSliderEnable) {
                        [self horizontalMoved:veloctyPoint.x]; // 水平移动的方法只要x方向的值
                    }
                    break;
                }
                case PanDirectionVerticalMoved:{
                    [self verticalMoved:veloctyPoint.y]; // 垂直移动方法只要y方向的值
                    break;
                }
                default:
                    break;
            }
            self.isDragging = YES;
            break;
        }
        case UIGestureRecognizerStateEnded:{ // 移动停止
            // 移动结束也需要判断垂直或者平移
            // 比如水平移动结束时，要快进到指定位置，如果这里没有判断，当我们调节音量完之后，会出现屏幕跳动的bug
            switch (self.panDirection) {
                case PanDirectionHorizontalMoved:{
                    if (self.isSliderEnable) {
                        self.isPauseByUser = NO;
                        [self seekToTime:self.sumTime];
                        // 把sumTime滞空，不然会越加越多
                        self.sumTime = 0;
                    }
                    break;
                }
                case PanDirectionVerticalMoved:{
                    // 垂直移动结束后，把状态改为不再控制音量
                    self.isVolume = NO;
                    break;
                }
                default:
                    break;
            }
            [self fastViewUnavaliable];
            self.isDragging = NO;
            break;
        }
        case UIGestureRecognizerStateCancelled: {
            self.sumTime = 0;
            self.isVolume = NO;
            [self fastViewUnavaliable];
            self.isDragging = NO;
        }
        default:
            break;
    }
}

/**
 *  pan垂直移动的方法
 *
 *  @param value void
 */
- (void)verticalMoved:(CGFloat)value {
   
    self.isVolume ? ([[self class] volumeViewSlider].value -= value / 10000) : ([UIScreen mainScreen].brightness -= value / 10000);

    if (self.isVolume) {
        [self fastViewImageAvaliable:SuperPlayerImage(@"sound_max") progress:[[self class] volumeViewSlider].value];
    } else {
        [self fastViewImageAvaliable:SuperPlayerImage(@"light_max") progress:[UIScreen mainScreen].brightness];
    }
}

/**
 *  pan水平移动的方法
 *
 *  @param value void
 */
- (void)horizontalMoved:(CGFloat)value {
    // 每次滑动需要叠加时间
    if (self.isSliderEnable) {
        CGFloat totalMovieDuration = [self playDuration];
        self.sumTime += value / 10000 * totalMovieDuration;
        
        if (self.sumTime > totalMovieDuration) { self.sumTime = totalMovieDuration;}
        if (self.sumTime < 0) { self.sumTime = 0; }
        
        [self fastViewProgressAvaliable:self.sumTime];
    }
}

- (void)volumeChanged:(NSNotification *)notification
{
    if (self.isDragging)
        return; // 正在拖动，不响应音量事件
    
    if (![[[notification userInfo] objectForKey:@"AVSystemController_AudioVolumeChangeReasonNotificationParameter"] isEqualToString:@"ExplicitVolumeChange"]) {
        return;
    }
    float volume = [[[notification userInfo] objectForKey:@"AVSystemController_AudioVolumeNotificationParameter"] floatValue];
    [self fastViewImageAvaliable:SuperPlayerImage(@"sound_max") progress:volume];
    [self.fastView fadeOut:1];
}

- (SuperPlayerFastView *)fastView
{
    if (_fastView == nil) {
        _fastView = [[SuperPlayerFastView alloc] init];
        [self addSubview:_fastView];
        [_fastView mas_makeConstraints:^(MASConstraintMaker *make) {
            make.edges.mas_equalTo(UIEdgeInsetsZero);
        }];
        _fastView.hidden = !_allowShowFastView;
    }
    return _fastView;
}

- (void)fastViewImageAvaliable:(UIImage *)image progress:(CGFloat)draggedValue {
    if (self.controlView.isShowSecondView)
        return;
    [self.fastView showImg:image withProgress:draggedValue];
    if (self.allowShowFastView) {
        [self.fastView fadeShow];
    }
}

- (void)fastViewProgressAvaliable:(NSInteger)draggedTime
{
    NSInteger totalTime = 0;
    if (self.originalDuration > 0) {
        totalTime = self.originalDuration;
    } else {
        totalTime = [self playDuration];
    }
    NSString *currentTimeStr = [StrUtils timeFormat:draggedTime];
    NSString *totalTimeStr   = [StrUtils timeFormat:totalTime];
    NSString *timeStr        = [NSString stringWithFormat:@"%@ / %@", currentTimeStr, totalTimeStr];
    if (self.isLive) {
        timeStr = [NSString stringWithFormat:@"%@", currentTimeStr];
    }
    
    UIImage *thumbnail;
    if (self.isFullScreen) {
        thumbnail = [self.imageSprite getThumbnail:draggedTime];
    }
    if (thumbnail) {
        self.fastView.videoRatio = self.videoRatio;
        [self.fastView showThumbnail:thumbnail withText:timeStr];
    } else {
        CGFloat sliderValue = 1;
        if (totalTime > 0) {
            sliderValue = (CGFloat)draggedTime/totalTime;
        }
        if (self.isLive && totalTime > MAX_SHIFT_TIME) {
            CGFloat base = totalTime - MAX_SHIFT_TIME;
            if (self.sumTime < base)
                self.sumTime = base;
            sliderValue = (self.sumTime - base) / MAX_SHIFT_TIME;
        }
        [self.fastView showText:timeStr withText:sliderValue];
    }
    if (self.allowShowFastView) {
        [self.fastView fadeShow];
    }
}

- (void)fastViewUnavaliable
{
    [self.fastView fadeOut:0.1];
}

#pragma mark - UIGestureRecognizerDelegate

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch {
    

    if ([gestureRecognizer isKindOfClass:[UIPanGestureRecognizer class]]) {
        if (self.playDidEnd){
            return NO;
        }
    }

    if ([touch.view isKindOfClass:[UISlider class]] || [touch.view.superview isKindOfClass:[UISlider class]]) {
        return NO;
    }
    
    if (SuperPlayerWindowShared.isShowing)
        return NO;

    return YES;
}

#pragma mark - Setter


/**
 *  设置播放的状态
 *
 *  @param state SuperPlayerState
 */
- (void)setState:(SuperPlayerState)state {
        
    _state = state;
    // 控制菊花显示、隐藏
    if (state == StateBuffering) {
        [self.spinner startAnimating];
    } else {
        if (self.isFirstFrameLoaded) {
            [self.spinner stopAnimating];
        } else {
            if (state == StateFailed || state == StateStopped) {
                [self.spinner stopAnimating];
            }
        }
    }
    if (state == StatePlaying) {
        [[NSNotificationCenter defaultCenter] removeObserver:self
                                                        name:@"AVSystemController_SystemVolumeDidChangeNotification"
                                                      object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(volumeChanged:)
                                                     name:@"AVSystemController_SystemVolumeDidChangeNotification"
                                                   object:nil];
        if (self.coverImageView.alpha == 1 && self.isFirstFrameLoaded) {
            [UIView animateWithDuration:0.2 animations:^{
                self.coverImageView.alpha = 0;
            }];
        }
    } else if (state == StateFailed) {
        
    } else if (state == StateStopped) {
        [[NSNotificationCenter defaultCenter] removeObserver:self
                                                        name:@"AVSystemController_SystemVolumeDidChangeNotification"
                                                      object:nil];
        self.coverImageView.alpha = 1;
    } else if (state == StatePause) {

    }
    if ([self.delegate respondsToSelector:@selector(superPlayerDidChange:state:)]) {
        [self.delegate superPlayerDidChange:self state:state];
    }
    if (self.autoEnableIdleTimer) {
        switch (state) {
            case StatePlaying:
            case StateBuffering:
                UIApplication.sharedApplication.idleTimerDisabled = YES;
                break;
            case StateFailed:
            case StateStopped:
            case StatePause:
                UIApplication.sharedApplication.idleTimerDisabled = NO;
                break;
            default:
                break;
        }
    }
}

- (void)setControlView:(SuperPlayerControlView *)controlView {
    if (_controlView == controlView) {
        return;
    }
    [_controlView removeFromSuperview];

    _controlView = controlView;
    controlView.delegate = self;
    [self addSubview:controlView];
    [controlView mas_makeConstraints:^(MASConstraintMaker *make) {
        make.edges.mas_equalTo(UIEdgeInsetsZero);
    }];
    [self resetControlViewWithLive:self.isLive
                     shiftPlayback:self.isShiftPlayback
                         isPlaying:self.autoPlay];
    [controlView setTitle:_controlView.title];
    [controlView setPointArray:_controlView.pointArray];
}

- (SuperPlayerControlView *)controlView
{
    if (_controlView == nil) {
        self.controlView = [[SPDefaultControlView alloc] initWithFrame:CGRectZero];
    }
    return _controlView;
}

- (void)setDragging:(BOOL)dragging
{
    _isDragging = dragging;
    if (dragging) {
        [[NSNotificationCenter defaultCenter]
         removeObserver:self name:@"AVSystemController_SystemVolumeDidChangeNotification"
         object:nil];
    } else {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter]
             addObserver:self
             selector:@selector(volumeChanged:)
             name:@"AVSystemController_SystemVolumeDidChangeNotification"
             object:nil];
        });
    }
}

- (void)setLoop:(BOOL)loop
{
    _loop = loop;
    if (self.vodPlayer) {
        self.vodPlayer.loop = loop;
    }
}

#pragma mark - Getter

- (CGFloat)playDuration {
    if (self.isLive) {
        return self.maxLiveProgressTime;
    }
    return self.vodPlayer.duration;
}

- (CGFloat)playCurrentTime {
    if (self.isLive) {
        if (self.isShiftPlayback) {
            return self.liveProgressTime;
        }
        return self.maxLiveProgressTime;
    }
    
    return _playCurrentTime;
}

+ (UISlider *)volumeViewSlider {
    return [VolumeViewManager shared].volumeSlider;
}
#pragma mark - SuperPlayerControlViewDelegate

- (void)controlViewPlay:(SuperPlayerControlView *)controlView
{
    [self resume];
    if (self.state == StatePause) { self.state = StatePlaying; }
}

- (void)controlViewPause:(SuperPlayerControlView *)controlView
{
    [self pause];
    if (self.state == StatePlaying) { self.state = StatePause;}
}

- (void)controlViewBack:(SuperPlayerControlView *)controlView {
    [self controlViewBackAction:controlView];
}

- (void)controlViewBackAction:(id)sender {
    if (self.isFullScreen) {
        self.isFullScreen = NO;
        return;
    }
    if ([self.delegate respondsToSelector:@selector(superPlayerBackAction:)]) {
        [self.delegate superPlayerBackAction:self];
    }
}

- (void)controlViewChangeScreen:(SuperPlayerControlView *)controlView withFullScreen:(BOOL)isFullScreen {
    self.isFullScreen = isFullScreen;
}

- (void)controlViewDidChangeScreen:(UIView *)controlView
{
    if ([self.delegate respondsToSelector:@selector(superPlayerFullScreenChanged:)]) {
        [self.delegate superPlayerFullScreenChanged:self];
    }
}

- (void)controlViewLockScreen:(SuperPlayerControlView *)controlView withLock:(BOOL)isLock {
    self.isLockScreen = isLock;
}

- (void)controlViewSwitch:(SuperPlayerControlView *)controlView withDefinition:(NSString *)definition {
    if ([self.playerModel.playingDefinition isEqualToString:definition])
        return;
    
    self.playerModel.playingDefinition = definition;
    NSString *url = self.playerModel.playingDefinitionUrl;
    if (self.isLive) {
        [self.livePlayer switchStream:url];
        [self showMiddleBtnMsg:[NSString stringWithFormat:@"正在切换到%@...", definition] withAction:ActionNone];
    } else {
        if ([self.vodPlayer supportedBitrates].count > 1) {
            [self.vodPlayer setBitrateIndex:self.playerModel.playingDefinitionIndex];
        } else {
            CGFloat startTime = [self.vodPlayer currentPlaybackTime];
            [self.vodPlayer setStartTime:startTime];
            [self.vodPlayer startPlay:url];
        }
    }
}

- (void)controlViewConfigUpdate:(SuperPlayerView *)controlView withReload:(BOOL)reload {
    if (self.isLive) {
        [self.livePlayer setMute:self.playerConfig.mute];
        [self.livePlayer setRenderMode:self.playerConfig.renderMode];
    } else {
        [self.vodPlayer setRate:self.playerConfig.playRate];
        [self.vodPlayer setMirror:self.playerConfig.mirror];
        [self.vodPlayer setMute:self.playerConfig.mute];
        [self.vodPlayer setRenderMode:self.playerConfig.renderMode];
    }
    if (reload) {
        if (!self.isLive)
            self.startTime = [self.vodPlayer currentPlaybackTime];
        self.isShiftPlayback = NO;
        [self configTXPlayer]; // 软硬解需要重启
    }
}


- (void)controlViewReload:(UIView *)controlView {
    if (self.isLive) {
        self.isShiftPlayback = NO;
        self.isLoaded = NO;
        [self.livePlayer resumeLive];
        [self resetControlViewWithLive:self.isLive
                         shiftPlayback:self.isShiftPlayback
                             isPlaying:YES];
    } else {
        self.startTime = [self.vodPlayer currentPlaybackTime];
        [self configTXPlayer];
    }
}

- (void)controlViewSnapshot:(SuperPlayerControlView *)controlView {
    
    void (^block)(UIImage *img) = ^(UIImage *img) {
        [self.fastView showSnapshot:img];
        
        if ([self.fastView.snapshotView gestureRecognizers].count == 0) {
            UITapGestureRecognizer *singleTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(openPhotos)];
            singleTap.numberOfTapsRequired = 1;
            [self.fastView.snapshotView setUserInteractionEnabled:YES];
            [self.fastView.snapshotView addGestureRecognizer:singleTap];
        }
        if (self.allowShowFastView) {
            [self.fastView fadeShow];
            [self.fastView fadeOut:2];
        }
        UIImageWriteToSavedPhotosAlbum(img, nil, nil, nil);
    };
    
    if (_isLive) {
        [_livePlayer snapshot:block];
    } else {
        [_vodPlayer snapshot:block];
    }
}

- (void)setDisableGesture:(BOOL)disableGesture {
    for(UIGestureRecognizer *gesture in self.gestureRecognizers) {
        gesture.enabled = !disableGesture;
    }
}
-(void)openPhotos {
    [[UIApplication sharedApplication] openURL:[NSURL URLWithString:@"photos-redirect://"]];
}

- (CGFloat)sliderPosToTime:(CGFloat)pos
{
    // 视频总时间长度
    CGFloat totalTime = 0;
    if (self.originalDuration > 0) {
        totalTime = self.originalDuration;
    } else {
        totalTime = [self playDuration];
    }

    //计算出拖动的当前秒数
    CGFloat dragedSeconds = floorf(totalTime * pos);
    if (self.isLive && totalTime > MAX_SHIFT_TIME) {
        CGFloat base = totalTime - MAX_SHIFT_TIME;
        dragedSeconds = floor(MAX_SHIFT_TIME * pos) + base;
    }
    return dragedSeconds;
}

- (void)controlViewSeek:(SuperPlayerControlView *)controlView where:(CGFloat)pos {
    CGFloat dragedSeconds = [self sliderPosToTime:pos];
    [self seekToTime:dragedSeconds];
    [self fastViewUnavaliable];
}

- (void)controlViewPreview:(SuperPlayerControlView *)controlView where:(CGFloat)pos {
    CGFloat dragedSeconds = [self sliderPosToTime:pos];
    if ([self playDuration] > 0) { // 当总时长 > 0时候才能拖动slider
        [self fastViewProgressAvaliable:dragedSeconds];
    }
}

#pragma clang diagnostic pop
#pragma mark - 点播回调

- (void)_removeOldPlayer
{
    for (UIView *w in [self subviews]) {
        if ([w isKindOfClass:NSClassFromString(@"TXCRenderView")])
            [w removeFromSuperview];
        if ([w isKindOfClass:NSClassFromString(@"TXIJKSDLGLView")])
            [w removeFromSuperview];
        if ([w isKindOfClass:NSClassFromString(@"TXCAVPlayerView")])
            [w removeFromSuperview];
    }
}
/*
- (NSString *)_getResolutionName:(long)minEdge {
    for (NSInteger i = 0; i < self.resolutions.count; ++ i) {
        SPResolutionDefination *resDef = self.resolutions[i];
        if (minEdge <= resDef.minEdge) {
            return resDef.name;
        }
    }
    return self.resolutions.lastObject.name;
}

- (NSArray<SuperPlayerUrl *>*)_getHLSDefinations:(NSArray<TXBitrateItem *> *)supportedBitrates {
    NSMutableArray *definations = [NSMutableArray arrayWithCapacity:3];
    [supportedBitrates enumerateObjectsUsingBlock:^(TXBitrateItem * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
        SuperPlayerUrl *url = [[SuperPlayerUrl alloc] init];
        url.title = [self _getResolutionName:MIN(obj.width, obj.height)];
        [definations addObject:url];
    }];
    return definations;
}
*/

-(void) onPlayEvent:(TXVodPlayer *)player event:(int)EvtID withParam:(NSDictionary*)param
{
    dispatch_async(dispatch_get_main_queue(), ^{
#if DEBUG
        if (EvtID != PLAY_EVT_PLAY_PROGRESS) {
            NSString *desc = [param description];
            NSLog(@"%@", [NSString stringWithCString:[desc cStringUsingEncoding:NSUTF8StringEncoding] encoding:NSNonLossyASCIIStringEncoding]);
        }
#endif

        float duration = 0;
        if (self.originalDuration > 0) {
            duration = self.originalDuration;
        } else {
            duration = player.duration;
        }

        if (EvtID == PLAY_EVT_PLAY_BEGIN || EvtID == PLAY_EVT_RCV_FIRST_I_FRAME) {
            if (EvtID == PLAY_EVT_RCV_FIRST_I_FRAME) {
                self.isFirstFrameLoaded = YES;
            }
            [self setNeedsLayout];
            [self layoutIfNeeded];
            self.isLoaded = YES;
            [self _removeOldPlayer];
            [self.vodPlayer setupVideoWidget:self insertIndex:0];
            [self layoutSubviews];  // 防止横屏状态下添加view显示不全
            self.state = StatePlaying;

//            if (self.playerModel.playDefinitions.count == 0) {
                [self updateBitrates:player.supportedBitrates];
//            }
            for (SPVideoFrameDescription *p in self.keyFrameDescList) {
                if (player.duration > 0)
                    p.where = p.time/duration;
            }
            self.controlView.pointArray = self.keyFrameDescList;
            
            // 不使用vodPlayer.autoPlay的原因是暂停的时候会黑屏，影响体验
            if (!self.autoPlay) {
                self.autoPlay = YES; // 下次用户设置自动播放失效
                [self pause];
            }
            
            if (self.originalDuration > 0) {
                // 当前是试看
                self.controlView.maxPlayableRatio = player.duration / self.originalDuration;
            }
        }
        if (EvtID == PLAY_EVT_VOD_PLAY_PREPARED) {
            // 防止暂停导致加载进度不消失
            if (self.isPauseByUser)
                [self.spinner stopAnimating];
            
            if ([self.delegate respondsToSelector:@selector(superPlayerDidStart:)]) {
                [self.delegate superPlayerDidStart:self];
            }
        }
        if (EvtID == PLAY_EVT_PLAY_PROGRESS) {
            if (self.state == StateStopped)
                return;

            self.playCurrentTime  = player.currentPlaybackTime;
            CGFloat totalTime     = duration;
            CGFloat value         = player.currentPlaybackTime / duration;

            [self.controlView setProgressTime:self.playCurrentTime
                                    totalTime:totalTime
                                progressValue:value
                                playableValue:player.playableDuration / duration];
        } else if (EvtID == PLAY_EVT_PLAY_END) {
            [self.controlView setProgressTime:[self playDuration]
                                    totalTime:[self playDuration]
                                progressValue:player.duration/duration
                                playableValue:player.duration/duration];
            [self moviePlayDidEnd];
        } else if (EvtID == PLAY_ERR_NET_DISCONNECT || EvtID == PLAY_ERR_FILE_NOT_FOUND || EvtID == PLAY_ERR_HLS_KEY /*|| EvtID == PLAY_ERR_VOD_LOAD_LICENSE_FAIL*/) {
            
            if (EvtID == PLAY_ERR_NET_DISCONNECT) {
                [self showMiddleBtnMsg:kStrBadNetRetry withAction:ActionContinueReplay];
            } else {
                [self showMiddleBtnMsg:kStrLoadFaildRetry withAction:ActionRetry];
            }
            self.state = StateFailed;
            [player stopPlay];
            if ([self.delegate respondsToSelector:@selector(superPlayerError:errCode:errMessage:)]) {
                [self.delegate superPlayerError:self errCode:EvtID errMessage:param[EVT_MSG]];
            }
        } else if (EvtID == PLAY_EVT_PLAY_LOADING){
            // 当缓冲是空的时候
            self.state = StateBuffering;
        } else if (EvtID == PLAY_EVT_VOD_LOADING_END) {
            [self.spinner stopAnimating];
        } else if (EvtID == PLAY_EVT_CHANGE_RESOLUTION) {
            if (player.height != 0) {
                self.videoRatio = (GLfloat)player.width / player.height;
                if ([self.delegate respondsToSelector:@selector(superPlayer:videoRatioDidChange:)]) {
                    [self.delegate superPlayer:self videoRatioDidChange:self.videoRatio];
                }
            }
        }
     });
}

// 更新当前播放的视频信息，包括清晰度、码率等
- (void)updateBitrates:(NSArray<TXBitrateItem *> *)bitrates;
{
    if (bitrates.count > 0) {
        if (self.resolutions) {
            if (_playerModel.multiVideoURLs == nil) {
                NSMutableArray *urlDefs = [[NSMutableArray alloc] initWithCapacity:self.resolutions.count];
                for (SPSubStreamInfo *info in self.resolutions) {
                    SuperPlayerUrl *url = [[SuperPlayerUrl alloc] init];
                    url.title = info.resolutionName;
                    [urlDefs addObject:url];
                }
                _playerModel.playingDefinition = _playerModel.multiVideoURLs.firstObject.title;
            }
        } else {
            NSArray *titles = [TXBitrateItemHelper sortWithBitrate:bitrates];
            _playerModel.multiVideoURLs = titles;
            self.netWatcher.playerModel = _playerModel;
            if (_playerModel.playingDefinition == nil)
                _playerModel.playingDefinition = self.netWatcher.adviseDefinition;
        }
        [self resetControlViewWithLive:self.isLive
                         shiftPlayback:self.isShiftPlayback
                             isPlaying:self.autoPlay];
        [self.vodPlayer setBitrateIndex:_playerModel.playingDefinitionIndex];

    }
}


#pragma mark - 直播回调

- (void)onPlayEvent:(int)EvtID withParam:(NSDictionary *)param {
    NSDictionary* dict = param;
    
    dispatch_async(dispatch_get_main_queue(), ^{
#if DEBUG
        if (EvtID != PLAY_EVT_PLAY_PROGRESS) {
            NSString *desc = [param description];
            NSLog(@"%@", [NSString stringWithCString:[desc cStringUsingEncoding:NSUTF8StringEncoding] encoding:NSNonLossyASCIIStringEncoding]);
        }
#endif
        if (EvtID == PLAY_EVT_PLAY_BEGIN || EvtID == PLAY_EVT_RCV_FIRST_I_FRAME) {
            if (EvtID == PLAY_EVT_RCV_FIRST_I_FRAME) {
                self.isFirstFrameLoaded = YES;
            }
            if (!self.isLoaded) {
                [self setNeedsLayout];
                [self layoutIfNeeded];
                self.isLoaded = YES;
                [self _removeOldPlayer];
                [self.livePlayer setupVideoWidget:CGRectZero containView:self insertIndex:0];
                [self layoutSubviews];  // 防止横屏状态下添加view显示不全
                self.state = StatePlaying;
                
                if ([self.delegate respondsToSelector:@selector(superPlayerDidStart:)]) {
                    [self.delegate superPlayerDidStart:self];
                }
               
            } else {
                self.state = StatePlaying;
            }
            
            [self.netWatcher loadingEndEvent];
        } else if (EvtID == PLAY_EVT_PLAY_END) {
            [self moviePlayDidEnd];
        } else if (EvtID == PLAY_ERR_NET_DISCONNECT) {
            if (self.isShiftPlayback) {
                [self controlViewReload:self.controlView];
                [self showMiddleBtnMsg:kStrTimeShiftFailed withAction:ActionRetry];
                [self.middleBlackBtn fadeOut:2];
            } else {
                [self showMiddleBtnMsg:kStrBadNetRetry withAction:ActionRetry];
                self.state = StateFailed;
            }
            if ([self.delegate respondsToSelector:@selector(superPlayerError:errCode:errMessage:)]) {
                [self.delegate superPlayerError:self errCode:EvtID errMessage:param[EVT_MSG]];
            }
        } else if (EvtID == PLAY_EVT_PLAY_LOADING){
            // 当缓冲是空的时候
            self.state = StateBuffering;
            if (!self.isShiftPlayback) {
                [self.netWatcher loadingEvent];
            }
        } else if (EvtID == PLAY_EVT_STREAM_SWITCH_SUCC) {
            [self showMiddleBtnMsg:[@"已切换为" stringByAppendingString:self.playerModel.playingDefinition] withAction:ActionNone];
            [self.middleBlackBtn fadeOut:1];
        } else if (EvtID == PLAY_ERR_STREAM_SWITCH_FAIL) {
            [self showMiddleBtnMsg:kStrHDSwitchFailed withAction:ActionRetry];
            self.state = StateFailed;
        } else if (EvtID == PLAY_EVT_PLAY_PROGRESS) {
            if (self.state == StateStopped)
                return;
            NSInteger progress = [dict[EVT_PLAY_PROGRESS] intValue];
            self.liveProgressTime = progress;
            self.maxLiveProgressTime = MAX(self.maxLiveProgressTime, self.liveProgressTime);
            
            if (self.isShiftPlayback) {
                CGFloat sv = 0;
                if (self.maxLiveProgressTime > MAX_SHIFT_TIME) {
                    CGFloat base = self.maxLiveProgressTime - MAX_SHIFT_TIME;
                    sv = (self.liveProgressTime - base) / MAX_SHIFT_TIME;
                } else {
                    sv = self.liveProgressTime / (self.maxLiveProgressTime + 1);
                }
                [self.controlView setProgressTime:self.liveProgressTime totalTime:-1 progressValue:sv playableValue:0];
            } else {
                [self.controlView setProgressTime:self.maxLiveProgressTime totalTime:-1 progressValue:1 playableValue:0];
            }
        }
    });
}

// 日志回调
-(void) onLog:(NSString*)log LogLevel:(int)level WhichModule:(NSString*)module
{
    if (self.playerConfig.enableLog) {
        NSLog(@"%@:%@", module, log);
    }
}

- (int)livePlayerType {
    int playType = -1;
    NSString *videoURL = self.playerModel.playingDefinitionUrl;
    NSURLComponents *components = [NSURLComponents componentsWithString:videoURL];
    NSString *scheme = [[components scheme] lowercaseString];
    if ([scheme isEqualToString:@"rtmp"]) {
        playType = PLAY_TYPE_LIVE_RTMP;
    } else if ([scheme hasPrefix:@"http"]
               && [[components path].lowercaseString hasSuffix:@".flv"]) {
        playType = PLAY_TYPE_LIVE_FLV;
    }
    return playType;
}

- (void)reportPlay {
    if (self.reportTime == nil)
        return;
    int usedtime = -[self.reportTime timeIntervalSinceNow];
    if (self.isLive) {
        [DataReport report:@"superlive" param:@{@"usedtime":@(usedtime)}];
    } else {
        [DataReport report:@"supervod" param:@{@"usedtime":@(usedtime), @"fileid":@(self.playerModel.videoId.fileId?1:0)}];
    }
    if (self.imageSprite) {
        [DataReport report:@"image_sprite" param:nil];
    }
    self.reportTime = nil;
}

#pragma mark - middle btn

- (UIButton *)middleBlackBtn
{
    if (_middleBlackBtn == nil) {
        _middleBlackBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        [_middleBlackBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        _middleBlackBtn.titleLabel.font = [UIFont systemFontOfSize:14.0];
        _middleBlackBtn.backgroundColor = [UIColor clearColor];
        [_middleBlackBtn addTarget:self action:@selector(middleBlackBtnClick:) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:_middleBlackBtn];
        [_middleBlackBtn mas_makeConstraints:^(MASConstraintMaker *make) {
            make.center.equalTo(self);
            make.height.mas_equalTo(33);
        }];
    }
    return _middleBlackBtn;
}

- (void)showMiddleBtnMsg:(NSString *)msg withAction:(ButtonAction)action {
    [self.middleBlackBtn setTitle:msg forState:UIControlStateNormal];
    self.middleBlackBtn.titleLabel.text = msg;
    self.middleBlackBtnAction = action;
    CGFloat width = self.middleBlackBtn.titleLabel.attributedText.size.width;
    
    [self.middleBlackBtn mas_updateConstraints:^(MASConstraintMaker *make) {
        make.width.equalTo(@(width+10));
    }];
    [self.middleBlackBtn fadeShow];
}

- (void)middleBlackBtnClick:(UIButton *)btn
{
    switch (self.middleBlackBtnAction) {
        case ActionNone:
            break;
        case ActionContinueReplay: {
            if (!self.isLive) {
                self.startTime = self.playCurrentTime;
            }
            [self configTXPlayer];
        }
            break;
        case ActionRetry:
            [self reloadModel];
            break;
        case ActionSwitch:
            [self controlViewSwitch:self.controlView withDefinition:self.netWatcher.adviseDefinition];
            [self resetControlViewWithLive:self.isLive
                             shiftPlayback:self.isShiftPlayback
                                 isPlaying:YES];
            break;
        case ActionIgnore:
            return;
        default:
            break;
    }
    [btn fadeOut:0.2];
}

- (UIButton *)repeatBtn {
    if (!_repeatBtn) {
        _repeatBtn = [UIButton buttonWithType:UIButtonTypeCustom];
        [_repeatBtn setImage:SuperPlayerImage(@"repeat_video") forState:UIControlStateNormal];
        [_repeatBtn addTarget:self action:@selector(repeatBtnClick:) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:_repeatBtn];
        [_repeatBtn mas_makeConstraints:^(MASConstraintMaker *make) {
            make.center.equalTo(self);
        }];
    }
    return _repeatBtn;
}

- (UIButton *)repeatBackBtn {
    if (!_repeatBackBtn) {
        _repeatBackBtn = [UIButton buttonWithType:UIButtonTypeCustom];
        [_repeatBackBtn setImage:SuperPlayerImage(@"back_full") forState:UIControlStateNormal];
        [_repeatBackBtn addTarget:self action:@selector(controlViewBackAction:) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:_repeatBackBtn];
        [_repeatBackBtn mas_makeConstraints:^(MASConstraintMaker *make) {
            make.left.equalTo(self).offset(15);
            make.top.equalTo(self).offset(15);
            make.width.mas_equalTo(@30);
        }];
    }
    return _repeatBackBtn;
}

- (void)repeatBtnClick:(UIButton *)sender {
    [self configTXPlayer];
}

- (MMMaterialDesignSpinner *)spinner {
    if (!_spinner) {
        _spinner = [[MMMaterialDesignSpinner alloc] init];
        _spinner.lineWidth = 1;
        _spinner.duration  = 1;
        _spinner.hidden    = YES;
        _spinner.hidesWhenStopped = YES;
        _spinner.tintColor = [[UIColor whiteColor] colorWithAlphaComponent:0.9];
        [self addSubview:_spinner];
        [_spinner mas_makeConstraints:^(MASConstraintMaker *make) {
            make.center.equalTo(self);
            make.width.with.height.mas_equalTo(45);
        }];
    }
    return _spinner;
}

- (UIImageView *)coverImageView {
    if (!_coverImageView) {
        _coverImageView = [[UIImageView alloc] init];
        _coverImageView.userInteractionEnabled = YES;
        _coverImageView.contentMode = UIViewContentModeScaleAspectFit;
        _coverImageView.alpha = 0;
        [self insertSubview:_coverImageView belowSubview:self.controlView];
        [_coverImageView mas_makeConstraints:^(MASConstraintMaker *make) {
            make.edges.mas_equalTo(UIEdgeInsetsZero);
        }];
    }
    return _coverImageView;
}

@end
