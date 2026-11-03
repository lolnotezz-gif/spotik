#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <MediaPlayer/MediaPlayer.h>
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
#define DEFAULTS_VERSION_KEY       @"AntiCensor_Storage_v3_5_Clean"
#define DEFAULTS_VERSION_KEY_36    @"AntiCensor_Storage_v3_6_Restore"
#define DEFAULTS_VERSION_KEY_38    @"AntiCensor_Storage_v3_8_Fixes"
#define DEFAULT_SERVER_URL         @"https://spotik-in4b.onrender.com"
#define SC_CLIENT_ID               @"2yeWkbX88QhTzS3OtZp8cLGaJRrOAWwF"

static void setupFloatingBadge(void);
static void checkAndInjectProfileDrawerButton(void);

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

#pragma mark - 100% Reliable CoreAudio Mixer Interceptor

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
static AudioUnitSetParameter_t orig_AudioUnitSetParameter = NULL;

static void applyMuteStateToAllUnits(void) {
    if (!orig_AudioUnitSetParameter) {
        orig_AudioUnitSetParameter = (AudioUnitSetParameter_t)dlsym(RTLD_DEFAULT, "AudioUnitSetParameter");
    }
    if (!orig_AudioUnitSetParameter) return;

    float vol = isMutingSpotify ? 0.0f : 1.0f;
    for (int i = 0; i < g_activeUnitCount; i++) {
        void *u = g_activeUnits[i];
        if (u) {
            orig_AudioUnitSetParameter(u, 0 /* kMultiChannelMixerParam_Volume */, 1 /* Input */, 0 /* Bus 0 */, vol, 0);
            orig_AudioUnitSetParameter(u, 0, 1 /* Input */, 1 /* Bus 1 */, vol, 0);
            orig_AudioUnitSetParameter(u, 0, 2 /* Output */, 0, vol, 0);
        }
    }
}

static OSStatus custom_AudioUnitSetParameter(void *inUnit, uint32_t inID, uint32_t inScope, uint32_t inElement, float inValue, uint32_t inBufferOffsetInFrames) {
    recordAudioUnit(inUnit);
    if (isMutingSpotify && (inID == 0 /* kMultiChannelMixerParam_Volume */)) {
        inValue = 0.0f; // Принудительный мьют: Spotify не может сам вернуть себе звук!
    }
    return orig_AudioUnitSetParameter ? orig_AudioUnitSetParameter(inUnit, inID, inScope, inElement, inValue, inBufferOffsetInFrames) : 0;
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

#pragma mark - Persistent JSON Storage with Strict Isolation

static NSString *normalizeKey(NSString *str) {
    if (!str || ![str isKindOfClass:[NSString class]]) return @"";
    NSString *clean = [[str lowercaseString] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    // Убираем точки, дефисы и лишние пробелы для точного совпадения
    clean = [clean stringByReplacingOccurrencesOfString:@"…" withString:@""];
    clean = [clean stringByReplacingOccurrencesOfString:@"..." withString:@""];
    return clean;
}

static NSString *getStorageFilePath(void) {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *docDir = paths.firstObject;
    return [docDir stringByAppendingPathComponent:@"AntiCensor_Overrides.json"];
}

static NSString *getLocalAudioDirectoryPath(void) {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *docDir = paths.firstObject;
    NSString *audioDir = [docDir stringByAppendingPathComponent:@"AntiCensor_AudioFiles"];
    [[NSFileManager defaultManager] createDirectoryAtPath:audioDir withIntermediateDirectories:YES attributes:nil error:nil];
    return audioDir;
}

static NSMutableDictionary *loadAllOverrides(void) {
    NSMutableDictionary *cleaned = [NSMutableDictionary dictionary];
    NSString *path = getStorageFilePath();
    NSData *data = [NSData dataWithContentsOfFile:path];
    NSDictionary *rawDict = nil;
    if (data) {
        rawDict = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    }
    if (!rawDict || ![rawDict isKindOfClass:[NSDictionary class]]) {
        rawDict = [[NSUserDefaults standardUserDefaults] dictionaryForKey:DEFAULTS_OVERRIDES_KEY];
    }
    if (rawDict && [rawDict isKindOfClass:[NSDictionary class]]) {
        for (NSString *k in rawDict) {
            if (![k isKindOfClass:[NSString class]]) continue;
            NSString *normK = normalizeKey(k);
            if (normK.length >= 3 &&
                ![normK isEqualToString:@"текущий трек spotify"] &&
                ![normK isEqualToString:@"выбранный трек"] &&
                ![normK isEqualToString:@"текущий трек"] &&
                ![normK isEqualToString:@"spotify:track:"] &&
                ![normK isEqualToString:@"spotify:"]) {
                NSString *val = [rawDict[k] description];
                if (val && val.length > 5 && ([val containsString:@"soundcloud"] || [val containsString:@"http"] || [val containsString:@"local://"] || [val containsString:@"file://"])) {
                    cleaned[normK] = val;
                }
            }
        }
    }
    return cleaned;
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

static NSString *cleanTrackID(NSString *rawUri) {
    if (!rawUri || ![rawUri isKindOfClass:[NSString class]]) return nil;
    return [rawUri componentsSeparatedByString:@"?"].firstObject;
}

static void saveOverride(NSString *trackKey, NSString *scUrl) {
    if (!trackKey) return;
    NSString *normKey = normalizeKey(trackKey);
    if (normKey.length < 3 ||
        [normKey isEqualToString:@"текущий трек spotify"] ||
        [normKey isEqualToString:@"выбранный трек"] ||
        [normKey isEqualToString:@"текущий трек"]) {
        return;
    }

    NSMutableDictionary *dict = loadAllOverrides();
    if (scUrl && scUrl.length > 0) {
        dict[normKey] = [scUrl stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    } else {
        [dict removeObjectForKey:normKey];
    }
    persistOverrides(dict);
}

static NSString *getOverrideForTrack(NSString *uri, NSString *title, NSString *artist) {
    if ((!uri || uri.length < 5) && (!title || title.length < 2)) {
        return nil;
    }

    NSDictionary *dict = loadAllOverrides();
    if (!dict || dict.count == 0) return nil;

    // 1. Поиск по точному Spotify URI (например spotify:track:6wLq5...)
    if (uri && [uri hasPrefix:@"spotify:track:"] && uri.length > 15) {
        NSString *normUri = normalizeKey(uri);
        NSString *val = dict[normUri];
        if (val && val.length > 5) return val;
    }

    // 2. Поиск по «Артист - Название» (гарантирует уникальность трека в альбоме!)
    if (title && title.length > 1 && artist && artist.length > 1) {
        NSString *combined = [NSString stringWithFormat:@"%@ - %@", artist, title];
        NSString *val = dict[normalizeKey(combined)];
        if (val && val.length > 5) return val;

        NSString *combined2 = [NSString stringWithFormat:@"%@ — %@", artist, title];
        NSString *val2 = dict[normalizeKey(combined2)];
        if (val2 && val2.length > 5) return val2;
    }

    // 3. Точное название песни
    if (title && title.length > 2) {
        NSString *normTitle = normalizeKey(title);
        NSString *val = dict[normTitle];
        if (val && val.length > 5) return val;
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

#pragma mark - Direct Stream Cache & Resolution Engine (Zero Cooldown!)

static NSMutableDictionary<NSString *, NSURL *> *g_streamCache = nil;

static void resolveSoundCloudUrl(NSString *rawUrl, void (^completion)(NSURL *streamUrl)) {
    if (!rawUrl || rawUrl.length == 0) {
        completion(nil);
        return;
    }

    if (!g_streamCache) {
        g_streamCache = [NSMutableDictionary dictionary];
    }

    NSURL *cached = g_streamCache[rawUrl];
    if (cached) {
        completion(cached);
        return;
    }

    if ([rawUrl hasPrefix:@"local://"]) {
        NSString *filename = [rawUrl substringFromIndex:@"local://".length];
        NSString *fullPath = [getLocalAudioDirectoryPath() stringByAppendingPathComponent:filename];
        if ([[NSFileManager defaultManager] fileExistsAtPath:fullPath]) {
            NSURL *u = [NSURL fileURLWithPath:fullPath];
            g_streamCache[rawUrl] = u;
            completion(u);
            return;
        }
    }

    if ([rawUrl hasPrefix:@"file://"] || [rawUrl hasPrefix:@"/"]) {
        NSURL *u = [rawUrl hasPrefix:@"file://"] ? [NSURL URLWithString:rawUrl] : [NSURL fileURLWithPath:rawUrl];
        if ([[NSFileManager defaultManager] fileExistsAtPath:u.path]) {
            g_streamCache[rawUrl] = u;
            completion(u);
            return;
        }
    }

    if ([rawUrl hasSuffix:@".mp3"] || [rawUrl hasSuffix:@".m3u8"] || [rawUrl containsString:@"media-streaming.soundcloud.cloud"]) {
        NSURL *u = [NSURL URLWithString:rawUrl];
        g_streamCache[rawUrl] = u;
        completion(u);
        return;
    }

    NSString *server = getServerURL();
    NSString *encoded = [rawUrl stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
    NSURL *renderFallback = [NSURL URLWithString:[NSString stringWithFormat:@"%@/sc?url=%@", server, encoded]];

    void (^doApiResolve)(NSString *) = ^(NSString *canonicalUrl) {
        NSString *clean = [canonicalUrl componentsSeparatedByString:@"?"].firstObject;
        NSString *endpoint = [NSString stringWithFormat:@"https://api-v2.soundcloud.com/resolve?url=%@&client_id=%@",
                              [clean stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]],
                              SC_CLIENT_ID];
        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:endpoint]];
        [req setValue:@"Mozilla/5.0" forHTTPHeaderField:@"User-Agent"];
        [req setTimeoutInterval:3.5];

        [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
            if (!data || err) {
                completion(renderFallback);
                return;
            }
            @try {
                NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                NSArray *trans = json[@"media"][@"transcodings"];
                if (trans && [trans isKindOfClass:[NSArray class]] && trans.count > 0) {
                    NSDictionary *chosen = nil;
                    for (NSDictionary *t in trans) {
                        if ([t[@"format"][@"protocol"] isEqualToString:@"progressive"]) { chosen = t; break; }
                    }
                    if (!chosen) {
                        for (NSDictionary *t in trans) {
                            if ([t[@"url"] containsString:@"aac_160k"]) { chosen = t; break; }
                        }
                    }
                    if (!chosen) chosen = trans.firstObject;

                    NSString *sApi = chosen[@"url"];
                    if (sApi) {
                        NSString *sep = [sApi containsString:@"?"] ? @"&" : @"?";
                        NSString *fullSApi = [NSString stringWithFormat:@"%@%@client_id=%@", sApi, sep, SC_CLIENT_ID];
                        if (json[@"track_authorization"]) {
                            fullSApi = [fullSApi stringByAppendingFormat:@"&track_authorization=%@", json[@"track_authorization"]];
                        }
                        NSMutableURLRequest *req2 = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:fullSApi]];
                        [req2 setValue:@"Mozilla/5.0" forHTTPHeaderField:@"User-Agent"];
                        [req2 setTimeoutInterval:3.5];

                        [[[NSURLSession sharedSession] dataTaskWithRequest:req2 completionHandler:^(NSData *d2, NSURLResponse *r2, NSError *e2) {
                            if (d2 && !e2) {
                                NSDictionary *sJson = [NSJSONSerialization JSONObjectWithData:d2 options:0 error:nil];
                                NSString *media = sJson[@"url"];
                                if (media && media.length > 0) {
                                    NSURL *fastUrl = [NSURL URLWithString:media];
                                    if (fastUrl) {
                                        g_streamCache[rawUrl] = fastUrl;
                                    }
                                    completion(fastUrl);
                                    return;
                                }
                            }
                            completion(renderFallback);
                        }] resume];
                        return;
                    }
                }
            } @catch (id ex) {}
            completion(renderFallback);
        }] resume];
    };

    if ([rawUrl containsString:@"on.soundcloud.com"] || [rawUrl containsString:@"t.co"] || [rawUrl containsString:@"bit.ly"]) {
        NSMutableURLRequest *headReq = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:rawUrl]];
        [headReq setValue:@"Mozilla/5.0" forHTTPHeaderField:@"User-Agent"];
        [headReq setTimeoutInterval:3.0];
        [[[NSURLSession sharedSession] dataTaskWithRequest:headReq completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
            NSString *finalUrl = r.URL.absoluteString ?: rawUrl;
            doApiResolve(finalUrl);
        }] resume];
    } else {
        doApiResolve(rawUrl);
    }
}

#pragma mark - AntiCensor State & Real-Time Sync Engine

static AVPlayer *ourAudioPlayer = nil;
static void *kStatusObserverContext = &kStatusObserverContext;
static BOOL isObservingPlayerItem = NO;

static NSString *currentPlayingKey = nil;
static BOOL isReplacementLoading = NO;

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

// 100% реальное извлечение играющего сейчас трека прямо с экрана Spotify
static void findSpotifyNowPlayingTrackInfo(NSString **outTitle, NSString **outArtist) {
    UIWindow *window = getKeyAppWindow();
    if (!window) return;

    NSMutableArray<UILabel *> *labels = [NSMutableArray array];
    NSMutableArray *queue = [NSMutableArray arrayWithObject:window];
    while (queue.count > 0) {
        UIView *curr = queue.firstObject;
        [queue removeObjectAtIndex:0];
        if ([curr isKindOfClass:[UILabel class]]) {
            UILabel *l = (UILabel *)curr;
            if (l.text.length > 1 && ![l.text containsString:@"⚡"] && ![l.text containsString:@"AntiCensor"]) {
                [labels addObject:l];
            }
        }
        [queue addObjectsFromArray:curr.subviews];
    }

    [labels sortUsingComparator:^NSComparisonResult(UILabel *l1, UILabel *l2) {
        if (l1.font.pointSize > l2.font.pointSize) return NSOrderedAscending;
        if (l1.font.pointSize < l2.font.pointSize) return NSOrderedDescending;
        return NSOrderedSame;
    }];

    if (labels.count > 0 && !*outTitle) {
        *outTitle = labels[0].text;
    }
    if (labels.count > 1 && !*outArtist) {
        *outArtist = labels[1].text;
    }
}

#pragma mark - KVO Helper Object

@interface AntiCensorPlayerObserver : NSObject
@end

@implementation AntiCensorPlayerObserver

- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary *)change
                       context:(void *)context {
    if (context == kStatusObserverContext) {
        AVPlayerItem *item = (AVPlayerItem *)object;
        if (item.status == AVPlayerItemStatusReadyToPlay) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!ourAudioPlayer) return;
                double targetSeconds = getCurrentSpotifyPreciseTime();
                if (targetSeconds > 0.05) {
                    CMTime seekTime = CMTimeMakeWithSeconds(targetSeconds, NSEC_PER_SEC);
                    [ourAudioPlayer seekToTime:seekTime toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero completionHandler:^(BOOL finished) {
                        if (isSpotifyCurrentlyPlaying && ourAudioPlayer) {
                            [ourAudioPlayer play];
                        }
                    }];
                } else {
                    if (isSpotifyCurrentlyPlaying && ourAudioPlayer) {
                        [ourAudioPlayer play];
                    }
                }
            });
        }
    }
}

@end

static AntiCensorPlayerObserver *g_playerObserver = nil;

static void stopReplacementAudio(void) {
    isReplacementLoading = NO;
    currentPlayingKey = nil;

    if (ourAudioPlayer) {
        if (isObservingPlayerItem) {
            @try {
                [ourAudioPlayer.currentItem removeObserver:g_playerObserver forKeyPath:@"status" context:kStatusObserverContext];
            } @catch (id ex) {}
            isObservingPlayerItem = NO;
        }
        [ourAudioPlayer pause];
        ourAudioPlayer = nil;
    }

    isMutingSpotify = NO;
    applyMuteStateToAllUnits(); // Spotify возвращает свой звук на 100%!
}

static void handleTrackPlaybackUpdate(NSString *title, NSString *artist, NSString *trackURI, double position, BOOL isPlaying, BOOL hasElapsed, BOOL hasRate);

static void updateNowPlayingCenter(void) {
    if (!ourAudioPlayer) return;
    MPNowPlayingInfoCenter *center = [MPNowPlayingInfoCenter defaultCenter];
    NSDictionary *curr = center.nowPlayingInfo;
    NSMutableDictionary *info = curr ? [curr mutableCopy] : [NSMutableDictionary dictionary];

    if (currentActiveSpotifyTrackTitle && currentActiveSpotifyTrackTitle.length > 0) {
        info[MPMediaItemPropertyTitle] = currentActiveSpotifyTrackTitle;
    }
    if (currentActiveSpotifyTrackArtist && currentActiveSpotifyTrackArtist.length > 0) {
        info[MPMediaItemPropertyArtist] = currentActiveSpotifyTrackArtist;
    }

    double ourPos = CMTimeGetSeconds(ourAudioPlayer.currentTime);
    if (!isnan(ourPos) && ourPos >= 0) {
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = @(ourPos);
    }

    double ourDur = CMTimeGetSeconds(ourAudioPlayer.currentItem.duration);
    if (!isnan(ourDur) && ourDur > 0) {
        info[MPMediaItemPropertyPlaybackDuration] = @(ourDur);
    }

    float rate = (ourAudioPlayer.timeControlStatus == AVPlayerTimeControlStatusPlaying && isSpotifyCurrentlyPlaying) ? 1.0f : 0.0f;
    info[MPNowPlayingInfoPropertyPlaybackRate] = @(rate);

    center.nowPlayingInfo = info;
}

static void onPeriodicSyncCheck(NSTimer *timer) {
    // 0. Инжектим кнопку в боковое меню профиля только при его открытии, и вычищаем любые фантомные элементы
    checkAndInjectProfileDrawerButton();

    if (!ourAudioPlayer) return;

    NSString *repUrl = getOverrideForTrack(currentActiveSpotifyTrackURI, currentActiveSpotifyTrackTitle, currentActiveSpotifyTrackArtist);
    if (!repUrl || repUrl.length == 0) {
        stopReplacementAudio();
        return;
    }

    if (!isSpotifyCurrentlyPlaying) {
        if (ourAudioPlayer.timeControlStatus == AVPlayerTimeControlStatusPlaying) {
            [ourAudioPlayer pause];
            updateNowPlayingCenter();
        }
        return;
    }

    if (ourAudioPlayer.currentItem.status != AVPlayerItemStatusReadyToPlay) return;

    double spotifyTime = getCurrentSpotifyPreciseTime();
    double ourTime = CMTimeGetSeconds(ourAudioPlayer.currentTime);
    double diff = fabs(ourTime - spotifyTime);

    // Сглаженный порог рассинхрона (1.2 сек), чтобы не было заиканий звука и скачков громкости
    if (diff > 1.2) {
        CMTime seekTime = CMTimeMakeWithSeconds(spotifyTime, NSEC_PER_SEC);
        [ourAudioPlayer seekToTime:seekTime toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero];
    }

    if (ourAudioPlayer.timeControlStatus != AVPlayerTimeControlStatusPlaying && isSpotifyCurrentlyPlaying) {
        [ourAudioPlayer play];
    }

    // Синхронизируем Dynamic Island и экран блокировки
    updateNowPlayingCenter();
}

static void playStreamUrl(NSURL *streamUrl, NSString *trackKey, double initialPosition) {
    if (!streamUrl || ![trackKey isEqualToString:currentPlayingKey]) {
        return;
    }

    isMutingSpotify = YES;
    applyMuteStateToAllUnits(); // Spotify в полном мьюте

    // КРИТИЧНО ДЛЯ DYNAMIC ISLAND И LOCK SCREEN:
    // Ни в коем случае НЕ используем MixWithOthers! MixWithOthers отключает Dynamic Island и Now Playing!
    AVAudioSession *session = [AVAudioSession sharedInstance];
    [session setCategory:AVAudioSessionCategoryPlayback
             withOptions:AVAudioSessionCategoryOptionAllowBluetooth | AVAudioSessionCategoryOptionAllowAirPlay
                   error:nil];
    [session setActive:YES error:nil];

    AVPlayerItem *item = [AVPlayerItem playerItemWithURL:streamUrl];
    if (!g_playerObserver) {
        g_playerObserver = [[AntiCensorPlayerObserver alloc] init];
    }

    // Если играл старый плеер — полностью заменяем item на новый трек
    if (ourAudioPlayer) {
        if (isObservingPlayerItem) {
            @try { [ourAudioPlayer.currentItem removeObserver:g_playerObserver forKeyPath:@"status" context:kStatusObserverContext]; } @catch (id ex) {}
            isObservingPlayerItem = NO;
        }
        [item addObserver:g_playerObserver forKeyPath:@"status" options:NSKeyValueObservingOptionNew context:kStatusObserverContext];
        isObservingPlayerItem = YES;
        [ourAudioPlayer replaceCurrentItemWithPlayerItem:item];
    } else {
        [item addObserver:g_playerObserver forKeyPath:@"status" options:NSKeyValueObservingOptionNew context:kStatusObserverContext];
        isObservingPlayerItem = YES;
        ourAudioPlayer = [AVPlayer playerWithPlayerItem:item];
        ourAudioPlayer.volume = 1.0f;
    }

    if (isSpotifyCurrentlyPlaying) {
        [ourAudioPlayer play];
        updateNowPlayingCenter();
    }
}

static void startReplacementAudio(NSString *trackKey, NSString *scUrl, double initialPosition) {
    if (!scUrl || scUrl.length == 0) return;

    if ([trackKey isEqualToString:currentPlayingKey] && (ourAudioPlayer != nil || isReplacementLoading)) {
        return;
    }

    // 1. СТАРЫЙ ТРЕК ГЛУШИМ СРАЗУ ЖЕ, ЧТОБЫ ОН НЕ НАКЛАДЫВАЛСЯ!
    if (ourAudioPlayer) {
        [ourAudioPlayer pause];
        ourAudioPlayer = nil;
    }

    // 2. SPOTIFY ГЛУШИМ СРАЗУ ЖЕ!
    isMutingSpotify = YES;
    applyMuteStateToAllUnits();

    currentPlayingKey = trackKey;
    isReplacementLoading = YES;

    // Проверяем кэш (0 мс задержки!)
    if (!g_streamCache) {
        g_streamCache = [NSMutableDictionary dictionary];
    }
    NSURL *cached = g_streamCache[scUrl];
    if (cached) {
        isReplacementLoading = NO;
        playStreamUrl(cached, trackKey, initialPosition);
        return;
    }

    // Разрешаем в фоне
    resolveSoundCloudUrl(scUrl, ^(NSURL *streamUrl) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (![trackKey isEqualToString:currentPlayingKey]) {
                return;
            }
            isReplacementLoading = NO;
            if (!streamUrl) {
                stopReplacementAudio();
                return;
            }
            playStreamUrl(streamUrl, trackKey, initialPosition);
        });
    });
}

#pragma mark - Universal Playback & Accurate Sync

static void handleTrackPlaybackUpdate(NSString *title, NSString *artist, NSString *trackURI, double position, BOOL isPlaying, BOOL hasElapsed, BOOL hasRate) {
    if (title && title.length > 0) {
        if (![title isEqualToString:currentActiveSpotifyTrackTitle]) {
            currentActiveSpotifyTrackTitle = title;
            currentActiveSpotifyTrackArtist = artist ?: @"";
            currentActiveSpotifyTrackURI = trackURI;
        }
    }
    if (artist && artist.length > 0) {
        currentActiveSpotifyTrackArtist = artist;
    }
    if (trackURI && trackURI.length > 0) {
        currentActiveSpotifyTrackURI = trackURI;
    }

    if (hasElapsed) {
        lastKnownSpotifyPosition = position;
        lastSpotifyPositionTimestamp = [NSDate timeIntervalSinceReferenceDate];
    }
    if (hasRate) {
        isSpotifyCurrentlyPlaying = isPlaying;
    }

    NSString *repUrl = getOverrideForTrack(currentActiveSpotifyTrackURI, currentActiveSpotifyTrackTitle, currentActiveSpotifyTrackArtist);

    // СТРОГАЯ ИЗОЛЯЦИЯ: Если у трека нет замены — НЕМЕДЛЕННО размьючиваем Spotify и выключаем плеер!
    if (!repUrl || repUrl.length == 0) {
        if (ourAudioPlayer || isMutingSpotify || currentPlayingKey) {
            stopReplacementAudio();
        }
        return;
    }

    // Если Spotify стоит на паузе
    if (!isSpotifyCurrentlyPlaying) {
        if (ourAudioPlayer && ourAudioPlayer.timeControlStatus == AVPlayerTimeControlStatusPlaying) {
            [ourAudioPlayer pause];
            updateNowPlayingCenter();
        }
        // Spotify остаётся заглушенным, пока трек на паузе,
        // чтобы при снятии с паузы не вырывался звук цензурного оригинала!
        return;
    }

    // Заменённый трек должен играть — глушим Spotify моментально!
    isMutingSpotify = YES;
    applyMuteStateToAllUnits();

    NSString *trackKey = currentActiveSpotifyTrackURI ?: currentActiveSpotifyTrackTitle;

    // Если плеер ещё не играет этот трек
    if (!ourAudioPlayer || ![trackKey isEqualToString:currentPlayingKey]) {
        startReplacementAudio(trackKey, repUrl, position);
    } else {
        if (hasElapsed) {
            double ourPos = CMTimeGetSeconds(ourAudioPlayer.currentTime);
            double diff = fabs(ourPos - position);
            if (diff > 1.2) {
                CMTime newTime = CMTimeMakeWithSeconds(position, NSEC_PER_SEC);
                [ourAudioPlayer seekToTime:newTime toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero];
            }
        }
        if (ourAudioPlayer.timeControlStatus != AVPlayerTimeControlStatusPlaying && isSpotifyCurrentlyPlaying) {
            [ourAudioPlayer play];
        }
        updateNowPlayingCenter();
    }
}

static void (*orig_setNowPlayingInfo)(id, SEL, NSDictionary *);
static void custom_setNowPlayingInfo(id target, SEL _cmd, NSDictionary *info) {
    if (orig_setNowPlayingInfo) orig_setNowPlayingInfo(target, _cmd, info);
    if (!info || ![info isKindOfClass:[NSDictionary class]]) return;

    NSString *title = nil;
    NSString *artist = nil;
    NSString *trackURI = nil;
    double pos = 0.0;
    BOOL hasElapsed = NO;
    BOOL hasRate = NO;
    BOOL isPlaying = isSpotifyCurrentlyPlaying;

    for (id k in info) {
        NSString *kStr = [k description];
        NSString *kLower = kStr.lowercaseString;
        if ([kLower containsString:@"title"] && ![kLower containsString:@"album"]) {
            title = [info[k] description];
        } else if ([kLower containsString:@"artist"]) {
            artist = [info[k] description];
        } else if ([kLower containsString:@"externalcontentidentifier"]) {
            trackURI = [info[k] description];
        } else if ([kLower containsString:@"elapsed"]) {
            pos = [info[k] doubleValue];
            hasElapsed = YES;
        } else if ([kLower containsString:@"rate"]) {
            isPlaying = ([info[k] floatValue] > 0.01f);
            hasRate = YES;
        }
    }

    handleTrackPlaybackUpdate(title, artist, trackURI, pos, isPlaying, hasElapsed, hasRate);
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
            NSString *val = all[key];
            NSString *icon = [val hasPrefix:@"local://"] ? @"📁" : @"☁️";
            NSString *rowTitle = [NSString stringWithFormat:@"%@ Удалить: %@", icon, key];
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
            if (g_streamCache) [g_streamCache removeAllObjects];
            stopReplacementAudio();
        }]];

        [manageAlert addAction:[UIAlertAction actionWithTitle:@"Закрыть" style:UIAlertActionStyleCancel handler:nil]];
        [topVC presentViewController:manageAlert animated:YES completion:nil];
    });
}

#pragma mark - Local Audio Document Picker

@interface AntiCensorDocumentPickerDelegate : NSObject <UIDocumentPickerDelegate>
@property (nonatomic, copy) NSString *targetURI;
@property (nonatomic, copy) NSString *targetTitle;
@property (nonatomic, copy) NSString *targetArtist;
@property (nonatomic, copy) NSString *displayTrack;
@end

@implementation AntiCensorDocumentPickerDelegate

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    if (!urls || urls.count == 0) return;
    NSURL *pickedUrl = urls.firstObject;

    BOOL didAccess = NO;
    if ([pickedUrl respondsToSelector:@selector(startAccessingSecurityScopedResource)]) {
        didAccess = [pickedUrl startAccessingSecurityScopedResource];
    }

    NSString *ext = [pickedUrl pathExtension];
    if (!ext || ext.length == 0) ext = @"mp3";

    NSString *audioDir = getLocalAudioDirectoryPath();
    NSString *safeId = [[NSUUID UUID] UUIDString];
    NSString *filename = [NSString stringWithFormat:@"audio_%@.%@", safeId, ext];
    NSString *destPath = [audioDir stringByAppendingPathComponent:filename];

    NSError *copyErr = nil;
    [[NSFileManager defaultManager] removeItemAtPath:destPath error:nil];
    BOOL success = [[NSFileManager defaultManager] copyItemAtURL:pickedUrl toURL:[NSURL fileURLWithPath:destPath] error:&copyErr];

    if (didAccess) {
        [pickedUrl stopAccessingSecurityScopedResource];
    }

    if (!success || copyErr) {
        NSLog(@"[AntiCensor] Failed to copy local audio: %@", copyErr);
        dispatch_async(dispatch_get_main_queue(), ^{
            UIViewController *top = getTopViewController();
            if (top) {
                UIAlertController *err = [UIAlertController alertControllerWithTitle:@"Ошибка"
                                                                             message:@"Не удалось скопировать файл с устройства."
                                                                      preferredStyle:UIAlertControllerStyleAlert];
                [err addAction:[UIAlertAction actionWithTitle:@"ОК" style:UIAlertActionStyleCancel handler:nil]];
                [top presentViewController:err animated:YES completion:nil];
            }
        });
        return;
    }

    NSString *storedUrl = [NSString stringWithFormat:@"local://%@", filename];

    if (self.targetURI && [self.targetURI hasPrefix:@"spotify:track:"] && self.targetURI.length > 15) {
        saveOverride(self.targetURI, storedUrl);
    }
    if (self.displayTrack.length > 1) {
        saveOverride(self.displayTrack, storedUrl);
    }
    if (self.targetTitle && self.targetTitle.length > 1) {
        saveOverride(self.targetTitle, storedUrl);
        if (self.targetArtist && self.targetArtist.length > 1) {
            saveOverride([NSString stringWithFormat:@"%@ - %@", self.targetArtist, self.targetTitle], storedUrl);
        }
    }

    // Мгновенный запуск локального аудиофайла без задержек
    startReplacementAudio(self.targetURI ?: (self.targetTitle ?: self.displayTrack), storedUrl, getCurrentSpotifyPreciseTime());

    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *top = getTopViewController();
        if (top) {
            UIAlertController *succ = [UIAlertController alertControllerWithTitle:@"⚡ AntiCensor"
                                                                          message:@"Аудиофайл успешно сохранён с устройства и подключен к треку!"
                                                                   preferredStyle:UIAlertControllerStyleAlert];
            [succ addAction:[UIAlertAction actionWithTitle:@"Отлично!" style:UIAlertActionStyleDefault handler:nil]];
            [top presentViewController:succ animated:YES completion:nil];
        }
    });
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    NSLog(@"[AntiCensor] Document picker was cancelled.");
}

@end

static AntiCensorDocumentPickerDelegate *g_docPickerDelegate = nil;

static void openLocalAudioPicker(NSString *targetURI, NSString *targetTitle, NSString *targetArtist, NSString *displayTrack) {
    UIViewController *topVC = getTopViewController();
    if (!topVC) return;

    g_docPickerDelegate = [[AntiCensorDocumentPickerDelegate alloc] init];
    g_docPickerDelegate.targetURI = targetURI;
    g_docPickerDelegate.targetTitle = targetTitle;
    g_docPickerDelegate.targetArtist = targetArtist;
    g_docPickerDelegate.displayTrack = displayTrack;

    NSArray *types = @[
        @"public.audio",
        @"public.mp3",
        @"com.apple.m4a-audio",
        @"public.wav",
        @"public.flac",
        @"org.videolan.flac",
        @"public.data",
        @"public.content"
    ];

    #pragma clang diagnostic push
    #pragma clang diagnostic ignored "-Wdeprecated-declarations"
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initWithDocumentTypes:types inMode:UIDocumentPickerModeImport];
    #pragma clang diagnostic pop

    picker.delegate = g_docPickerDelegate;
    picker.allowsMultipleSelection = NO;
    if (@available(iOS 13.0, *)) {
        picker.modalPresentationStyle = UIModalPresentationFormSheet;
    }

    [topVC presentViewController:picker animated:YES completion:nil];
}

static void showReplacementDialogWithContext(NSString *targetURI, NSString *targetTitle, NSString *targetArtist) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *topVC = getTopViewController();
        if (!topVC) return;

        NSString *title = (targetTitle && targetTitle.length > 0) ? targetTitle : currentActiveSpotifyTrackTitle;
        NSString *uri = (targetURI && targetURI.length > 0) ? targetURI : currentActiveSpotifyTrackURI;
        NSString *artist = (targetArtist && targetArtist.length > 0) ? targetArtist : currentActiveSpotifyTrackArtist;

        NSString *displayTrack = @"";
        if (title && title.length > 0) {
            displayTrack = (artist && artist.length > 0) ? [NSString stringWithFormat:@"%@ - %@", artist, title] : title;
        } else if (uri && uri.length > 0) {
            displayTrack = uri;
        }

        NSString *existingUrl = getOverrideForTrack(uri, title, artist) ?: @"";
        NSString *clip = [UIPasteboard generalPasteboard].string;
        NSString *defaultUrl = existingUrl;
        if (defaultUrl.length == 0 && clip && ([clip hasPrefix:@"http://"] || [clip hasPrefix:@"https://"])) {
            defaultUrl = [clip stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        }

        NSString *dialogMsg = @"Выбери аудиофайл с устройства или вставь SoundCloud ссылку:";
        if ([existingUrl hasPrefix:@"local://"]) {
            dialogMsg = @"📁 Сейчас подключен локальный файл с устройства!\nМожно выбрать другой файл или вставить SoundCloud ссылку:";
        } else if (existingUrl.length > 0) {
            dialogMsg = @"☁️ Сейчас подключен трек из SoundCloud!\nМожно заменить его локальным файлом или обновить ссылку:";
        }

        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"AntiCensor Замена"
                                                                        message:dialogMsg
                                                                 preferredStyle:UIAlertControllerStyleAlert];

        [alert addTextFieldWithConfigurationHandler:^(UITextField * _Nonnull tfTitle) {
            tfTitle.placeholder = @"Артист - Название трека";
            tfTitle.text = displayTrack;
            tfTitle.clearButtonMode = UITextFieldViewModeWhileEditing;
        }];

        [alert addTextFieldWithConfigurationHandler:^(UITextField * _Nonnull tfUrl) {
            tfUrl.placeholder = @"https://soundcloud.com/...";
            tfUrl.text = defaultUrl;
            tfUrl.clearButtonMode = UITextFieldViewModeWhileEditing;
        }];

        UIAlertAction *saveAction = [UIAlertAction actionWithTitle:@"Сохранить замену" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
            NSString *inputTrack = [alert.textFields[0].text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            NSString *inputUrl = [alert.textFields[1].text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

            if (inputUrl.length > 0) {
                resolveSoundCloudUrl(inputUrl, ^(NSURL *u) {});

                if (uri && [uri hasPrefix:@"spotify:track:"] && uri.length > 15) {
                    saveOverride(uri, inputUrl);
                }
                if (inputTrack.length > 1) {
                    saveOverride(inputTrack, inputUrl);
                }
                if (title && title.length > 1) {
                    saveOverride(title, inputUrl);
                    if (artist && artist.length > 1) {
                        saveOverride([NSString stringWithFormat:@"%@ - %@", artist, title], inputUrl);
                    }
                }
                startReplacementAudio(uri ?: (title ?: inputTrack), inputUrl, getCurrentSpotifyPreciseTime());
            } else {
                if (uri && uri.length > 5) saveOverride(uri, nil);
                if (inputTrack.length > 1) saveOverride(inputTrack, nil);
                if (title && title.length > 1) saveOverride(title, nil);
                stopReplacementAudio();
            }
        }];

        UIAlertAction *pickFileAction = [UIAlertAction actionWithTitle:@"📁 Выбрать MP3 / M4A с устройства" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
            NSString *inputTrack = [alert.textFields[0].text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            openLocalAudioPicker(uri, title, artist, inputTrack.length > 0 ? inputTrack : displayTrack);
        }];

        UIAlertAction *manageAction = [UIAlertAction actionWithTitle:@"Список всех замен треков" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull a) {
            showManageAllTracksDialog();
        }];

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

        BOOL isBannerHidden = [[NSUserDefaults standardUserDefaults] boolForKey:DEFAULTS_HIDE_BANNER_KEY];
        NSString *bannerBtnTitle = isBannerHidden ? @"Показать зелёную плашку сверху" : @"Скрыть зелёную плашку сверху";
        UIAlertAction *toggleBannerAction = [UIAlertAction actionWithTitle:bannerBtnTitle style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull a) {
            BOOL newHidden = !isBannerHidden;
            [[NSUserDefaults standardUserDefaults] setBool:newHidden forKey:DEFAULTS_HIDE_BANNER_KEY];
            [[NSUserDefaults standardUserDefaults] synchronize];
        }];

        UIAlertAction *removeAction = [UIAlertAction actionWithTitle:@"Сбросить замену этого трека" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
            if (uri && uri.length > 5) saveOverride(uri, nil);
            if (displayTrack.length > 1) saveOverride(displayTrack, nil);
            if (title && title.length > 1) saveOverride(title, nil);
            stopReplacementAudio();
        }];

        UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:@"Отмена" style:UIAlertActionStyleCancel handler:nil];

        [alert addAction:pickFileAction];
        [alert addAction:saveAction];
        if (existingUrl.length > 0) [alert addAction:removeAction];
        [alert addAction:manageAction];
        [alert addAction:toggleFloatAction];
        [alert addAction:toggleBannerAction];
        [alert addAction:cancelAction];

        [topVC presentViewController:alert animated:YES completion:nil];
    });
}

#pragma mark - Context Menu (3-Dots Menu) Accurate Extraction

static const char kAntiCensorUriKey = 0;
static const char kAntiCensorTitleKey = 0;
static const char kAntiCensorArtistKey = 0;

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

static void extractBestTrackInfo(UIViewController *sheetVC, NSString **outURI, NSString **outTitle, NSString **outArtist) {
    if (!sheetVC) return;

    NSArray *modelSelectors = @[@"track", @"entity", @"item", @"model", @"viewModel", @"actionContext", @"headerViewController"];
    for (NSString *selName in modelSelectors) {
        SEL sel = NSSelectorFromString(selName);
        if ([sheetVC respondsToSelector:sel]) {
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            id target = [sheetVC performSelector:sel];
            #pragma clang diagnostic pop
            if (target) {
                if (!*outURI) {
                    *outURI = extractTrackURIFromObject(target, 0);
                }
                if (!*outTitle) {
                    for (NSString *tSel in @[@"title", @"name", @"trackName", @"headerTitle"]) {
                        SEL s = NSSelectorFromString(tSel);
                        if ([target respondsToSelector:s]) {
                            #pragma clang diagnostic push
                            #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                            id tVal = [target performSelector:s];
                            #pragma clang diagnostic pop
                            if (tVal && [tVal isKindOfClass:[NSString class]] && [tVal length] > 1) {
                                *outTitle = (NSString *)tVal;
                                break;
                            }
                        }
                    }
                }
            }
        }
    }

    UIView *container = sheetVC.view;
    NSMutableArray<UILabel *> *labels = [NSMutableArray array];
    NSMutableArray *queue = [NSMutableArray arrayWithObject:container];
    while (queue.count > 0) {
        UIView *curr = queue.firstObject;
        [queue removeObjectAtIndex:0];
        if ([curr isKindOfClass:[UILabel class]]) {
            UILabel *l = (UILabel *)curr;
            if (l.text.length > 1 && ![l.text containsString:@"⚡"] && ![l.text containsString:@"AntiCensor"]) {
                [labels addObject:l];
            }
        }
        [queue addObjectsFromArray:curr.subviews];
    }

    [labels sortUsingComparator:^NSComparisonResult(UILabel *l1, UILabel *l2) {
        if (l1.font.pointSize > l2.font.pointSize) return NSOrderedAscending;
        if (l1.font.pointSize < l2.font.pointSize) return NSOrderedDescending;
        return NSOrderedSame;
    }];

    if (!*outTitle && labels.count > 0) {
        *outTitle = labels[0].text;
    }
    if (!*outArtist && labels.count > 1) {
        *outArtist = labels[1].text;
    }
}

static void anticensor_bannerCloseTapped(UIViewController *callerVC, SEL _cmd, UIButton *sender) {
    UIView *banner = sender.superview;
    if (banner) {
        [UIView animateWithDuration:0.2 animations:^{
            banner.alpha = 0.0;
        } completion:^(BOOL finished) {
            [banner removeFromSuperview];
        }];
    }
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:DEFAULTS_HIDE_BANNER_KEY];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

#pragma mark - Profile Drawer / Side Menu Integration

static UIButton *createDrawerButton(CGRect frame) {
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
    btn.tag = 889911;
    if (!CGRectIsEmpty(frame)) {
        btn.frame = frame;
        btn.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    }
    btn.backgroundColor = [UIColor colorWithRed:0.11 green:0.73 blue:0.33 alpha:0.18];
    btn.layer.cornerRadius = 12.0f;
    btn.layer.borderWidth = 1.0f;
    btn.layer.borderColor = [UIColor colorWithRed:0.11 green:0.73 blue:0.33 alpha:0.6].CGColor;
    btn.layer.masksToBounds = YES;
    btn.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    btn.contentEdgeInsets = UIEdgeInsetsMake(0, 16, 0, 16);

    [btn setTitle:@"⚡  AntiCensor" forState:UIControlStateNormal];
    [btn setTitleColor:[UIColor colorWithRed:0.18 green:0.85 blue:0.42 alpha:1.0] forState:UIControlStateNormal];
    btn.titleLabel.font = [UIFont boldSystemFontOfSize:15.0f];

    [btn addTarget:nil action:@selector(anticensor_drawerButtonTapped:) forControlEvents:UIControlEventTouchUpInside];
    return btn;
}

static void anticensor_drawerButtonTapped(id target, SEL _cmd, UIButton *sender) {
    if (@available(iOS 10.0, *)) {
        UIImpactFeedbackGenerator *gen = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
        [gen prepare];
        [gen impactOccurred];
    }

    // 1. Восстанавливаем показ баннера в меню "..."
    [[NSUserDefaults standardUserDefaults] setBool:NO forKey:DEFAULTS_HIDE_BANNER_KEY];
    [[NSUserDefaults standardUserDefaults] synchronize];

    // 2. Открываем меню настроек замен треков прямо сейчас
    NSString *title = currentActiveSpotifyTrackTitle;
    NSString *artist = currentActiveSpotifyTrackArtist;
    NSString *uri = currentActiveSpotifyTrackURI;

    showReplacementDialogWithContext(uri, title, artist);
}

static UILabel *findDrawerLabel(UIView *root) {
    if (!root || root.hidden || root.alpha < 0.05) return nil;
    if ([root isKindOfClass:[UILabel class]]) {
        UILabel *lbl = (UILabel *)root;
        NSString *txt = [lbl.text lowercaseString];
        if (txt.length > 0) {
            // ТОЛЬКО уникальная строка настроек бокового меню профиля!
            // Никаких "недавние" или "обновления", чтобы не засорять медиатеку!
            if ([txt containsString:@"настройки и конфиденциальность"] ||
                [txt containsString:@"settings and privacy"] ||
                [txt containsString:@"settings & privacy"]) {
                return lbl;
            }
        }
    }
    for (UIView *sub in root.subviews) {
        UILabel *found = findDrawerLabel(sub);
        if (found) return found;
    }
    return nil;
}

static void cleanupPhantomButtons(void) {
    // 1. Полностью убираем плавающую пилюлю с экрана
    if (floatingPillButton) {
        [floatingPillButton removeFromSuperview];
        floatingPillButton = nil;
    }

    // 2. Ищем и удаляем любые случайные кнопки (889911) и футеры (889910),
    // если они оказались вне настоящего бокового меню (например, в UIScrollView медиатеки)
    NSArray *windows = [UIApplication sharedApplication].windows;
    for (UIWindow *win in windows) {
        NSMutableArray *queue = [NSMutableArray arrayWithObject:win];
        while (queue.count > 0) {
            UIView *v = queue.firstObject;
            [queue removeObjectAtIndex:0];
            if (v.tag == 889911 || v.tag == 889910) {
                // Проверяем: есть ли в этой же ветке иерархии строка "настройки и конфиденциальность"?
                BOOL inRealDrawer = NO;
                UIView *p = v.superview;
                while (p && p != win) {
                    if (findDrawerLabel(p)) {
                        inRealDrawer = YES;
                        break;
                    }
                    p = p.superview;
                }
                if (!inRealDrawer) {
                    [v removeFromSuperview];
                }
            } else {
                [queue addObjectsFromArray:v.subviews];
            }
        }
    }
}

static void checkAndInjectProfileDrawerButton(void) {
    cleanupPhantomButtons();

    NSArray *windows = [UIApplication sharedApplication].windows;
    for (UIWindow *win in windows) {
        if (!win || win.hidden) continue;

        UILabel *targetLabel = findDrawerLabel(win);
        if (!targetLabel) continue;

        // Если метка скрыта или прозрачна — меню закрыто
        if (targetLabel.hidden || targetLabel.alpha < 0.2) continue;

        // Нашли "настройки и конфиденциальность"! Определяем родительский контейнер
        UIView *current = targetLabel;
        UITableView *parentTableView = nil;
        UIStackView *parentStackView = nil;
        UIScrollView *parentScrollView = nil;

        while (current && current != win) {
            if ([current isKindOfClass:[UITableView class]]) { parentTableView = (UITableView *)current; break; }
            if ([current isKindOfClass:[UIStackView class]]) { parentStackView = (UIStackView *)current; break; }
            if ([current isKindOfClass:[UIScrollView class]]) { parentScrollView = (UIScrollView *)current; break; }
            current = current.superview;
        }

        if (parentTableView) {
            if (![parentTableView viewWithTag:889911]) {
                CGFloat width = parentTableView.bounds.size.width;
                if (width < 100 || width > win.bounds.size.width) width = win.bounds.size.width * 0.78;
                UIView *existingFooter = parentTableView.tableFooterView;
                CGFloat existH = existingFooter ? existingFooter.bounds.size.height : 0;

                UIView *footerContainer = [[UIView alloc] initWithFrame:CGRectMake(0, 0, width, existH + 58.0)];
                footerContainer.tag = 889910;
                if (existingFooter) {
                    existingFooter.frame = CGRectMake(0, 0, width, existH);
                    [footerContainer addSubview:existingFooter];
                }
                UIButton *btn = createDrawerButton(CGRectMake(16.0, existH + 6.0, width - 32.0, 46.0));
                [footerContainer addSubview:btn];
                parentTableView.tableFooterView = footerContainer;
            }
            continue;
        }

        if (parentStackView) {
            if (![parentStackView viewWithTag:889911]) {
                UIButton *btn = createDrawerButton(CGRectZero);
                btn.translatesAutoresizingMaskIntoConstraints = NO;
                [parentStackView addArrangedSubview:btn];
                [NSLayoutConstraint activateConstraints:@[
                    [btn.heightAnchor constraintEqualToConstant:46.0]
                ]];
            }
            continue;
        }

        if (parentScrollView) {
            if (![parentScrollView viewWithTag:889911]) {
                UIView *row = targetLabel;
                while (row.superview && row.superview != parentScrollView) {
                    row = row.superview;
                }
                CGFloat width = parentScrollView.bounds.size.width;
                if (width < 100 || width > win.bounds.size.width) width = win.bounds.size.width * 0.78;
                CGFloat rowBottom = CGRectGetMaxY(row.frame);
                UIButton *btn = createDrawerButton(CGRectMake(16.0, rowBottom + 10.0, width - 32.0, 46.0));
                [parentScrollView addSubview:btn];
                CGFloat neededH = rowBottom + 10.0 + 46.0 + 20.0;
                if (parentScrollView.contentSize.height < neededH) {
                    parentScrollView.contentSize = CGSizeMake(parentScrollView.contentSize.width, neededH);
                }
            }
            continue;
        }

        // Обычный контейнер View
        UIView *row = targetLabel;
        while (row.superview && row.superview != win && row.superview.bounds.size.height < 150) {
            row = row.superview;
        }
        UIView *container = row.superview ?: win;
        if (![container viewWithTag:889911]) {
            CGRect rowInContainer = [row.superview convertRect:row.frame toView:container];
            CGFloat width = container.bounds.size.width;
            if (width < 100 || width > win.bounds.size.width) width = win.bounds.size.width * 0.78;
            CGFloat btnY = CGRectGetMaxY(rowInContainer) + 10.0;
            UIButton *btn = createDrawerButton(CGRectMake(16.0, btnY, width - 32.0, 46.0));
            [container addSubview:btn];
            [container bringSubviewToFront:btn];
        }
    }
}

static void addAntiCensorButtonToContextMenu(UIViewController *sheetVC) {
    if (!sheetVC || !sheetVC.isViewLoaded) return;
    BOOL isBannerHidden = [[NSUserDefaults standardUserDefaults] boolForKey:DEFAULTS_HIDE_BANNER_KEY];
    if (isBannerHidden) return;

    UIView *container = sheetVC.view;
    if ([container viewWithTag:778899]) return;

    NSString *extractedURI = nil;
    NSString *extractedTitle = nil;
    NSString *extractedArtist = nil;
    extractBestTrackInfo(sheetVC, &extractedURI, &extractedTitle, &extractedArtist);

    UIView *bannerView = [[UIView alloc] init];
    bannerView.tag = 778899;
    bannerView.translatesAutoresizingMaskIntoConstraints = NO;
    bannerView.backgroundColor = [UIColor colorWithRed:0.11 green:0.73 blue:0.33 alpha:1.0];
    bannerView.layer.cornerRadius = 22.0f;
    bannerView.layer.masksToBounds = YES;

    UIButton *mainBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    mainBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [mainBtn setTitle:@"⚡ Заменить на SoundCloud (AntiCensor)" forState:UIControlStateNormal];
    [mainBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    mainBtn.titleLabel.font = [UIFont boldSystemFontOfSize:13.5f];

    if (extractedURI) objc_setAssociatedObject(mainBtn, &kAntiCensorUriKey, extractedURI, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (extractedTitle) objc_setAssociatedObject(mainBtn, &kAntiCensorTitleKey, extractedTitle, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (extractedArtist) objc_setAssociatedObject(mainBtn, &kAntiCensorArtistKey, extractedArtist, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    [mainBtn addTarget:sheetVC action:@selector(anticensor_onContextMenuButtonTap:) forControlEvents:UIControlEventTouchUpInside];
    [bannerView addSubview:mainBtn];

    UIButton *closeBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    closeBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [closeBtn setTitle:@"✕" forState:UIControlStateNormal];
    [closeBtn setTitleColor:[UIColor colorWithWhite:1.0 alpha:0.8] forState:UIControlStateNormal];
    closeBtn.titleLabel.font = [UIFont boldSystemFontOfSize:15.0f];
    [closeBtn addTarget:sheetVC action:@selector(anticensor_bannerCloseTapped:) forControlEvents:UIControlEventTouchUpInside];
    [bannerView addSubview:closeBtn];

    [container addSubview:bannerView];

    [NSLayoutConstraint activateConstraints:@[
        [bannerView.centerXAnchor constraintEqualToAnchor:container.centerXAnchor],
        [bannerView.topAnchor constraintEqualToAnchor:container.safeAreaLayoutGuide.topAnchor constant:10.0],
        [bannerView.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:12.0],
        [bannerView.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-12.0],
        [bannerView.heightAnchor constraintEqualToConstant:44.0],

        [mainBtn.leadingAnchor constraintEqualToAnchor:bannerView.leadingAnchor constant:10.0],
        [mainBtn.trailingAnchor constraintEqualToAnchor:closeBtn.leadingAnchor constant:-5.0],
        [mainBtn.topAnchor constraintEqualToAnchor:bannerView.topAnchor],
        [mainBtn.bottomAnchor constraintEqualToAnchor:bannerView.bottomAnchor],

        [closeBtn.trailingAnchor constraintEqualToAnchor:bannerView.trailingAnchor constant:-10.0],
        [closeBtn.widthAnchor constraintEqualToConstant:32.0],
        [closeBtn.topAnchor constraintEqualToAnchor:bannerView.topAnchor],
        [closeBtn.bottomAnchor constraintEqualToAnchor:bannerView.bottomAnchor]
    ]];

    [container bringSubviewToFront:bannerView];
}

static void anticensor_onContextMenuButtonTap(UIViewController *callerVC, SEL _cmd, UIButton *sender) {
    NSString *uri = objc_getAssociatedObject(sender, &kAntiCensorUriKey);
    NSString *title = objc_getAssociatedObject(sender, &kAntiCensorTitleKey);
    NSString *artist = objc_getAssociatedObject(sender, &kAntiCensorArtistKey);
    [callerVC dismissViewControllerAnimated:YES completion:^{
        showReplacementDialogWithContext(uri, title, artist);
    }];
}

#pragma mark - Method Swizzling

static void (*orig_presentViewController)(id, SEL, UIViewController *, BOOL, void (^)(void));
static void custom_presentViewController(UIViewController *callerVC, SEL _cmd, UIViewController *vcToPresent, BOOL animated, void (^completion)(void)) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        checkAndInjectProfileDrawerButton();
    });

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

static UIMenu * (*orig_menuWithTitle_image_identifier_options_children)(id, SEL, NSString *, UIImage *, id, NSUInteger, NSArray *);
static UIMenu * custom_menuWithTitle_image_identifier_options_children(id target, SEL _cmd, NSString *title, UIImage *image, id identifier, NSUInteger options, NSArray *children) {
    if (children && children.count > 0) {
        UIAction *action = [UIAction actionWithTitle:@"⚡ Заменить на SoundCloud (AntiCensor)"
                                               image:[UIImage systemImageNamed:@"arrow.triangle.2.circlepath"]
                                          identifier:@"com.anticensor.action"
                                             handler:^(UIAction *a) {
            showReplacementDialogWithContext(nil, title, nil);
        }];
        children = [children arrayByAddingObject:action];
    }
    if (orig_menuWithTitle_image_identifier_options_children) {
        return orig_menuWithTitle_image_identifier_options_children(target, _cmd, title, image, identifier, options, children);
    }
    return nil;
}

#pragma mark - Floating Badge

static void anticensor_floatingBadgeTapped(id target, SEL _cmd);
static void anticensor_handleBadgePan(id target, SEL _cmd, UIPanGestureRecognizer *pan);

static void setupFloatingBadge(void) {
    // В v3.8 плавающая кнопка скрыта по умолчанию, так как есть кнопка в боковом меню профиля
    BOOL isHidden = [[NSUserDefaults standardUserDefaults] boolForKey:DEFAULTS_HIDE_FLOAT_KEY];
    if (isHidden) {
        if (floatingPillButton) {
            [floatingPillButton removeFromSuperview];
            floatingPillButton = nil;
        }
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *window = getKeyAppWindow();
        if (!window) return;

        if (floatingPillButton) {
            floatingPillButton.hidden = NO;
            [window bringSubviewToFront:floatingPillButton];
            return;
        }

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
    NSString *uiTitle = nil;
    NSString *uiArtist = nil;
    findSpotifyNowPlayingTrackInfo(&uiTitle, &uiArtist);

    NSString *title = uiTitle ?: currentActiveSpotifyTrackTitle;
    NSString *artist = uiArtist ?: currentActiveSpotifyTrackArtist;
    showReplacementDialogWithContext(currentActiveSpotifyTrackURI, title, artist);
}

static void anticensor_handleBadgePan(id target, SEL _cmd, UIPanGestureRecognizer *pan) {
    UIView *badge = pan.view;
    CGPoint translation = [pan translationInView:badge.window];
    badge.center = CGPointMake(badge.center.x + translation.x, badge.center.y + translation.y);
    [pan setTranslation:CGPointMake(0, 0) inView:badge.window];
}

#pragma mark - Dynamic Injection Constructor

__attribute__((constructor)) static void initAntiCensor(void) {
    NSLog(@"[AntiCensor] Initializing AntiCensor iOS Tweak v3.8 (Dynamic Island + Clean Drawer + Smooth Playback)...");

    // Инициализация аудиосессии для гарантированной поддержки Dynamic Island и экрана блокировки
    AVAudioSession *session = [AVAudioSession sharedInstance];
    [session setCategory:AVAudioSessionCategoryPlayback
             withOptions:AVAudioSessionCategoryOptionAllowBluetooth | AVAudioSessionCategoryOptionAllowAirPlay
                   error:nil];
    [session setActive:YES error:nil];

    // ОДНОКРАТНАЯ ПОЛНАЯ ОЧИСТКА БАЗЫ ДАННЫХ ОТ СТАРЫХ МУСОРНЫХ КЛЮЧЕЙ (WIPE CORRUPTED CACHE)
    BOOL isCleanedV35 = [[NSUserDefaults standardUserDefaults] boolForKey:DEFAULTS_VERSION_KEY];
    if (!isCleanedV35) {
        [[NSFileManager defaultManager] removeItemAtPath:getStorageFilePath() error:nil];
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:DEFAULTS_OVERRIDES_KEY];
        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:DEFAULTS_VERSION_KEY];
        [[NSUserDefaults standardUserDefaults] synchronize];
    }

    // v3.8: Чистка фантомных плашек, скрытие плавающей пилюли
    BOOL isCleanedV38 = [[NSUserDefaults standardUserDefaults] boolForKey:DEFAULTS_VERSION_KEY_38];
    if (!isCleanedV38) {
        [[NSUserDefaults standardUserDefaults] setBool:NO forKey:DEFAULTS_HIDE_BANNER_KEY];
        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:DEFAULTS_HIDE_FLOAT_KEY];
        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:DEFAULTS_VERSION_KEY_38];
        [[NSUserDefaults standardUserDefaults] synchronize];
    }

    // 1. CoreAudio мьютер микшера Spotify с полным перехватом AudioUnitSetParameter
    struct rebinding audioRebind[3];
    audioRebind[0].name = "AudioOutputUnitStart";
    audioRebind[0].replacement = (void *)custom_AudioOutputUnitStart;
    audioRebind[0].replaced = (void **)&orig_AudioOutputUnitStart;

    audioRebind[1].name = "AudioUnitInitialize";
    audioRebind[1].replacement = (void *)custom_AudioUnitInitialize;
    audioRebind[1].replaced = (void **)&orig_AudioUnitInitialize;

    audioRebind[2].name = "AudioUnitSetParameter";
    audioRebind[2].replacement = (void *)custom_AudioUnitSetParameter;
    audioRebind[2].replaced = (void **)&orig_AudioUnitSetParameter;

    ac_rebind_symbols(audioRebind, 3);

    // 2. Хук контекстного меню и обработчики UI
    Class respClass = objc_getClass("UIResponder");
    if (respClass) {
        class_addMethod(respClass, @selector(anticensor_drawerButtonTapped:), (IMP)anticensor_drawerButtonTapped, "v@:@");
    }

    Class vcClass = objc_getClass("UIViewController");
    if (vcClass) {
        class_addMethod(vcClass, @selector(anticensor_onContextMenuButtonTap:), (IMP)anticensor_onContextMenuButtonTap, "v@:@");
        class_addMethod(vcClass, @selector(anticensor_bannerCloseTapped:), (IMP)anticensor_bannerCloseTapped, "v@:@");
        class_addMethod(vcClass, @selector(anticensor_drawerButtonTapped:), (IMP)anticensor_drawerButtonTapped, "v@:@");
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
            orig_menuWithTitle_image_identifier_options_children = (UIMenu * (*)(id, SEL, NSString *, UIImage *, id, NSUInteger, NSArray *))method_getImplementation(mMenu);
            method_setImplementation(mMenu, (IMP)custom_menuWithTitle_image_identifier_options_children);
        }
    }

    // 4. Хук MPNowPlayingInfoCenter для точного определения треков и синхронизации
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
        class_addMethod(winClass, @selector(anticensor_drawerButtonTapped:), (IMP)anticensor_drawerButtonTapped, "v@:@");
    }

    // 5. Фоновый высокочастотный таймер синхронизации и смены треков (каждые 250 мс)
    dispatch_async(dispatch_get_main_queue(), ^{
        periodicSyncTimer = [NSTimer scheduledTimerWithTimeInterval:0.25 repeats:YES block:^(NSTimer * _Nonnull timer) {
            onPeriodicSyncCheck(timer);
        }];
        [[NSRunLoop mainRunLoop] addTimer:periodicSyncTimer forMode:NSRunLoopCommonModes];
    });
}
