#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

#define DEFAULTS_OVERRIDES_KEY @"AntiCensor_Overrides"
#define DEFAULTS_SERVER_KEY    @"AntiCensor_ServerURL"
#define DEFAULT_SERVER_URL     @"https://spotik-in4b.onrender.com"

@protocol AntiCensorPlayerProtocol <NSObject>
@optional
- (void)setVolume:(float)volume;
- (id)track;
- (NSURL *)URI;
- (double)position;
- (BOOL)isPaused;
- (BOOL)isPlaying;
@end

@interface UIViewController (AntiCensorInternal)
- (void)anticensor_handleLongPress:(UILongPressGestureRecognizer *)gr;
@end

static AVPlayer *ourAudioPlayer = nil;
static BOOL isMutingSpotify = NO;
static float savedSpotifyVolume = 1.0f;
static NSString *currentPlayingURI = nil;

#pragma mark - Helper Functions

static NSString *getServerURL(void) {
    NSString *url = [[NSUserDefaults standardUserDefaults] stringForKey:DEFAULTS_SERVER_KEY];
    if (!url || url.length == 0) {
        return DEFAULT_SERVER_URL;
    }
    return [url stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/"]];
}

static NSDictionary *getOverrides(void) {
    NSDictionary *dict = [[NSUserDefaults standardUserDefaults] dictionaryForKey:DEFAULTS_OVERRIDES_KEY];
    return dict ?: @{};
}

static void saveOverride(NSString *trackURI, NSString *scUrl) {
    if (!trackURI) return;
    NSMutableDictionary *dict = [getOverrides() mutableCopy];
    if (scUrl && scUrl.length > 0) {
        dict[trackURI] = scUrl;
    } else {
        [dict removeObjectForKey:trackURI];
    }
    [[NSUserDefaults standardUserDefaults] setObject:dict forKey:DEFAULTS_OVERRIDES_KEY];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

static NSString *cleanTrackID(NSString *rawUri) {
    if (!rawUri) return nil;
    NSArray *parts = [rawUri componentsSeparatedByString:@"?"];
    return parts.firstObject;
}

#pragma mark - Audio Playback Engine

static void stopReplacementAudio(id<AntiCensorPlayerProtocol> player) {
    if (ourAudioPlayer) {
        [ourAudioPlayer pause];
        ourAudioPlayer = nil;
    }
    if (isMutingSpotify) {
        isMutingSpotify = NO;
        if (player && [player respondsToSelector:@selector(setVolume:)]) {
            [player setVolume:savedSpotifyVolume];
        }
    }
    currentPlayingURI = nil;
}

static void startReplacementAudio(NSString *trackURI, NSString *scUrl, double startPosition, id<AntiCensorPlayerProtocol> spotifyPlayer) {
    if (!scUrl || scUrl.length == 0) return;

    NSString *server = getServerURL();
    NSString *encodedUrl = [scUrl stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
    NSString *streamEndpoint = [NSString stringWithFormat:@"%@/sc?url=%@", server, encodedUrl];
    NSURL *audioUrl = [NSURL URLWithString:streamEndpoint];
    if (!audioUrl) return;

    currentPlayingURI = trackURI;

    // Enable background audio session
    NSError *error = nil;
    [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback withOptions:AVAudioSessionCategoryOptionMixWithOthers error:&error];
    [[AVAudioSession sharedInstance] setActive:YES error:&error];

    if (ourAudioPlayer) {
        [ourAudioPlayer pause];
        ourAudioPlayer = nil;
    }

    AVPlayerItem *item = [AVPlayerItem playerItemWithURL:audioUrl];
    ourAudioPlayer = [AVPlayer playerWithPlayerItem:item];
    ourAudioPlayer.volume = 1.0f;

    if (startPosition > 0) {
        CMTime seekTime = CMTimeMakeWithSeconds(startPosition, NSEC_PER_SEC);
        [ourAudioPlayer seekToTime:seekTime toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero];
    }

    [ourAudioPlayer play];
    isMutingSpotify = YES;

    // Mute Spotify native player
    if (spotifyPlayer && [spotifyPlayer respondsToSelector:@selector(setVolume:)]) {
        [spotifyPlayer setVolume:0.0f];
    }
}

#pragma mark - UI Interaction (Long-press to Replace)

static void showReplacementDialog(NSString *trackURI, NSString *trackTitle, id spotifyPlayer) {
    if (!trackURI) return;

    UIWindow *window = nil;
    for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (scene.activationState == UISceneActivationStateForegroundActive) {
            for (UIWindow *w in scene.windows) {
                if (w.isKeyWindow) { window = w; break; }
            }
        }
        if (window) break;
    }
    if (!window) {
        window = [UIApplication sharedApplication].windows.firstObject;
    }

    UIViewController *topVC = window.rootViewController;
    while (topVC.presentedViewController) {
        topVC = topVC.presentedViewController;
    }

    NSDictionary *overrides = getOverrides();
    NSString *existingUrl = overrides[trackURI] ?: @"";

    NSString *clip = [UIPasteboard generalPasteboard].string;
    NSString *defaultText = existingUrl;
    if ((defaultText.length == 0) && clip && ([clip hasPrefix:@"http://"] || [clip hasPrefix:@"https://"])) {
        defaultText = [clip stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    }

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"AntiCensor"
                                                                   message:[NSString stringWithFormat:@"Замена трека:\n%@", trackTitle ?: trackURI]
                                                            preferredStyle:UIAlertControllerStyleAlert];

    [alert addTextFieldWithConfigurationHandler:^(UITextField * _Nonnull textField) {
        textField.placeholder = @"Вставь ссылку на SoundCloud...";
        textField.text = defaultText;
        textField.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];

    UIAlertAction *saveAction = [UIAlertAction actionWithTitle:@"Сохранить" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        UITextField *tf = alert.textFields.firstObject;
        NSString *inputUrl = [tf.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (inputUrl.length > 0) {
            saveOverride(trackURI, inputUrl);
            startReplacementAudio(trackURI, inputUrl, 0.0, (id<AntiCensorPlayerProtocol>)spotifyPlayer);
        } else {
            saveOverride(trackURI, nil);
            stopReplacementAudio((id<AntiCensorPlayerProtocol>)spotifyPlayer);
        }
    }];

    UIAlertAction *serverAction = [UIAlertAction actionWithTitle:@"Сервер моста" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        UIAlertController *serverAlert = [UIAlertController alertControllerWithTitle:@"URL Моста"
                                                                             message:@"Адрес сервера AntiCensorBridge:"
                                                                      preferredStyle:UIAlertControllerStyleAlert];
        [serverAlert addTextFieldWithConfigurationHandler:^(UITextField * _Nonnull textField) {
            textField.placeholder = DEFAULT_SERVER_URL;
            textField.text = getServerURL();
        }];
        [serverAlert addAction:[UIAlertAction actionWithTitle:@"Сохранить" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull a) {
            NSString *newServer = [serverAlert.textFields.firstObject.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (newServer.length > 0) {
                [[NSUserDefaults standardUserDefaults] setObject:newServer forKey:DEFAULTS_SERVER_KEY];
                [[NSUserDefaults standardUserDefaults] synchronize];
            }
        }]];
        [serverAlert addAction:[UIAlertAction actionWithTitle:@"Отмена" style:UIAlertActionStyleCancel handler:nil]];
        [topVC presentViewController:serverAlert animated:YES completion:nil];
    }];

    UIAlertAction *removeAction = [UIAlertAction actionWithTitle:@"Удалить замену" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
        saveOverride(trackURI, nil);
        stopReplacementAudio((id<AntiCensorPlayerProtocol>)spotifyPlayer);
    }];

    UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:@"Отмена" style:UIAlertActionStyleCancel handler:nil];

    [alert addAction:saveAction];
    if (existingUrl.length > 0) {
        [alert addAction:removeAction];
    }
    [alert addAction:serverAction];
    [alert addAction:cancelAction];

    [topVC presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Method Swizzling

// Hook SPTPlayer state changes
static void (*orig_player_stateDidChange)(id, SEL, id, id);
static void custom_player_stateDidChange(id self, SEL _cmd, id player, id state) {
    if (orig_player_stateDidChange) {
        orig_player_stateDidChange(self, _cmd, player, state);
    }

    if (!state) return;

    id<AntiCensorPlayerProtocol> pState = (id<AntiCensorPlayerProtocol>)state;
    id track = [pState respondsToSelector:@selector(track)] ? [pState track] : nil;
    NSURL *trackURI = track && [track respondsToSelector:@selector(URI)] ? [track URI] : nil;
    NSString *cleanURI = cleanTrackID(trackURI.absoluteString);

    double position = 0.0;
    if ([pState respondsToSelector:@selector(position)]) {
        position = [pState position];
    }

    BOOL isPaused = NO;
    if ([pState respondsToSelector:@selector(isPaused)]) {
        isPaused = [pState isPaused];
    }

    if (!cleanURI) {
        stopReplacementAudio((id<AntiCensorPlayerProtocol>)player);
        return;
    }

    NSDictionary *overrides = getOverrides();
    NSString *repUrl = overrides[cleanURI];

    if (repUrl && repUrl.length > 0) {
        if (![cleanURI isEqualToString:currentPlayingURI] || !ourAudioPlayer) {
            startReplacementAudio(cleanURI, repUrl, position, (id<AntiCensorPlayerProtocol>)player);
        } else {
            // Keep play / pause in sync
            if (isPaused && ourAudioPlayer.timeControlStatus == AVPlayerTimeControlStatusPlaying) {
                [ourAudioPlayer pause];
            } else if (!isPaused && ourAudioPlayer.timeControlStatus == AVPlayerTimeControlStatusPaused) {
                [ourAudioPlayer play];
            }

            // Sync seek / lyrics scrub jumps (> 0.4s)
            double ourPos = CMTimeGetSeconds(ourAudioPlayer.currentTime);
            if (fabs(ourPos - position) > 0.4) {
                CMTime newTime = CMTimeMakeWithSeconds(position, NSEC_PER_SEC);
                [ourAudioPlayer seekToTime:newTime toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero];
            }
        }
    } else {
        if (ourAudioPlayer) {
            stopReplacementAudio((id<AntiCensorPlayerProtocol>)player);
        }
    }
}

static void anticensor_handleLongPress(id self, SEL _cmd, UILongPressGestureRecognizer *gr) {
    if (gr.state == UIGestureRecognizerStateBegan) {
        showReplacementDialog(currentPlayingURI, nil, nil);
    }
}

// Hook NowPlaying viewDidAppear for gesture
static void (*orig_viewDidAppear)(id, SEL, BOOL);
static void custom_viewDidAppear(UIViewController *self, SEL _cmd, BOOL animated) {
    if (orig_viewDidAppear) {
        orig_viewDidAppear(self, _cmd, animated);
    }

    NSString *className = NSStringFromClass([self class]);
    if ([className containsString:@"NowPlaying"]) {
        UIView *view = self.view;
        for (UIGestureRecognizer *gr in view.gestureRecognizers) {
            if ([gr isKindOfClass:[UILongPressGestureRecognizer class]]) {
                return;
            }
        }

        UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(anticensor_handleLongPress:)];
        lp.minimumPressDuration = 0.6;
        [view addGestureRecognizer:lp];
    }
}

#pragma mark - Dynamic Injection Constructor

__attribute__((constructor)) static void initAntiCensor(void) {
    NSLog(@"[AntiCensor] iOS Tweak Loaded!");

    Class npClass = objc_getClass("UIViewController");
    if (npClass) {
        class_addMethod(npClass, @selector(anticensor_handleLongPress:), (IMP)anticensor_handleLongPress, "v@:@");
        Method mApp = class_getInstanceMethod(npClass, @selector(viewDidAppear:));
        if (mApp) {
            orig_viewDidAppear = (void (*)(id, SEL, BOOL))method_getImplementation(mApp);
            method_setImplementation(mApp, (IMP)custom_viewDidAppear);
        }
    }

    Class obsClass = objc_getClass("SPTPlayerObserver");
    if (!obsClass) {
        obsClass = objc_getClass("SPTPlayerImpl");
    }
    if (obsClass) {
        Method mState = class_getInstanceMethod(obsClass, @selector(player:stateDidChange:));
        if (mState) {
            orig_player_stateDidChange = (void (*)(id, SEL, id, id))method_getImplementation(mState);
            method_setImplementation(mState, (IMP)custom_player_stateDidChange);
        }
    }
}
