#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <MediaPlayer/MediaPlayer.h>
#import <objc/runtime.h>
#import <objc/message.h>

#define DEFAULTS_OVERRIDES_KEY     @"AntiCensor_Overrides"
#define DEFAULTS_SERVER_KEY        @"AntiCensor_ServerURL"
#define DEFAULTS_HIDE_FLOAT_KEY    @"AntiCensor_HideFloatingButton"
#define DEFAULT_SERVER_URL         @"https://spotik-in4b.onrender.com"

@protocol AntiCensorPlayerProtocol <NSObject>
@optional
- (void)setVolume:(float)volume;
- (void)setMuted:(BOOL)muted;
- (id)track;
- (id)metadata;
- (NSString *)name;
- (id)URI;
- (double)position;
- (BOOL)isPaused;
- (BOOL)isPlaying;
@end

static AVPlayer *ourAudioPlayer = nil;
static BOOL isMutingSpotify = NO;
static float savedSpotifyVolume = 1.0f;
static NSString *currentPlayingURI = nil;

static NSString *currentActiveSpotifyTrackURI = nil;
static NSString *currentActiveSpotifyTrackTitle = nil;
static NSString *currentActiveSpotifyTrackArtist = nil;
static id currentActiveSpotifyPlayer = nil;

static UIButton *floatingPillButton = nil;

#pragma mark - Helpers

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

static NSString *normalizeKey(NSString *str) {
    if (!str) return @"";
    return [[str lowercaseString] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

static void saveOverride(NSString *trackKey, NSString *scUrl) {
    if (!trackKey || trackKey.length == 0) return;
    NSMutableDictionary *dict = [getOverrides() mutableCopy];
    NSString *normKey = normalizeKey(trackKey);
    if (scUrl && scUrl.length > 0) {
        dict[normKey] = [scUrl stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    } else {
        [dict removeObjectForKey:normKey];
    }
    [[NSUserDefaults standardUserDefaults] setObject:dict forKey:DEFAULTS_OVERRIDES_KEY];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

static NSString *getOverrideForTrack(NSString *uri, NSString *title, NSString *artist) {
    NSDictionary *dict = getOverrides();
    if (uri && uri.length > 0) {
        NSString *val = dict[normalizeKey(uri)];
        if (val) return val;
    }
    if (title && title.length > 0) {
        if (artist && artist.length > 0) {
            NSString *val = dict[normalizeKey([NSString stringWithFormat:@"%@ - %@", artist, title])];
            if (val) return val;
        }
        NSString *val = dict[normalizeKey(title)];
        if (val) return val;
    }
    return nil;
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
        id p = player ?: currentActiveSpotifyPlayer;
        if (p && [p respondsToSelector:@selector(setVolume:)]) {
            [p setVolume:savedSpotifyVolume];
        }
    }
    currentPlayingURI = nil;
}

static void startReplacementAudio(NSString *trackKey, NSString *scUrl, double startPosition, id<AntiCensorPlayerProtocol> spotifyPlayer) {
    if (!scUrl || scUrl.length == 0) return;

    NSString *server = getServerURL();
    NSString *encodedUrl = [scUrl stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
    NSString *streamEndpoint = [NSString stringWithFormat:@"%@/sc?url=%@", server, encodedUrl];
    NSURL *audioUrl = [NSURL URLWithString:streamEndpoint];
    if (!audioUrl) return;

    currentPlayingURI = trackKey;

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

    id p = spotifyPlayer ?: currentActiveSpotifyPlayer;
    if (p && [p respondsToSelector:@selector(setVolume:)]) {
        [p setVolume:0.0f];
    }
}

#pragma mark - Window and Controller Lookup

static UIWindow *getKeyAppWindow(void) {
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]] && scene.activationState == UISceneActivationStateForegroundActive) {
            UIWindowScene *winScene = (UIWindowScene *)scene;
            for (UIWindow *w in winScene.windows) {
                if (w.isKeyWindow) return w;
            }
            if (winScene.windows.count > 0) {
                return winScene.windows.firstObject;
            }
        }
    }
    if ([UIApplication sharedApplication].keyWindow) {
        return [UIApplication sharedApplication].keyWindow;
    }
    if ([UIApplication sharedApplication].windows.count > 0) {
        return [UIApplication sharedApplication].windows.firstObject;
    }
    return nil;
}

static UIViewController *getTopViewController(void) {
    UIWindow *window = getKeyAppWindow();
    UIViewController *topVC = window.rootViewController;
    while (topVC.presentedViewController) {
        topVC = topVC.presentedViewController;
    }
    if ([topVC isKindOfClass:[UINavigationController class]]) {
        topVC = [(UINavigationController *)topVC visibleViewController];
    }
    if ([topVC isKindOfClass:[UITabBarController class]]) {
        topVC = [(UITabBarController *)topVC selectedViewController];
    }
    return topVC;
}

#pragma mark - Replacement Popup Dialog

static void showReplacementDialogWithContext(NSString *targetURI, NSString *targetTitle, NSString *targetArtist) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *topVC = getTopViewController();
        if (!topVC) return;

        NSString *title = targetTitle ?: currentActiveSpotifyTrackTitle;
        NSString *uri = targetURI ?: currentActiveSpotifyTrackURI;
        NSString *artist = targetArtist ?: currentActiveSpotifyTrackArtist;

        NSString *displayTrack = @"Неизвестный трек";
        if (title && title.length > 0) {
            displayTrack = artist ? [NSString stringWithFormat:@"%@ — %@", artist, title] : title;
        } else if (uri && uri.length > 0) {
            displayTrack = uri;
        }

        NSString *existingUrl = getOverrideForTrack(uri, title, artist) ?: @"";
        NSString *clip = [UIPasteboard generalPasteboard].string;
        NSString *defaultText = existingUrl;
        if (defaultText.length == 0 && clip && ([clip hasPrefix:@"http://"] || [clip hasPrefix:@"https://"])) {
            defaultText = [clip stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        }

        NSString *alertMessage = [NSString stringWithFormat:@"Трек: %@\n\nВставь ссылку на песню из SoundCloud:", displayTrack];
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"AntiCensor (Замена на SoundCloud)"
                                                                       message:alertMessage
                                                                preferredStyle:UIAlertControllerStyleAlert];

        [alert addTextFieldWithConfigurationHandler:^(UITextField * _Nonnull textField) {
            textField.placeholder = @"https://soundcloud.com/...";
            textField.text = defaultText;
            textField.clearButtonMode = UITextFieldViewModeWhileEditing;
        }];

        UIAlertAction *saveAction = [UIAlertAction actionWithTitle:@"Сохранить" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
            UITextField *tf = alert.textFields.firstObject;
            NSString *inputUrl = [tf.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (inputUrl.length > 0) {
                if (uri && uri.length > 0) saveOverride(uri, inputUrl);
                if (title && title.length > 0) {
                    saveOverride(title, inputUrl);
                    if (artist && artist.length > 0) {
                        saveOverride([NSString stringWithFormat:@"%@ - %@", artist, title], inputUrl);
                    }
                }
                startReplacementAudio(uri ?: title, inputUrl, 0.0, (id<AntiCensorPlayerProtocol>)currentActiveSpotifyPlayer);
            } else {
                if (uri && uri.length > 0) saveOverride(uri, nil);
                if (title && title.length > 0) {
                    saveOverride(title, nil);
                    if (artist && artist.length > 0) {
                        saveOverride([NSString stringWithFormat:@"%@ - %@", artist, title], nil);
                    }
                }
                stopReplacementAudio((id<AntiCensorPlayerProtocol>)currentActiveSpotifyPlayer);
            }
        }];

        UIAlertAction *serverAction = [UIAlertAction actionWithTitle:@"Сервер моста" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
            UIAlertController *serverAlert = [UIAlertController alertControllerWithTitle:@"Сервер моста"
                                                                                 message:@"Текущий адрес сервера AntiCensor:"
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
            if (uri && uri.length > 0) saveOverride(uri, nil);
            if (title && title.length > 0) {
                saveOverride(title, nil);
                if (artist && artist.length > 0) {
                    saveOverride([NSString stringWithFormat:@"%@ - %@", artist, title], nil);
                }
            }
            stopReplacementAudio((id<AntiCensorPlayerProtocol>)currentActiveSpotifyPlayer);
        }];

        UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:@"Отмена" style:UIAlertActionStyleCancel handler:nil];

        [alert addAction:saveAction];
        if (existingUrl.length > 0) {
            [alert addAction:removeAction];
        }
        [alert addAction:serverAction];
        [alert addAction:cancelAction];

        [topVC presentViewController:alert animated:YES completion:nil];
    });
}

#pragma mark - Extracting Track Info Dynamically

static NSString *extractTrackURIFromObject(id obj, int depth) {
    if (!obj || depth > 3) return nil;
    
    NSArray *selectors = @[@"trackURI", @"entityURI", @"URI", @"uri", @"itemURI", @"targetURI"];
    for (NSString *selName in selectors) {
        SEL sel = NSSelectorFromString(selName);
        if ([obj respondsToSelector:sel]) {
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            id val = [obj performSelector:sel];
            #pragma clang diagnostic pop
            if (val) {
                NSString *str = [val description];
                if ([str containsString:@"spotify:track:"]) {
                    return cleanTrackID(str);
                }
            }
        }
    }

    unsigned int ivarCount = 0;
    Ivar *ivars = class_copyIvarList([obj class], &ivarCount);
    if (ivars) {
        for (unsigned int i = 0; i < ivarCount; i++) {
            const char *ivarName = ivar_getName(ivars[i]);
            NSString *nameStr = [NSString stringWithUTF8String:ivarName];
            if ([nameStr localizedCaseInsensitiveContainsString:@"uri"] ||
                [nameStr localizedCaseInsensitiveContainsString:@"track"] ||
                [nameStr localizedCaseInsensitiveContainsString:@"item"] ||
                [nameStr localizedCaseInsensitiveContainsString:@"entity"]) {
                id val = object_getIvar(obj, ivars[i]);
                if (val) {
                    if ([val isKindOfClass:[NSString class]] || [val isKindOfClass:[NSURL class]]) {
                        NSString *str = [val description];
                        if ([str containsString:@"spotify:track:"]) {
                            free(ivars);
                            return cleanTrackID(str);
                        }
                    } else if ([val isKindOfClass:[NSObject class]] && depth < 2) {
                        NSString *found = extractTrackURIFromObject(val, depth + 1);
                        if (found) {
                            free(ivars);
                            return found;
                        }
                    }
                }
            }
        }
        free(ivars);
    }
    return nil;
}

static void findLabelsInView(UIView *view, NSMutableArray<UILabel *> *outLabels) {
    if ([view isKindOfClass:[UILabel class]]) {
        [outLabels addObject:(UILabel *)view];
    }
    for (UIView *sub in view.subviews) {
        findLabelsInView(sub, outLabels);
    }
}

static void extractTitleAndArtistFromView(UIView *view, NSString **outTitle, NSString **outArtist) {
    NSMutableArray<UILabel *> *labels = [NSMutableArray array];
    findLabelsInView(view, labels);

    NSMutableArray<NSString *> *candidates = [NSMutableArray array];
    for (UILabel *lbl in labels) {
        NSString *txt = [lbl.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (txt.length > 0 && txt.length < 100) {
            if (![txt containsString:@"AntiCensor"] &&
                ![txt containsString:@"SoundCloud"] &&
                ![txt containsString:@"плейлист"] &&
                ![txt containsString:@"очередь"] &&
                ![txt containsString:@"Поделиться"] &&
                ![txt containsString:@"Отмена"] &&
                ![txt containsString:@"Лайк"] &&
                ![txt containsString:@"Cancel"] &&
                ![txt containsString:@"Share"] &&
                ![txt containsString:@"Queue"] &&
                ![txt containsString:@"Playlist"]) {
                if (![candidates containsObject:txt]) {
                    [candidates addObject:txt];
                }
            }
        }
    }

    if (candidates.count >= 2) {
        if (outTitle) *outTitle = candidates[0];
        if (outArtist) *outArtist = candidates[1];
    } else if (candidates.count == 1) {
        if (outTitle) *outTitle = candidates[0];
    }
}

#pragma mark - Context Menu Injection (3-Dots Menu)

static void addAntiCensorButtonToContextMenu(UIViewController *sheetVC) {
    if (!sheetVC || !sheetVC.isViewLoaded) return;
    UIView *container = sheetVC.view;
    if ([container viewWithTag:778899]) return;

    NSString *extractedURI = extractTrackURIFromObject(sheetVC, 0);
    NSString *extractedTitle = nil;
    NSString *extractedArtist = nil;
    extractTitleAndArtistFromView(container, &extractedTitle, &extractedArtist);

    UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
    btn.tag = 778899;
    btn.translatesAutoresizingMaskIntoConstraints = NO;
    btn.backgroundColor = [UIColor colorWithRed:0.11 green:0.73 blue:0.33 alpha:1.0];
    [btn setTitle:@"⚡ Заменить на SoundCloud (AntiCensor)" forState:UIControlStateNormal];
    [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    btn.titleLabel.font = [UIFont boldSystemFontOfSize:14.0f];
    btn.layer.cornerRadius = 22.0f;
    btn.layer.masksToBounds = YES;

    if (extractedURI) objc_setAssociatedObject(btn, "anticensor_uri", extractedURI, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (extractedTitle) objc_setAssociatedObject(btn, "anticensor_title", extractedTitle, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (extractedArtist) objc_setAssociatedObject(btn, "anticensor_artist", extractedArtist, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    [btn addTarget:sheetVC action:@selector(anticensor_onContextMenuButtonTap:) forControlEvents:UIControlEventTouchUpInside];

    [container addSubview:btn];

    [NSLayoutConstraint activateConstraints:@[
        [btn.centerXAnchor constraintEqualToAnchor:container.centerXAnchor],
        [btn.topAnchor constraintEqualToAnchor:container.safeAreaLayoutGuide.topAnchor constant:12.0],
        [btn.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:16.0],
        [btn.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-16.0],
        [btn.heightAnchor constraintEqualToConstant:44.0]
    ]];

    [container bringSubviewToFront:btn];
}

static void anticensor_onContextMenuButtonTap(UIViewController *self, SEL _cmd, UIButton *sender) {
    NSString *uri = objc_getAssociatedObject(sender, "anticensor_uri");
    NSString *title = objc_getAssociatedObject(sender, "anticensor_title");
    NSString *artist = objc_getAssociatedObject(sender, "anticensor_artist");

    [self dismissViewControllerAnimated:YES completion:^{
        showReplacementDialogWithContext(uri, title, artist);
    }];
}

#pragma mark - Method Swizzling

static void (*orig_presentViewController)(id, SEL, UIViewController *, BOOL, void (^)(void));
static void custom_presentViewController(UIViewController *self, SEL _cmd, UIViewController *vcToPresent, BOOL animated, void (^completion)(void)) {
    if ([vcToPresent isKindOfClass:[UIAlertController class]]) {
        UIAlertController *alert = (UIAlertController *)vcToPresent;
        BOOL hasAction = NO;
        for (UIAlertAction *act in alert.actions) {
            if ([act.title containsString:@"AntiCensor"] || [act.title containsString:@"SoundCloud"]) {
                hasAction = YES;
                break;
            }
        }
        if (!hasAction) {
            NSString *uri = extractTrackURIFromObject(alert, 0) ?: currentActiveSpotifyTrackURI;
            NSString *title = nil;
            NSString *artist = nil;
            extractTitleAndArtistFromView(alert.view, &title, &artist);

            UIAlertAction *acAction = [UIAlertAction actionWithTitle:@"⚡ Заменить на SoundCloud (AntiCensor)"
                                                              style:UIAlertActionStyleDefault
                                                            handler:^(UIAlertAction * _Nonnull action) {
                showReplacementDialogWithContext(uri, title, artist);
            }];
            [alert addAction:acAction];
        }
    } else {
        NSString *clsName = NSStringFromClass([vcToPresent class]);
        if ([clsName containsString:@"ContextMenu"] ||
            [clsName containsString:@"Action"] ||
            [clsName containsString:@"Menu"] ||
            [clsName containsString:@"Sheet"] ||
            [clsName containsString:@"Option"] ||
            [clsName containsString:@"Track"]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                addAntiCensorButtonToContextMenu(vcToPresent);
            });
        }
    }

    if (orig_presentViewController) {
        orig_presentViewController(self, _cmd, vcToPresent, animated, completion);
    }
}

static UIMenu * (*orig_menuWithTitle_image_identifier_options_children)(id, SEL, NSString *, UIImage *, UIMenuIdentifier, UIMenuOptions, NSArray *);
static UIMenu * custom_menuWithTitle_image_identifier_options_children(id self, SEL _cmd, NSString *title, UIImage *image, UIMenuIdentifier identifier, UIMenuOptions options, NSArray *children) {
    if (children && children.count > 0) {
        UIAction *action = [UIAction actionWithTitle:@"⚡ Заменить на SoundCloud (AntiCensor)"
                                               image:[UIImage systemImageNamed:@"arrow.triangle.2.circlepath"]
                                          identifier:@"com.anticensor.contextAction"
                                             handler:^(__kindof UIAction * _Nonnull a) {
            showReplacementDialogWithContext(currentActiveSpotifyTrackURI, title ?: currentActiveSpotifyTrackTitle, currentActiveSpotifyTrackArtist);
        }];
        children = [children arrayByAddingObject:action];
    }
    if (orig_menuWithTitle_image_identifier_options_children) {
        return orig_menuWithTitle_image_identifier_options_children(self, _cmd, title, image, identifier, options, children);
    }
    return nil;
}

static void handleTrackPlaybackUpdate(NSString *title, NSString *artist, double position, BOOL isPlaying) {
    if (title && title.length > 0) {
        currentActiveSpotifyTrackTitle = title;
    }
    if (artist && artist.length > 0) {
        currentActiveSpotifyTrackArtist = artist;
    }

    NSString *repUrl = getOverrideForTrack(currentActiveSpotifyTrackURI, currentActiveSpotifyTrackTitle, currentActiveSpotifyTrackArtist);

    if (repUrl && repUrl.length > 0) {
        if (!ourAudioPlayer) {
            startReplacementAudio(currentActiveSpotifyTrackURI ?: currentActiveSpotifyTrackTitle, repUrl, position, (id<AntiCensorPlayerProtocol>)currentActiveSpotifyPlayer);
        } else {
            if (!isPlaying && ourAudioPlayer.timeControlStatus == AVPlayerTimeControlStatusPlaying) {
                [ourAudioPlayer pause];
            }
