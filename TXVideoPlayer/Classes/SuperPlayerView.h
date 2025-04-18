#import <UIKit/UIKit.h>
#import "SuperPlayer.h"
#import "SuperPlayerModel.h"
#import "SuperPlayerViewConfig.h"
#import "SPVideoFrameDescription.h"
#import "MMMaterialDesignSpinner.h"

typedef void(^PlayEndAfter)(void);
typedef void(^PlayEndHandler)(PlayEndAfter);

@protocol SuperPlayerGestureDelegate <NSObject>
- (BOOL)superPlayerGestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer;
@end

@class SuperPlayerControlView;
@class SuperPlayerView;
@class TXImageSprite;

/// 播放器的状态
typedef NS_ENUM(NSInteger, SuperPlayerState) {
    StateFailed,     // 播放失败
    StateBuffering,  // 缓冲中
    StatePlaying,    // 播放中
    StateStopped,    // 停止播放
    StatePause,      // 暂停播放
};

@protocol SuperPlayerDelegate <NSObject>
@optional
/// 返回事件
- (void)superPlayerBackAction:(SuperPlayerView *)player;
/// 全屏改变通知
- (void)superPlayerFullScreenChanged:(SuperPlayerView *)player;
/// 播放开始通知
- (void)superPlayerDidStart:(SuperPlayerView *)player;
/// 播放结束通知
- (void)superPlayerDidEnd:(SuperPlayerView *)player;
/// 播放错误通知
- (void)superPlayerError:(SuperPlayerView *)player errCode:(int)code errMessage:(NSString *)why;
// 播放状态通知
- (void)superPlayerDidChange:(SuperPlayerView *)player state:(SuperPlayerState)state;
- (void)superPlayer:(SuperPlayerView *)player videoRatioDidChange:(CGFloat)ratio;
@end



/// 播放器布局样式
typedef NS_ENUM(NSInteger, SuperPlayerLayoutStyle) {
    SuperPlayerLayoutStyleCompact, ///< 精简模式
    SuperPlayerLayoutStyleFullScreen ///< 全屏模式
};

@interface SuperPlayerView : UIView

/** 设置代理 */
@property (nonatomic, weak) id<SuperPlayerDelegate> delegate;

@property (nonatomic, assign) SuperPlayerLayoutStyle layoutStyle;

/// 设置播放器的父view。播放过程中调用可实现播放窗口转移
@property (nonatomic, weak) UIView *fatherView;

/// 播放器的状态
@property (nonatomic, assign) SuperPlayerState state;
/// 是否全屏
@property (nonatomic, assign, setter=setFullScreen:) BOOL isFullScreen;
/// 是否锁定旋转
@property (nonatomic, assign) BOOL isLockScreen;
/// 是否是直播流 // 这是原始的属性，但是播放m3u8流的时候及时是直播流也不能用直播播放器播放，必须用点播播放器放，所以这个属性会误导人的，废弃
@property (readonly) BOOL isLive DEPRECATED_MSG_ATTRIBUTE("这是原始的属性，但是播放m3u8流的时候及时是直播流也不能用直播播放器播放，必须用点播播放器放，所以这个属性会误导人的，废弃");
///// 是否是直播流 基于现有的逻辑这个属性应该也用不到了，直接在子类里控制能否拖拽吧
//@property (assign, nonatomic) BOOL isLiveStream;
/// 超级播放器控制层
@property (nonatomic) SuperPlayerControlView *controlView;
/// 是否允许竖屏手势 (现在把代理放出来应该可以不用这个了)
@property (nonatomic) BOOL disableGesture;
@property (nonatomic, assign) id<SuperPlayerGestureDelegate> gestureDelegate;
/// 是否在手势中
@property (readonly)  BOOL isDragging;
/// 是否加载成功
@property (readonly)  BOOL  isLoaded;
/// 设置封面图片
@property (nonatomic) UIImageView *coverImageView;
/// 重播按钮
@property (nonatomic, strong) UIButton *repeatBtn;
/// 全屏退出
@property (nonatomic, strong) UIButton *repeatBackBtn;
/// 是否允许显示重播按钮
@property (nonatomic, assign) BOOL allowShowRepeatView;
/// 是否自动播放（在playWithModel前设置)
@property BOOL autoPlay;
/// 视频总时长
@property (nonatomic) CGFloat playDuration;
/// 原始视频总时长，主要用于试看场景下显示总时长
@property (nonatomic) NSTimeInterval originalDuration;
/// 视频当前播放时间
@property (nonatomic) CGFloat playCurrentTime;
/// 起始播放时间，用于从上次位置开播
@property CGFloat startTime;
/// 播放的视频Model
@property (readonly) SuperPlayerModel *playerModel;
/// 播放器配置
@property SuperPlayerViewConfig *playerConfig;
/// 循环播放
@property (nonatomic) BOOL loop;
/// 是否替换系统音量
@property (nonatomic) BOOL replaceSystemVolumeView DEPRECATED_MSG_ATTRIBUTE("主动传入VolumeView");
@property (nonatomic, weak) UISlider *volumeSlider;
/**
 * 视频雪碧图
 */
@property TXImageSprite *imageSprite;
/**
 * 打点信息
 */
@property NSArray<SPVideoFrameDescription *> *keyFrameDescList;
/**
 * 播放model
 */
- (void)playWithModel:(SuperPlayerModel *)playerModel;

/**
 * 重置player
 */
- (void)resetPlayer;

/**
 * 播放
 */
- (void)resume;

/**
 * 暂停
 * @warn isLoaded == NO 时暂停无效
 */
- (void)pause;

/**
 *  从xx秒开始播放视频跳转
 *
 *  @param dragedSeconds 视频跳转的秒数
 */
- (void)seekToTime:(NSInteger)dragedSeconds;

/// 是否允许fastView显示
@property (nonatomic, assign) BOOL allowShowFastView;

/// 强行暴露此方法，方便自定义调节音量的方式
- (void)verticalMoved:(CGFloat)value;

/// 允许自动监测屏幕旋转
@property (assign, nonatomic) BOOL allowAutoObserveOrientationChange;

@property (strong, nonatomic) UIPanGestureRecognizer *panGesture;
@property (strong, nonatomic) UIView *fullScreenBlackView;
/// 是否允许拖拽进度
@property (assign, nonatomic, getter=isSliderEnable) BOOL sliderEnable;
- (MMMaterialDesignSpinner *)spinner;
/// 自动控制空闲时间
@property (assign, nonatomic) BOOL autoEnableIdleTimer;
/// 播放完成允许识别单击事件
@property (assign, nonatomic) BOOL allowRecognizeSingleTapWhenPlayEnd;
/// 播放完成后的回调 这里主要是为了辅助实现后贴广告用的
@property (copy, nonatomic) PlayEndHandler playEndHandler;
@end
