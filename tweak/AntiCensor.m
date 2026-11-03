#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach-o/nlist.h>
#import <mach/mach.h>
#import <dlfcn.h>
#import <stdbool.h>

#define DEFAULTS_OVERRIDES_KEY     @"AntiCensor_Overrides"
#define DEFAULTS_SERVER_KEY        @"AntiCensor_ServerURL"
#define DEFAULTS_HIDE_FLOAT_KEY    @"AntiCensor_HideFloatingButton"
#define DEFAULTS_HIDE_BANNER_KEY   @"AntiCensor_HideBanner"
#define DEFAULT_SERVER_URL         @"https://spotik-in4b.onrender.com"

#pragma mark - Fishhook (Mach-O Symbol Rebinding)

struct rebinding {
    const char *name;
    void *replacement;
    void **replaced;
};

struct rebindings_entry {
    struct rebinding *rebindings;
    size_t rebindings_nel;
    struct rebindings_entry *next;
};

static struct rebindings_entry *_rebindings_head;

static int prepend_rebindings(struct rebindings_entry **head, struct rebinding rebindings[], size_t nel) {
    struct rebindings_entry *new_entry = (struct rebindings_entry *)malloc(sizeof(struct rebindings_entry));
    if (!new_entry) return -1;
    new_entry->rebindings = (struct rebinding *)malloc(sizeof(struct rebinding) * nel);
    if (!new_entry->rebindings) {
        free(new_entry);
        return -1;
    }
    memcpy(new_entry->rebindings, rebindings, sizeof(struct rebinding) * nel);
    new_entry->rebindings_nel = nel;
    new_entry->next = *head;
    *head = new_entry;
    return 0;
}

#if __LP64__
typedef struct mach_header_64 mach_header_t;
typedef struct segment_command_64 segment_command_t;
typedef struct section_64 section_t;
typedef struct nlist_64 nlist_t;
#define LC_SEGMENT_ARCH_DEPENDENT LC_SEGMENT_64
#else
typedef struct mach_header mach_header_t;
typedef struct segment_command segment_command_t;
typedef struct section section_t;
typedef struct nlist nlist_t;
#define LC_SEGMENT_ARCH_DEPENDENT LC_SEGMENT
#endif

static void perform_rebinding_with_section(struct rebindings_entry *rebindings,
                                           section_t *section,
                                           intptr_t slide,
                                           nlist_t *symtab,
                                           char *strtab,
                                           uint32_t *indirect_symtab) {
    const bool isDataConst = strcmp(section->segname, "__DATA_CONST") == 0;
    uint32_t *indirect_symbol_indices = indirect_symtab + section->reserved1;
    void **indirect_symbol_bindings = (void **)((uintptr_t)slide + section->addr);
    if (isDataConst) {
        vm_protect(mach_task_self(), (vm_address_t)indirect_symbol_bindings, section->size, false, VM_PROT_READ | VM_PROT_WRITE);
    }
    for (uint32_t i = 0; i < section->size / sizeof(void *); i++) {
        uint32_t symtab_index = indirect_symbol_indices[i];
        if (symtab_index == INDIRECT_SYMBOL_ABS || symtab_index == INDIRECT_SYMBOL_LOCAL ||
            symtab_index == (INDIRECT_SYMBOL_LOCAL | INDIRECT_SYMBOL_ABS)) {
            continue;
        }
        uint32_t strtab_offset = symtab[symtab_index].n_un.n_strx;
        char *symbol_name = strtab + strtab_offset;
        bool symbol_name_longer_than_one = symbol_name[0] && symbol_name[1];
        struct rebindings_entry *cur = rebindings;
        while (cur) {
            for (uint32_t j = 0; j < cur->rebindings_nel; j++) {
                if (symbol_name_longer_than_one && strcmp(&symbol_name[1], cur->rebindings[j].name) == 0) {
                    if (cur->rebindings[j].replaced != NULL &&
                        cur->rebindings[j].replacement != indirect_symbol_bindings[i]) {
                        *(cur->rebindings[j].replaced) = indirect_symbol_bindings[i];
                    }
                    indirect_symbol_bindings[i] = cur->rebindings[j].replacement;
                    goto symbol_found;
                }
            }
            cur = cur->next;
        }
    symbol_found:;
    }
}

static void rebind_symbols_for_image(struct rebindings_entry *rebindings,
                                     const struct mach_header *header,
                                     intptr_t slide) {
    Dl_info info;
    if (dladdr(header, &info) == 0) return;

    segment_command_t *cur_seg_cmd;
    segment_command_t *linkedit_segment = NULL;
    struct symtab_command *symtab_cmd = NULL;
    struct dysymtab_command *dysymtab_cmd = NULL;

    uintptr_t cur = (uintptr_t)header + sizeof(mach_header_t);
    for (uint32_t i = 0; i < header->ncmds; i++, cur += cur_seg_cmd->cmdsize) {
        cur_seg_cmd = (segment_command_t *)cur;
        if (cur_seg_cmd->cmd == LC_SEGMENT_ARCH_DEPENDENT) {
            if (strcmp(cur_seg_cmd->segname, SEG_LINKEDIT) == 0) {
                linkedit_segment = cur_seg_cmd;
            }
        } else if (cur_seg_cmd->cmd == LC_SYMTAB) {
            symtab_cmd = (struct symtab_command *)cur_seg_cmd;
        } else if (cur_seg_cmd->cmd == LC_DYSYMTAB) {
            dysymtab_cmd = (struct dysymtab_command *)cur_seg_cmd;
        }
    }

    if (!symtab_cmd || !dysymtab_cmd || !linkedit_segment || !dysymtab_cmd->nindirectsyms) {
        return;
    }

    uintptr_t linkedit_base = (uintptr_t)slide + linkedit_segment->vmaddr - linkedit_segment->fileoff;
    nlist_t *symtab = (nlist_t *)(linkedit_base + symtab_cmd->symoff);
    char *strtab = (char *)(linkedit_base + symtab_cmd->stroff);
    uint32_t *indirect_symtab = (uint32_t *)(linkedit_base + dysymtab_cmd->indirectsymoff);

    cur = (uintptr_t)header + sizeof(mach_header_t);
    for (uint32_t i = 0; i < header->ncmds; i++, cur += cur_seg_cmd->cmdsize) {
        cur_seg_cmd = (segment_command_t *)cur;
        if (cur_seg_cmd->cmd == LC_SEGMENT_ARCH_DEPENDENT) {
            if (strcmp(cur_seg_cmd->segname, SEG_DATA) != 0 &&
                strcmp(cur_seg_cmd->segname, "__DATA_CONST") != 0) {
                continue;
            }
            for (uint32_t j = 0; j < cur_seg_cmd->nsects; j++) {
                section_t *sect = (section_t *)(cur + sizeof(segment_command_t)) + j;
                if ((sect->flags & SECTION_TYPE) == S_LAZY_SYMBOL_POINTERS ||
                    (sect->flags & SECTION_TYPE) == S_NON_LAZY_SYMBOL_POINTERS) {
                    perform_rebinding_with_section(rebindings, sect, slide, symtab, strtab, indirect_symtab);
                }
            }
        }
    }
}

static void _rebind_symbols_for_image(const struct mach_header *header, intptr_t slide) {
    rebind_symbols_for_image(_rebindings_head, header, slide);
}

static int ac_rebind_symbols(struct rebinding rebindings[], size_t nel) {
    int retval = prepend_rebindings(&_rebindings_head, rebindings, nel);
    if (retval < 0) return retval;
    if (!_rebindings_head->next) {
        _dyld_register_func_for_add_image(_rebind_symbols_for_image);
    } else {
        uint32_t c = _dyld_image_count();
        for (uint32_t i = 0; i < c; i++) {
            _rebind_symbols_for_image(_dyld_get_image_header(i), _dyld_get_image_vmaddr_slide(i));
        }
    }
    return retval;
}

#pragma mark - Safe CoreAudio Muting Engine (Mixer Bus Control ONLY)

static BOOL isMutingSpotify = NO;

static void *g_activeUnits[16];
static int g_activeUnitCount = 0;

static void recordAudioUnit(void *unit) {
    if (!unit) return;
    for (int i = 0; i < g_activeUnitCount; i++) {
        if (g_activeUnits[i] == unit) return;
    }
    if (g_activeUnitCount < 16) {
        g_activeUnits[g_activeUnitCount++] = unit;
    }
}

typedef OSStatus (*AudioUnitSetParameter_t)(void *inUnit, uint32_t inID, uint32_t inScope, uint32_t inElement, float inValue, uint32_t inBufferOffsetInFrames);
static AudioUnitSetParameter_t pAudioUnitSetParameter = NULL;

static void applyMuteStateToAllUnits(void) {
    if (!pAudioUnitSetParameter) {
        pAudioUnitSetParameter = (AudioUnitSetParameter_t)dlsym(RTLD_DEFAULT, "AudioUnitSetParameter");
    }
    if (!pAudioUnitSetParameter) return;

    float vol = isMutingSpotify ? 0.0f : 1.0f;
    for (int i = 0; i < g_activeUnitCount; i++) {
        void *u = g_activeUnits[i];
        if (u) {
            // Мьютим только шины микшера Spotify. Параметр 14 (громкость наушников) не трогаем!
            pAudioUnitSetParameter(u, 0 /* kMultiChannelMixerParam_Volume */, 1 /* Input */, 0 /* Bus 0 */, vol, 0);
            pAudioUnitSetParameter(u, 0, 1 /* Input */, 1 /* Bus 1 */, vol, 0);
            pAudioUnitSetParameter(u, 0, 2 /* Output */, 0, vol, 0);
        }
    }
}

typedef OSStatus (*AudioOutputUnitStart_t)(void *unit);
static AudioOutputUnitStart_t orig_AudioOutputUnitStart = NULL;
static OSStatus custom_AudioOutputUnitStart(void *unit) {
    recordAudioUnit(unit);
    applyMuteStateToAllUnits();
    return orig_AudioOutputUnitStart ? orig_AudioOutputUnitStart(unit) : 0;
}

typedef OSStatus (*AudioUnitInitialize_t)(void *unit);
static AudioUnitInitialize_t orig_AudioUnitInitialize = NULL;
static OSStatus custom_AudioUnitInitialize(void *unit) {
    recordAudioUnit(unit);
    applyMuteStateToAllUnits();
    return orig_AudioUnitInitialize ? orig_AudioUnitInitialize(unit) : 0;
}

#pragma mark - Persistent JSON & UserDefaults Storage

static NSString *getStorageFilePath(void) {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *docDir = paths.firstObject;
    return [docDir stringByAppendingPathComponent:@"AntiCensor_Overrides.json"];
}

static NSMutableDictionary *loadAllOverrides(void) {
    NSString *path = getStorageFilePath();
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (data) {
        NSError *err = nil;
        NSDictionary *dict = [NSJSONSerialization JSONObjectWithData:data options:0 error:&err];
        if (dict && [dict isKindOfClass:[NSDictionary class]]) {
            return [dict mutableCopy];
        }
    }
    NSDictionary *defaultsDict = [[NSUserDefaults standardUserDefaults] dictionaryForKey:DEFAULTS_OVERRIDES_KEY];
    return defaultsDict ? [defaultsDict mutableCopy] : [NSMutableDictionary dictionary];
}

static void persistOverrides(NSDictionary *dict) {
    if (!dict) return;
    NSError *err = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:dict options:NSJSONWritingPrettyPrinted error:&err];
    if (data) {
        [data writeToFile:getStorageFilePath() atomically:YES];
    }
    [[NSUserDefaults standardUserDefaults] setObject:dict forKey:DEFAULTS_OVERRIDES_KEY];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

static NSString *normalizeKey(NSString *str) {
    if (!str) return @"";
    return [[str lowercaseString] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

static NSString *cleanTrackID(NSString *rawUri) {
    if (!rawUri) return nil;
    return [rawUri componentsSeparatedByString:@"?"].firstObject;
}

static void saveOverride(NSString *trackKey, NSString *scUrl) {
    if (!trackKey || trackKey.length == 0) return;
    NSMutableDictionary *dict = loadAllOverrides();
    NSString *normKey = normalizeKey(trackKey);
    if (scUrl && scUrl.length > 0) {
        dict[normKey] = [scUrl stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    } else {
        [dict removeObjectForKey:normKey];
    }
    persistOverrides(dict);
}

static NSString *getOverrideForTrack(NSString *uri, NSString *title, NSString *artist) {
    NSDictionary *dict = loadAllOverrides();
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

static NSString *getServerURL(void) {
    NSString *url = [[NSUserDefaults standardUserDefaults] stringForKey:DEFAULTS_SERVER_KEY];
    if (!url || url.length == 0) {
        return DEFAULT_SERVER_URL;
    }
    return [url stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/"]];
}

#pragma mark - AntiCensor State & Sync Engine

static AVPlayer *ourAudioPlayer = nil;
static id statusObserverContext = &statusObserverContext;
static BOOL isObservingPlayerItem = NO;

static NSString *currentPlayingURI = nil;

static NSString *currentActiveSpotifyTrackURI = nil;
static NSString *currentActiveSpotifyTrackTitle = nil;
static NSString *currentActiveSpotifyTrackArtist = nil;

static double lastKnownSpotifyPosition = 0.0;
static NSTimeInterval lastSpotifyPositionTimestamp = 0.0;
static BOOL isSpotifyCurrentlyPlaying = NO;

static NSTimer *periodicSyncTimer = nil;
static UIButton *floatingPillButton = nil;

static double getCurrentSpotifyPreciseTime(void) {
    if (!isSpotifyCurrentlyPlaying) {
        return lastKnownSpotifyPosition;
    }
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    NSTimeInterval delta = now - lastSpotifyPositionTimestamp;
    if (delta > 0 && delta < 600) {
        return lastKnownSpotifyPosition + delta;
    }
    return lastKnownSpotifyPosition;
}

#pragma mark - KVO Helper Object

@interface AntiCensorPlayerObserver : NSObject
@end

@implementation AntiCensorPlayerObserver

- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary<NSKeyValueChangeKey,id> *)change
                       context:(void *)context {
    if (context == statusObserverContext) {
        AVPlayerItem *item = (AVPlayerItem *)object;
        if (item.status == AVPlayerItemStatusReadyToPlay) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!ourAudioPlayer) return;
                // Мгновенный скачок на текущее время трека Spotify без задержки буферизации
                double targetSeconds = getCurrentSpotifyPreciseTime();
                if (targetSeconds > 0.05) {
                    CMTime seekTime = CMTimeMakeWithSeconds(targetSeconds, NSEC_PER_SEC);
                    [ourAudioPlayer seekToTime:seekTime toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero completionHandler:^(BOOL finished) {
                        if (isSpotifyCurrentlyPlaying && ourAudioPlayer) {
                            [ourAudioPlayer play];
                        }
                    }];
                } else {
                    if (isSpotifyCurrentlyPlaying) {
                        [ourAudioPlayer play];
                    }
                }
            });
        }
    } else {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
    }
}

@end

static AntiCensorPlayerObserver *g_playerObserver = nil;

#pragma mark - Audio Playback Engine

static void stopReplacementAudio(void) {
    if (periodicSyncTimer) {
        [periodicSyncTimer invalidate];
        periodicSyncTimer = nil;
    }

    if (ourAudioPlayer && isObservingPlayerItem) {
        @try {
            [ourAudioPlayer.currentItem removeObserver:g_playerObserver forKeyPath:@"status" context:statusObserverContext];
        } @catch (id ex) {}
        isObservingPlayerItem = NO;
    }

    isMutingSpotify = NO;
    applyMuteStateToAllUnits();

    if (ourAudioPlayer) {
        [ourAudioPlayer pause];
        ourAudioPlayer = nil;
    }
    currentPlayingURI = nil;
}

static void onPeriodicSyncCheck(NSTimer *timer) {
    if (!ourAudioPlayer || !isSpotifyCurrentlyPlaying) return;
    if (ourAudioPlayer.currentItem.status != AVPlayerItemStatusReadyToPlay) return;

    double spotifyTime = getCurrentSpotifyPreciseTime();
    double ourTime = CMTimeGetSeconds(ourAudioPlayer.currentTime);
    double diff = fabs(ourTime - spotifyTime);

    // Если разница больше 0.35 сек (например, нажали на текст песни), перематываем точно
    if (diff > 0.35) {
        CMTime seekTime = CMTimeMakeWithSeconds(spotifyTime, NSEC_PER_SEC);
        [ourAudioPlayer seekToTime:seekTime toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero];
    }

    if (ourAudioPlayer.timeControlStatus != AVPlayerTimeControlStatusPlaying && isSpotifyCurrentlyPlaying) {
        [ourAudioPlayer play];
    }
}

static void startReplacementAudio(NSString *trackKey, NSString *scUrl, double initialPosition) {
    if (!scUrl || scUrl.length == 0) return;

    NSString *server = getServerURL();
    NSString *encodedUrl = [scUrl stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
    NSString *streamEndpoint = [NSString stringWithFormat:@"%@/sc?url=%@", server, encodedUrl];
    NSURL *audioUrl = [NSURL URLWithString:streamEndpoint];
    if (!audioUrl) return;

    stopReplacementAudio();

    currentPlayingURI = trackKey;
    isMutingSpotify = YES;
    applyMuteStateToAllUnits();

    AVAudioSession *session = [AVAudioSession sharedInstance];
    [session setCategory:AVAudioSessionCategoryPlayback withOptions:AVAudioSessionCategoryOptionMixWithOthers error:nil];
    [session setActive:YES error:nil];

    AVPlayerItem *item = [AVPlayerItem playerItemWithURL:audioUrl];
    if (!g_playerObserver) {
        g_playerObserver = [[AntiCensorPlayerObserver alloc] init];
    }
    [item addObserver:g_playerObserver forKeyPath:@"status" options:NSKeyValueObservingOptionNew context:statusObserverContext];
    isObservingPlayerItem = YES;

    ourAudioPlayer = [AVPlayer playerWithPlayerItem:item];
    ourAudioPlayer.volume = 1.0f;

    // Таймер точной синхронизации каждые 250 мс
    periodicSyncTimer = [NSTimer scheduledTimerWithTimeInterval:0.25
                                                         target:[NSBlockOperation blockOperationWithBlock:^{
        dispatch_async(dispatch_get_main_queue(), ^{
            onPeriodicSyncCheck(nil);
        });
    }]
                                                       selector:@selector(main)
                                                       userInfo:nil
                                                        repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:periodicSyncTimer forMode:NSRunLoopCommonModes];
}

#pragma mark - Window & Controller Helpers

static UIWindow *getKeyAppWindow(void) {
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]] && scene.activationState == UISceneActivationStateForegroundActive) {
            UIWindowScene *winScene = (UIWindowScene *)scene;
            for (UIWindow *w in winScene.windows) {
                if (w.isKeyWindow) return w;
            }
            if (winScene.windows.count > 0) return winScene.windows.firstObject;
        }
    }
    return [UIApplication sharedApplication].keyWindow ?: [UIApplication sharedApplication].windows.firstObject;
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

#pragma mark - Settings & Replacement Dialog

static void showManageAllTracksDialog(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *topVC = getTopViewController();
        if (!topVC) return;

        NSDictionary *all = loadAllOverrides();
        if (all.count == 0) {
            UIAlertController *emptyAlert = [UIAlertController alertControllerWithTitle:@"AntiCensor Память"
                                                                                message:@"Сохранённых замен пока нет."
                                                                         preferredStyle:UIAlertControllerStyleAlert];
            [emptyAlert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
            [topVC presentViewController:emptyAlert animated:YES completion:nil];
            return;
        }

        UIAlertController *manageAlert = [UIAlertController alertControllerWithTitle:@"Все замены AntiCensor"
                                                                             message:[NSString stringWithFormat:@"Всего сохранено: %lu треков", (unsigned long)all.count]
                                                                      preferredStyle:UIAlertControllerStyleActionSheet];

        for (NSString *key in all) {
            NSString *rowTitle = [NSString stringWithFormat:@"Удалить: %@", key];
            [manageAlert addAction:[UIAlertAction actionWithTitle:rowTitle style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
                saveOverride(key, nil);
                if ([normalizeKey(currentActiveSpotifyTrackTitle) isEqualToString:key] ||
                    [normalizeKey(currentActiveSpotifyTrackURI) isEqualToString:key]) {
                    stopReplacementAudio();
                }
            }]];
        }

        [manageAlert addAction:[UIAlertAction actionWithTitle:@"Очистить ВСЕ замены" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
            persistOverrides(@{});
            stopReplacementAudio();
        }]];

        [manageAlert addAction:[UIAlertAction actionWithTitle:@"Закрыть" style:UIAlertActionStyleCancel handler:nil]];
        [topVC presentViewController:manageAlert animated:YES completion:nil];
    });
}

static void showReplacementDialogWithContext(NSString *targetURI, NSString *targetTitle, NSString *targetArtist) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *topVC = getTopViewController();
        if (!topVC) return;

        NSString *title = targetTitle ?: currentActiveSpotifyTrackTitle;
        NSString *uri = targetURI ?: currentActiveSpotifyTrackURI;
        NSString *artist = targetArtist ?: currentActiveSpotifyTrackArtist;

        NSString *displayTrack = @"Текущий трек Spotify";
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
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"AntiCensor"
                                                                        message:alertMessage
                                                                 preferredStyle:UIAlertControllerStyleAlert];

        [alert addTextFieldWithConfigurationHandler:^(UITextField * _Nonnull textField) {
            textField.placeholder = @"https://soundcloud.com/...";
            textField.text = defaultText;
            textField.clearButtonMode = UITextFieldViewModeWhileEditing;
        }];

        UIAlertAction *saveAction = [UIAlertAction actionWithTitle:@"Сохранить замену" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
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
                startReplacementAudio(uri ?: title, inputUrl, getCurrentSpotifyPreciseTime());
            } else {
                if (uri && uri.length > 0) saveOverride(uri, nil);
                if (title && title.length > 0) {
                    saveOverride(title, nil);
                    if (artist && artist.length > 0) {
                        saveOverride([NSString stringWithFormat:@"%@ - %@", artist, title], nil);
                    }
                }
                stopReplacementAudio();
            }
        }];

        UIAlertAction *manageAction = [UIAlertAction actionWithTitle:@"Список всех замен треков" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull a) {
            showManageAllTracksDialog();
        }];

        // Скрыть/показать плавающую кнопку
        BOOL isFloatHidden = [[NSUserDefaults standardUserDefaults] boolForKey:DEFAULTS_HIDE_FLOAT_KEY];
        NSString *floatBtnTitle = isFloatHidden ? @"Показать плавающую кнопку (⚡)" : @"Скрыть плавающую кнопку (⚡)";
        UIAlertAction *toggleFloatAction = [UIAlertAction actionWithTitle:floatBtnTitle style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull a) {
            BOOL newHidden = !isFloatHidden;
            [[NSUserDefaults standardUserDefaults] setBool:newHidden forKey:DEFAULTS_HIDE_FLOAT_KEY];
            [[NSUserDefaults standardUserDefaults] synchronize];
            if (floatingPillButton) {
                floatingPillButton.hidden = newHidden;
            }
        }];

        // Скрыть/показать верхнюю плашку
        BOOL isBannerHidden = [[NSUserDefaults standardUserDefaults] boolForKey:DEFAULTS_HIDE_BANNER_KEY];
        NSString *bannerBtnTitle = isBannerHidden ? @"Показать зелёную плашку сверху" : @"Скрыть зелёную плашку сверху";
        UIAlertAction *toggleBannerAction = [UIAlertAction actionWithTitle:bannerBtnTitle style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull a) {
            BOOL newHidden = !isBannerHidden;
            [[NSUserDefaults standardUserDefaults] setBool:newHidden forKey:DEFAULTS_HIDE_BANNER_KEY];
            [[NSUserDefaults standardUserDefaults] synchronize];
        }];

        UIAlertAction *removeAction = [UIAlertAction actionWithTitle:@"Сбросить замену этого трека" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
            if (uri && uri.length > 0) saveOverride(uri, nil);
            if (title && title.length > 0) {
                saveOverride(title, nil);
                if (artist && artist.length > 0) {
                    saveOverride([NSString stringWithFormat:@"%@ - %@", artist, title], nil);
                }
            }
            stopReplacementAudio();
        }];

        UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:@"Отмена" style:UIAlertActionStyleCancel handler:nil];

        [alert addAction:saveAction];
        if (existingUrl.length > 0) [alert addAction:removeAction];
        [alert addAction:manageAction];
        [alert addAction:toggleFloatAction];
        [alert addAction:toggleBannerAction];
        [alert addAction:cancelAction];

        [topVC presentViewController:alert animated:YES completion:nil];
    });
}

#pragma mark - Context Menu (3-Dots Menu) & UI Extraction

static void extractTrackLabels(UIView *view, NSString **outTitle, NSString **outArtist) {
    if (!view) return;
    if ([view isKindOfClass:[UILabel class]]) {
        UILabel *lbl = (UILabel *)view;
        NSString *t = lbl.text;
        if (t && t.length > 1 && ![t containsString:@"⚡"] && ![t containsString:@"AntiCensor"]) {
            if (!*outTitle) {
                *outTitle = t;
            } else if (!*outArtist && ![t isEqualToString:*outTitle]) {
                *outArtist = t;
            }
        }
    }
    for (UIView *sub in view.subviews) {
        extractTrackLabels(sub, outTitle, outArtist);
        if (*outTitle && *outArtist) return;
    }
}

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
            if (val && [[val description] containsString:@"spotify:track:"]) {
                return cleanTrackID([val description]);
            }
        }
    }
    return nil;
}

static void addAntiCensorButtonToContextMenu(UIViewController *sheetVC) {
    if (!sheetVC || !sheetVC.isViewLoaded) return;
    UIView *container = sheetVC.view;
    if ([container viewWithTag:778899]) return;

    NSString *extractedURI = extractTrackURIFromObject(sheetVC, 0);
    NSString *extractedTitle = nil;
    NSString *extractedArtist = nil;
    extractTrackLabels(container, &extractedTitle, &extractedArtist);

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

static void anticensor_onContextMenuButtonTap(UIViewController *callerVC, SEL _cmd, UIButton *sender) {
    NSString *uri = objc_getAssociatedObject(sender, "anticensor_uri");
    NSString *title = objc_getAssociatedObject(sender, "anticensor_title");
    NSString *artist = objc_getAssociatedObject(sender, "anticensor_artist");
    [callerVC dismissViewControllerAnimated:YES completion:^{
        showReplacementDialogWithContext(uri, title, artist);
    }];
}

#pragma mark - Method Swizzling

static void (*orig_presentViewController)(id, SEL, UIViewController *, BOOL, void (^)(void));
static void custom_presentViewController(UIViewController *callerVC, SEL _cmd, UIViewController *vcToPresent, BOOL animated, void (^completion)(void)) {
    if ([vcToPresent isKindOfClass:[UIAlertController class]]) {
        UIAlertController *alert = (UIAlertController *)vcToPresent;
        BOOL hasAction = NO;
        for (UIAlertAction *act in alert.actions) {
            if ([act.title containsString:@"AntiCensor"]) { hasAction = YES; break; }
        }
        if (!hasAction) {
            NSString *uri = extractTrackURIFromObject(alert, 0) ?: currentActiveSpotifyTrackURI;
            [alert addAction:[UIAlertAction actionWithTitle:@"⚡ Заменить на SoundCloud (AntiCensor)"
                                                      style:UIAlertActionStyleDefault
                                                    handler:^(UIAlertAction * _Nonnull a) {
                showReplacementDialogWithContext(uri, nil, nil);
            }]];
        }
    } else {
        NSString *cls = NSStringFromClass([vcToPresent class]);
        // Запрещаем показ плашки на экранах плеера, обложки и текстов песен
        if (![cls containsString:@"NowPlaying"] &&
            ![cls containsString:@"Playback"] &&
            ![cls containsString:@"Lyrics"] &&
            ![cls containsString:@"Player"] &&
            ![cls containsString:@"Contained"] &&
            ([cls containsString:@"ContextMenu"] || [cls containsString:@"Action"] || [cls containsString:@"Sheet"] || [cls containsString:@"Option"])) {
            
            BOOL isBannerHidden = [[NSUserDefaults standardUserDefaults] boolForKey:DEFAULTS_HIDE_BANNER_KEY];
            if (!isBannerHidden) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    addAntiCensorButtonToContextMenu(vcToPresent);
                });
            }
        }
    }

    if (orig_presentViewController) {
        orig_presentViewController(callerVC, _cmd, vcToPresent, animated, completion);
    }
}

static UIMenu * (*orig_menuWithTitle_image_identifier_options_children)(id, SEL, NSString *, UIImage *, UIMenuIdentifier, UIMenuOptions, NSArray *);
static UIMenu * custom_menuWithTitle_image_identifier_options_children(id target, SEL _cmd, NSString *title, UIImage *image, UIMenuIdentifier identifier, UIMenuOptions options, NSArray *children) {
    if (children && children.count > 0) {
        UIAction *action = [UIAction actionWithTitle:@"⚡ Заменить на SoundCloud (AntiCensor)"
                                               image:[UIImage systemImageNamed:@"arrow.triangle.2.circlepath"]
                                          identifier:@"com.anticensor.action"
                                             handler:^(__kindof UIAction * _Nonnull a) {
            showReplacementDialogWithContext(currentActiveSpotifyTrackURI, title ?: currentActiveSpotifyTrackTitle, currentActiveSpotifyTrackArtist);
        }];
        children = [children arrayByAddingObject:action];
    }
    if (orig_menuWithTitle_image_identifier_options_children) {
        return orig_menuWithTitle_image_identifier_options_children(target, _cmd, title, image, identifier, options, children);
    }
    return nil;
}

#pragma mark - Universal Playback & Accurate Sync

static void handleTrackPlaybackUpdate(NSString *title, NSString *artist, double position, BOOL isPlaying, BOOL hasElapsed, BOOL hasRate) {
    if (title && title.length > 0) currentActiveSpotifyTrackTitle = title;
    if (artist && artist.length > 0) currentActiveSpotifyTrackArtist = artist;

    if (hasElapsed) {
        lastKnownSpotifyPosition = position;
        lastSpotifyPositionTimestamp = [NSDate timeIntervalSinceReferenceDate];
    }

    if (hasRate) {
        isSpotifyCurrentlyPlaying = isPlaying;
    }

    NSString *repUrl = getOverrideForTrack(currentActiveSpotifyTrackURI, currentActiveSpotifyTrackTitle, currentActiveSpotifyTrackArtist);

    if (!repUrl || repUrl.length == 0) {
        // Обычный незаменённый трек: размьючиваем Spotify и глушим наш плеер
        if (ourAudioPlayer) {
            stopReplacementAudio();
        }
        return;
    }

    // Заменённый трек на паузе
    if (!isSpotifyCurrentlyPlaying) {
        if (ourAudioPlayer) {
            [ourAudioPlayer pause];
        }
        isMutingSpotify = NO;
        applyMuteStateToAllUnits();
        return;
    }

    // Заменённый трек играет
    isMutingSpotify = YES;
    applyMuteStateToAllUnits();

    if (!ourAudioPlayer) {
        startReplacementAudio(currentActiveSpotifyTrackURI ?: currentActiveSpotifyTrackTitle, repUrl, position);
    } else {
        if (hasElapsed) {
            double ourPos = CMTimeGetSeconds(ourAudioPlayer.currentTime);
            double diff = fabs(ourPos - position);
            if (diff > 0.3) {
                CMTime newTime = CMTimeMakeWithSeconds(position, NSEC_PER_SEC);
                [ourAudioPlayer seekToTime:newTime toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero];
            }
        }
        if (ourAudioPlayer.timeControlStatus != AVPlayerTimeControlStatusPlaying && isSpotifyCurrentlyPlaying) {
            [ourAudioPlayer play];
        }
    }
}

static void (*orig_setNowPlayingInfo)(id, SEL, NSDictionary *);
static void custom_setNowPlayingInfo(id target, SEL _cmd, NSDictionary *info) {
    if (orig_setNowPlayingInfo) orig_setNowPlayingInfo(target, _cmd, info);
    if (!info || ![info isKindOfClass:[NSDictionary class]]) return;

    NSString *title = nil;
    NSString *artist = nil;
    double pos = 0.0;
    BOOL hasElapsed = NO;
    BOOL hasRate = NO;
    BOOL isPlaying = isSpotifyCurrentlyPlaying; // Сохраняем текущее состояние, если rate не передан!

    for (id k in info) {
        NSString *kStr = [k description];
        if ([kStr localizedCaseInsensitiveContainsString:@"title"]) {
            title = [info[k] description];
        } else if ([kStr localizedCaseInsensitiveContainsString:@"artist"]) {
            artist = [info[k] description];
        } else if ([kStr localizedCaseInsensitiveContainsString:@"elapsed"]) {
            pos = [info[k] doubleValue];
            hasElapsed = YES;
        } else if ([kStr localizedCaseInsensitiveContainsString:@"rate"]) {
            isPlaying = ([info[k] floatValue] > 0.01f);
            hasRate = YES;
        }
    }

    handleTrackPlaybackUpdate(title, artist, pos, isPlaying, hasElapsed, hasRate);
}

#pragma mark - Floating Badge

static void anticensor_floatingBadgeTapped(id target, SEL _cmd);
static void anticensor_handleBadgePan(id target, SEL _cmd, UIPanGestureRecognizer *pan);

static void setupFloatingBadge(void) {
    BOOL isHidden = [[NSUserDefaults standardUserDefaults] boolForKey:DEFAULTS_HIDE_FLOAT_KEY];
    if (isHidden) return;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (floatingPillButton) return;
        UIWindow *window = getKeyAppWindow();
        if (!window) return;

        floatingPillButton = [UIButton buttonWithType:UIButtonTypeCustom];
        floatingPillButton.frame = CGRectMake(window.bounds.size.width - 105, 120, 95, 32);
        floatingPillButton.backgroundColor = [UIColor colorWithRed:0.11 green:0.73 blue:0.33 alpha:0.9];
        [floatingPillButton setTitle:@"⚡ AntiCensor" forState:UIControlStateNormal];
        [floatingPillButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        floatingPillButton.titleLabel.font = [UIFont boldSystemFontOfSize:11.0f];
        floatingPillButton.layer.cornerRadius = 16.0f;
        floatingPillButton.layer.masksToBounds = YES;
        floatingPillButton.layer.borderWidth = 1.0f;
        floatingPillButton.layer.borderColor = [UIColor whiteColor].CGColor;

        [floatingPillButton addTarget:window action:@selector(anticensor_floatingBadgeTapped) forControlEvents:UIControlEventTouchUpInside];

        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:window action:@selector(anticensor_handleBadgePan:)];
        [floatingPillButton addGestureRecognizer:pan];

        [window addSubview:floatingPillButton];
        [window bringSubviewToFront:floatingPillButton];
    });
}

static void anticensor_floatingBadgeTapped(id target, SEL _cmd) {
    showReplacementDialogWithContext(currentActiveSpotifyTrackURI, currentActiveSpotifyTrackTitle, currentActiveSpotifyTrackArtist);
}

static void anticensor_handleBadgePan(id target, SEL _cmd, UIPanGestureRecognizer *pan) {
    UIView *badge = pan.view;
    CGPoint translation = [pan translationInView:badge.window];
    badge.center = CGPointMake(badge.center.x + translation.x, badge.center.y + translation.y);
    [pan setTranslation:CGPointMake(0, 0) inView:badge.window];
}

#pragma mark - Dynamic Injection Constructor

__attribute__((constructor)) static void initAntiCensor(void) {
    NSLog(@"[AntiCensor] Initializing AntiCensor iOS Tweak v3.0...");

    // 1. CoreAudio мьютер микшера Spotify
    struct rebinding audioRebind[2];
    audioRebind[0].name = "AudioOutputUnitStart";
    audioRebind[0].replacement = (void *)custom_AudioOutputUnitStart;
    audioRebind[0].replaced = (void **)&orig_AudioOutputUnitStart;

    audioRebind[1].name = "AudioUnitInitialize";
    audioRebind[1].replacement = (void *)custom_AudioUnitInitialize;
    audioRebind[1].replaced = (void **)&orig_AudioUnitInitialize;
    ac_rebind_symbols(audioRebind, 2);

    // 2. Хук контекстного меню
    Class vcClass = objc_getClass("UIViewController");
    if (vcClass) {
        class_addMethod(vcClass, @selector(anticensor_onContextMenuButtonTap:), (IMP)anticensor_onContextMenuButtonTap, "v@:@");
        Method mPresent = class_getInstanceMethod(vcClass, @selector(presentViewController:animated:completion:));
        if (mPresent) {
            orig_presentViewController = (void (*)(id, SEL, UIViewController *, BOOL, void (^)(void)))method_getImplementation(mPresent);
            method_setImplementation(mPresent, (IMP)custom_presentViewController);
        }
    }

    // 3. Хук UIMenu (iOS 14+)
    Class menuClass = objc_getClass("UIMenu");
    if (menuClass) {
        Method mMenu = class_getClassMethod(menuClass, @selector(menuWithTitle:image:identifier:options:children:));
        if (mMenu) {
            orig_menuWithTitle_image_identifier_options_children = (UIMenu * (*)(id, SEL, NSString *, UIImage *, UIMenuIdentifier, UIMenuOptions, NSArray *))method_getImplementation(mMenu);
            method_setImplementation(mMenu, (IMP)custom_menuWithTitle_image_identifier_options_children);
        }
    }

    // 4. Хук MPNowPlayingInfoCenter для синхронизации и перемотки по тексту
    Class npCenterClass = objc_getClass("MPNowPlayingInfoCenter");
    if (npCenterClass) {
        Method mInfo = class_getInstanceMethod(npCenterClass, @selector(setNowPlayingInfo:));
        if (mInfo) {
            orig_setNowPlayingInfo = (void (*)(id, SEL, NSDictionary *))method_getImplementation(mInfo);
            method_setImplementation(mInfo, (IMP)custom_setNowPlayingInfo);
        }
    }

    Class winClass = objc_getClass("UIWindow");
    if (winClass) {
        class_addMethod(winClass, @selector(anticensor_floatingBadgeTapped), (IMP)anticensor_floatingBadgeTapped, "v@:");
        class_addMethod(winClass, @selector(anticensor_handleBadgePan:), (IMP)anticensor_handleBadgePan, "v@:@");
    }

    // 5. Запуск плавающей кнопки ⚡
    setupFloatingBadge();
}
