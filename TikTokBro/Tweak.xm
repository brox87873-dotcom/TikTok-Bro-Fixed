#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <QuartzCore/QuartzCore.h>
#import <math.h>

static NSString * const TBAllKey = @"TikTokBro.total.all";
static NSString * const TBDayKey = @"TikTokBro.total.day";
static NSString * const TBDateKey = @"TikTokBro.total.date";
static NSString * const TBSeenKey = @"TikTokBro.seen.ids";
static NSString * const TBTargetBundleID = @"com.ss.iphone.ugc.tiktok.lite";

@interface TBPlaybackState : NSObject
@property (nonatomic) double lastPosition;
@property (nonatomic) double watchedSeconds;
@property (nonatomic) CFTimeInterval lastSampleTime;
@property (nonatomic) CFTimeInterval lastSeenTime;
@property (nonatomic) BOOL hasSample;
@property (nonatomic) BOOL disqualified;
@end

@implementation TBPlaybackState
@end

static NSMutableDictionary<NSString *, TBPlaybackState *> *TBProgress;
static NSTimer *TBTimer;
static char TBItemSessionKey;

static NSString *TBToday(void) {
    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.timeZone = NSTimeZone.localTimeZone;
    formatter.dateFormat = @"yyyy-MM-dd";
    return [formatter stringFromDate:[NSDate date]];
}

static void TBEnsureDailyCounter(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSString *today = TBToday();
    if (![[defaults stringForKey:TBDateKey] isEqualToString:today]) {
        [defaults setObject:today forKey:TBDateKey];
        [defaults setInteger:0 forKey:TBDayKey];
    }
}

static NSMutableSet<NSString *> *TBSeenSet(void) {
    NSArray<NSString *> *stored = [NSUserDefaults.standardUserDefaults arrayForKey:TBSeenKey] ?: @[];
    return [NSMutableSet setWithArray:stored];
}

static void TBSaveSeen(NSMutableSet<NSString *> *seen) {
    [NSUserDefaults.standardUserDefaults setObject:seen.allObjects forKey:TBSeenKey];
}

static void TBIncrementCounters(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    TBEnsureDailyCounter();
    [defaults setInteger:[defaults integerForKey:TBAllKey] + 1 forKey:TBAllKey];
    [defaults setInteger:[defaults integerForKey:TBDayKey] + 1 forKey:TBDayKey];
}

// Playback state is scoped to one AVPlayerItem instance, while the media ID
// is stable for URL-backed videos and is used for persistent de-duplication.
static NSString *TBPlaybackIdentity(AVPlayerItem *item) {
    if (!item) return nil;

    NSUUID *uuid = objc_getAssociatedObject(item, &TBItemSessionKey);
    if (!uuid) {
        uuid = [NSUUID UUID];
        objc_setAssociatedObject(item, &TBItemSessionKey, uuid, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return [@"session:" stringByAppendingString:uuid.UUIDString];
}

static NSString *TBMediaIdentity(AVPlayerItem *item) {
    if (!item) return nil;

    AVAsset *asset = item.asset;
    if ([asset isKindOfClass:AVURLAsset.class]) {
        NSString *url = ((AVURLAsset *)asset).URL.absoluteString;
        if (url.length) return url;
    }
    return TBPlaybackIdentity(item);
}

static void TBCountPlayback(AVPlayer *player) {
    if (!player) return;

    AVPlayerItem *item = player.currentItem;
    if (!item) return;

    double duration = CMTimeGetSeconds(item.duration);
    double current = CMTimeGetSeconds(player.currentTime);
    if (!isfinite(duration) || !isfinite(current) || duration <= 0.0 || current < 0.0) return;

    NSString *sessionKey = TBPlaybackIdentity(item);
    NSString *mediaKey = TBMediaIdentity(item);
    if (sessionKey.length == 0 || mediaKey.length == 0) return;

    CFTimeInterval now = CACurrentMediaTime();
    TBPlaybackState *state = TBProgress[sessionKey];
    if (!state) {
        state = [TBPlaybackState new];
        TBProgress[sessionKey] = state;
    }
    state.lastSeenTime = now;

    // Pauses and buffering update the baseline but do not add watched time.
    if (!isfinite(player.rate) || player.rate <= 0.0) {
        // A manual scrub while paused must also invalidate this viewing session.
        if (state.hasSample && fabs(current - state.lastPosition) > 0.75) {
            state.disqualified = YES;
        }
        state.lastPosition = current;
        state.lastSampleTime = now;
        state.hasSample = YES;
        return;
    }

    if (!state.hasSample) {
        state.lastPosition = current;
        state.lastSampleTime = now;
        state.hasSample = YES;
        return;
    }

    double elapsed = now - state.lastSampleTime;
    if (elapsed <= 0.0 || elapsed > 2.5) {
        // Do not misclassify a suspended app or a delayed main run loop as a seek.
        state.lastPosition = current;
        state.lastSampleTime = now;
        return;
    }

    double delta = current - state.lastPosition;
    double expected = elapsed * player.rate;
    double seekTolerance = MAX(1.25, expected * 0.5);

    if (delta < -0.75 || delta > expected + seekTolerance) {
        state.disqualified = YES;
    } else if (delta > 0.0) {
        // Count media-time progress, so playback speed is naturally included.
        state.watchedSeconds += MIN(delta, expected + 0.25);
    }

    state.lastPosition = current;
    state.lastSampleTime = now;

    // Position alone is not enough: the viewer must have actually watched 75%
    // of the media timeline. Opening a video at 80% therefore cannot count it.
    double required = duration * 0.75;
    if (!state.disqualified && current >= required && state.watchedSeconds >= required) {
        NSMutableSet<NSString *> *seen = TBSeenSet();
        if (![seen containsObject:mediaKey]) {
            [seen addObject:mediaKey];
            TBSaveSeen(seen);
            TBIncrementCounters();
        }
        [TBProgress removeObjectForKey:sessionKey];
    }
}

static void TBCollectPlayers(CALayer *layer, NSMutableArray<AVPlayer *> *players) {
    if (!layer) return;

    if ([layer isKindOfClass:AVPlayerLayer.class]) {
        AVPlayer *player = ((AVPlayerLayer *)layer).player;
        if (player && ![players containsObject:player]) [players addObject:player];
    }

    for (CALayer *child in layer.sublayers ?: @[]) {
        TBCollectPlayers(child, players);
    }
}

static NSArray<UIWindow *> *TBWindows(void) {
    UIApplication *application = UIApplication.sharedApplication;
    NSMutableArray<UIWindow *> *windows = [NSMutableArray new];

    for (UIScene *scene in application.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (![windows containsObject:window]) [windows addObject:window];
        }
    }

    // Fallback for unusual hosts that do not expose a UIWindowScene.
    if (windows.count == 0) [windows addObjectsFromArray:application.windows];
    return windows;
}

static void TBShowSettings(UIViewController *viewController) {
    if (!viewController || !viewController.isViewLoaded || !viewController.view.window) return;
    if (viewController.presentedViewController) return;

    TBEnsureDailyCounter();
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSString *message = [NSString stringWithFormat:
        @"Видео за всё время: %ld\nВидео сегодня: %ld\n\nЗасчитывается 75%% фактически просмотренного видео без перемотки. Ускоренное воспроизведение учитывается.",
        (long)[defaults integerForKey:TBAllKey],
        (long)[defaults integerForKey:TBDayKey]];

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"TikTok Bro"
        message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Закрыть"
        style:UIAlertActionStyleDefault handler:nil]];
    [viewController presentViewController:alert animated:YES completion:nil];
}

static void TBInstallProfileButton(UIViewController *viewController) {
    NSString *className = NSStringFromClass(viewController.class);
    if ([className rangeOfString:@"Profile" options:NSCaseInsensitiveSearch].location == NSNotFound) return;
    if (!viewController.isViewLoaded || !viewController.view.window) return;

    const NSInteger buttonTag = 0x54424;
    if ([viewController.view viewWithTag:buttonTag]) return;

    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.tag = buttonTag;
    CGFloat top = MAX(viewController.view.safeAreaInsets.top, 12.0);
    button.frame = CGRectMake(viewController.view.bounds.size.width - 54.0, top + 8.0, 42.0, 42.0);
    button.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleBottomMargin;
    button.layer.cornerRadius = 21.0;
    button.backgroundColor = [UIColor colorWithWhite:0.12 alpha:0.92];
    [button setTitle:@"TB" forState:UIControlStateNormal];
    [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont boldSystemFontOfSize:14.0];
    [button addTarget:viewController action:@selector(tb_openSettings:) forControlEvents:UIControlEventTouchUpInside];
    [viewController.view addSubview:button];
}

%hook UIViewController
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    TBInstallProfileButton(self);
}

%new
- (void)tb_openSettings:(id)sender {
    TBShowSettings(self);
}
%end

%ctor {
    @autoreleasepool {
        if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:TBTargetBundleID]) return;

        TBProgress = [NSMutableDictionary new];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (TBTimer) return;
            TBTimer = [NSTimer timerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *timer) {
                NSMutableArray<AVPlayer *> *players = [NSMutableArray new];
                for (UIWindow *window in TBWindows()) {
                    TBCollectPlayers(window.layer, players);
                }
                for (AVPlayer *player in players) TBCountPlayback(player);

                // Drop state for videos that have not appeared for two minutes.
                CFTimeInterval cleanupTime = CACurrentMediaTime();
                NSMutableArray<NSString *> *staleKeys = [NSMutableArray new];
                [TBProgress enumerateKeysAndObjectsUsingBlock:^(NSString *key, TBPlaybackState *state, BOOL *stop) {
                    if (cleanupTime - state.lastSeenTime > 120.0) [staleKeys addObject:key];
                }];
                [TBProgress removeObjectsForKeys:staleKeys];
            }];
            [[NSRunLoop mainRunLoop] addTimer:TBTimer forMode:NSRunLoopCommonModes];
        });
    }
}
