#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <MediaPlayer/MediaPlayer.h>
#import <AudioToolbox/AudioToolbox.h>
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
#define DEFAULTS_VERSION_KEY_39    @"AntiCensor_Storage_v3_9_Fixes"
#define DEFAULTS_VERSION_KEY_40    @"AntiCensor_Storage_v4_0_Sync"
#define DEFAULTS_LYRICS_KEY        @"AntiCensor_Lyrics"
#define DEFAULT_SERVER_URL         @"https://spotik-in4b.onrender.com"
#define SC_CLIENT_ID               @"2yeWkbX88QhTzS3OtZp8cLGaJRrOAWwF"

static void setupFloatingBadge(void);
static void checkAndInjectProfileDrawerButton(void);
static void checkAndSyncLyricsOnScreen(void);
static void addAntiCensorRowToContextMenu(UIViewController *sheetVC);
static void syncPullFromCloud(void (^completion)(BOOL success, NSUInteger count));
static void syncPushToCloud(NSString *key, NSString *value, BOOL isLyrics);
static void showAntiCensorMainOptionsDialog(NSString *targetURI, NSString *targetTitle, NSString *targetArtist);
static void showSoundCloudInputPrompt(NSString *uri, NSString *title, NSString *artist, NSString *displayTrack, NSString *existingUrl);
static void showLyricsManagerDialog(NSString *targetURI, NSString *targetTitle, NSString *targetArtist, NSString *displayTrack);
static void showLyricsEditPrompt(NSString *uri, NSString *title, NSString *artist, NSString *displayTrack, NSString *existingLyrics);
static NSString *getLyricsForTrack(NSString *uri, NSString *title, NSString *artist);
static void saveLyricsForTrack(NSString *trackKey, NSString *lyrics);
static void startReplacementAudio(NSString *trackKey, NSString *scUrl, double initialPosition);
static void stopReplacementAudio(void);
static void safeSeekPlayerToTime(double targetSeconds);

static double g_spotifyLastReportedPosition = 0.0;
static CFTimeInterval g_spotifyLastReportedTimestamp = 0;
static BOOL g_isPlayerFading = NO;
static NSString *currentPlayingUrl = nil;

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

static inline BOOL isCallerFromSpotifyBinary(void *retAddr) {
    if (!retAddr) return NO;
    Dl_info info;
    if (dladdr(retAddr, &info) && info.dli_fname) {
        const char *fn = info.dli_fname;
        // Проверяем, что вызов исходит ИМЕННО из исполняемого файла Spotify, а не из системных фреймворков или нашего AVPlayer!
        if (strstr(fn, "Spotify.app/Spotify") != NULL || (strstr(fn, "Spotify") != NULL && strstr(fn, ".framework") == NULL)) {
            if (strstr(fn, "AntiCensor") == NULL &&
                strstr(fn, "AVFoundation") == NULL &&
                strstr(fn, "MediaToolbox") == NULL &&
                strstr(fn, "AudioToolbox") == NULL) {
                return YES;
            }
        }
    }
    return NO;
}

static void recordAudioUnit(void *unit) {
    if (!unit) return;
    for (int i = 0; i < g_activeUnitCount; i++) {
        if (g_activeUnits[i] == unit) return;
    }
    if (g_activeUnitCount < 16) {
        g_activeUnits[g_activeUnitCount++] = unit;
    }
}

static void removeAudioUnit(void *unit) {
    if (!unit) return;
    for (int i = 0; i < g_activeUnitCount; i++) {
        if (g_activeUnits[i] == unit) {
            for (int j = i; j < g_activeUnitCount - 1; j++) {
                g_activeUnits[j] = g_activeUnits[j + 1];
            }
            g_activeUnitCount--;
            return;
        }
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
            @try {
                orig_AudioUnitSetParameter(u, 0 /* kMultiChannelMixerParam_Volume */, 1 /* Input */, 0 /* Bus 0 */, vol, 0);
                orig_AudioUnitSetParameter(u, 0, 1 /* Input */, 1 /* Bus 1 */, vol, 0);
                orig_AudioUnitSetParameter(u, 0, 2 /* Output */, 0, vol, 0);
            } @catch (id ex) {}
        }
    }
}

static OSStatus custom_AudioUnitSetParameter(void *inUnit, uint32_t inID, uint32_t inScope, uint32_t inElement, float inValue, uint32_t inBufferOffsetInFrames) {
    // ВАЖНО: Перехватываем и глушим громкость ТОЛЬКО для оригинального звукового движка Spotify!
    // Наш собственный AVPlayer ни при каких условиях не заглушается!
    if (isCallerFromSpotifyBinary(__builtin_return_address(0))) {
        if (inID == 0 /* kMultiChannelMixerParam_Volume */) {
            recordAudioUnit(inUnit);
            if (isMutingSpotify) {
                inValue = 0.0f; // Принудительный мьют: Spotify не может сам вернуть себе звук!
            }
        }
    }
    return orig_AudioUnitSetParameter ? orig_AudioUnitSetParameter(inUnit, inID, inScope, inElement, inValue, inBufferOffsetInFrames) : 0;
}

typedef OSStatus (*AudioOutputUnitStart_t)(void *unit);
static AudioOutputUnitStart_t orig_AudioOutputUnitStart = NULL;
static OSStatus custom_AudioOutputUnitStart(void *unit) {
    if (isCallerFromSpotifyBinary(__builtin_return_address(0))) {
        recordAudioUnit(unit);
        applyMuteStateToAllUnits();
    }
    return orig_AudioOutputUnitStart ? orig_AudioOutputUnitStart(unit) : 0;
}

typedef OSStatus (*AudioUnitInitialize_t)(void *unit);
static AudioUnitInitialize_t orig_AudioUnitInitialize = NULL;
static OSStatus custom_AudioUnitInitialize(void *unit) {
    if (isCallerFromSpotifyBinary(__builtin_return_address(0))) {
        recordAudioUnit(unit);
        applyMuteStateToAllUnits();
    }
    return orig_AudioUnitInitialize ? orig_AudioUnitInitialize(unit) : 0;
}

typedef OSStatus (*AudioComponentInstanceDispose_t)(void *inInstance);
static AudioComponentInstanceDispose_t orig_AudioComponentInstanceDispose = NULL;
static OSStatus custom_AudioComponentInstanceDispose(void *inInstance) {
    removeAudioUnit(inInstance);
    return orig_AudioComponentInstanceDispose ? orig_AudioComponentInstanceDispose(inInstance) : 0;
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

static NSString *getServerURL(void) {
    NSString *url = [[NSUserDefaults standardUserDefaults] stringForKey:DEFAULTS_SERVER_KEY];
    if (!url || url.length == 0) {
        return DEFAULT_SERVER_URL;
    }
    return [url stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/"]];
}

static NSString *getLyricsFilePath(void) {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *docDir = paths.firstObject;
    return [docDir stringByAppendingPathComponent:@"AntiCensor_Lyrics.json"];
}

static NSMutableDictionary *loadAllLyrics(void) {
    NSString *path = getLyricsFilePath();
    NSData *data = [NSData dataWithContentsOfFile:path];
    NSDictionary *rawDict = nil;
    if (data) {
        rawDict = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    }
    if (!rawDict || ![rawDict isKindOfClass:[NSDictionary class]]) {
        rawDict = [[NSUserDefaults standardUserDefaults] dictionaryForKey:DEFAULTS_LYRICS_KEY];
    }
    NSMutableDictionary *cleaned = [NSMutableDictionary dictionary];
    if (rawDict && [rawDict isKindOfClass:[NSDictionary class]]) {
        for (NSString *k in rawDict) {
            NSString *val = [rawDict[k] description];
            if (val && val.length > 0) {
                cleaned[normalizeKey(k)] = val;
            }
        }
    }
    return cleaned;
}

static void persistLyrics(NSDictionary *dict) {
    if (!dict) return;
    NSData *data = [NSJSONSerialization dataWithJSONObject:dict options:NSJSONWritingPrettyPrinted error:nil];
    if (data) {
        [data writeToFile:getLyricsFilePath() atomically:YES];
    }
    [[NSUserDefaults standardUserDefaults] setObject:dict forKey:DEFAULTS_LYRICS_KEY];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

static void syncPushToCloud(NSString *key, NSString *value, BOOL isLyrics) {
    if (!key || key.length == 0) return;
    NSString *server = getServerURL();
    NSURL *syncUrl = [NSURL URLWithString:[NSString stringWithFormat:@"%@/api/sync", server]];
    if (!syncUrl) return;

    NSMutableDictionary *payload = [NSMutableDictionary dictionary];
    if (isLyrics) {
        payload[@"lyrics"] = @{ key: value ?: @"" };
    } else {
        payload[@"overrides"] = @{ key: value ?: @"" };
    }

    NSData *bodyData = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
    if (!bodyData) return;

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:syncUrl];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    req.HTTPBody = bodyData;
    req.timeoutInterval = 7.0;

    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        if (!err) {
            NSLog(@"[AntiCensor] Cloud sync push SUCCESS for key: %@", key);
        } else {
            NSLog(@"[AntiCensor] Cloud sync push failed: %@", err);
        }
    }] resume];
}

static void syncPullFromCloud(void (^completion)(BOOL success, NSUInteger count)) {
    NSString *server = getServerURL();
    NSURL *syncUrl = [NSURL URLWithString:[NSString stringWithFormat:@"%@/api/sync", server]];
    if (!syncUrl) {
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(NO, 0); });
        return;
    }

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:syncUrl];
    req.HTTPMethod = @"GET";
    req.timeoutInterval = 7.0;

    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        if (!data || err) {
            if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(NO, 0); });
            return;
        }

        @try {
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if (!json || ![json isKindOfClass:[NSDictionary class]]) {
                if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(NO, 0); });
                return;
            }

            __block NSUInteger updatedCount = 0;

            // 1. Оверрайды треков с ПК
            NSDictionary *remoteOverrides = json[@"overrides"];
            if (remoteOverrides && [remoteOverrides isKindOfClass:[NSDictionary class]]) {
                NSMutableDictionary *localOverrides = loadAllOverrides();
                for (NSString *k in remoteOverrides) {
                    NSString *normK = normalizeKey(k);
                    NSString *remoteVal = [remoteOverrides[k] description];
                    if (remoteVal.length > 0) {
                        NSString *curr = localOverrides[normK];
                        if (!curr || ![curr hasPrefix:@"local://"]) {
                            if (![curr isEqualToString:remoteVal]) {
                                localOverrides[normK] = remoteVal;
                                updatedCount++;
                            }
                        }
                    }
                }
                persistOverrides(localOverrides);
            }

            // 2. Тексты песен с ПК
            NSDictionary *remoteLyrics = json[@"lyrics"];
            if (remoteLyrics && [remoteLyrics isKindOfClass:[NSDictionary class]]) {
                NSMutableDictionary *localLyrics = loadAllLyrics();
                for (NSString *k in remoteLyrics) {
                    NSString *normK = normalizeKey(k);
                    NSString *remoteTxt = [remoteLyrics[k] description];
                    if (remoteTxt.length > 0) {
                        NSString *currTxt = localLyrics[normK];
                        if (![currTxt isEqualToString:remoteTxt]) {
                            localLyrics[normK] = remoteTxt;
                            updatedCount++;
                        }
                    }
                }
                persistLyrics(localLyrics);
            }

            NSLog(@"[AntiCensor] Cloud sync pull SUCCESS, merged entries: %lu", (unsigned long)updatedCount);
            if (completion) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    completion(YES, updatedCount);
                });
            }
        } @catch (id ex) {
            if (completion) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    completion(NO, 0);
                });
            }
        }
    }] resume];
}

static void saveLyricsForTrack(NSString *trackKey, NSString *lyrics) {
    if (!trackKey) return;
    NSString *normKey = normalizeKey(trackKey);
    if (normKey.length < 3) return;

    NSMutableDictionary *dict = loadAllLyrics();
    if (lyrics && lyrics.length > 0) {
        dict[normKey] = lyrics;
        syncPushToCloud(normKey, lyrics, YES);
    } else {
        [dict removeObjectForKey:normKey];
        syncPushToCloud(normKey, @"", YES);
    }
    persistLyrics(dict);
}

static NSString *getLyricsForTrack(NSString *uri, NSString *title, NSString *artist) {
    if ((!uri || uri.length < 5) && (!title || title.length < 2)) {
        return nil;
    }
    NSDictionary *dict = loadAllLyrics();
    if (!dict || dict.count == 0) return nil;

    if (uri && [uri hasPrefix:@"spotify:track:"] && uri.length > 15) {
        NSString *val = dict[normalizeKey(uri)];
        if (val && val.length > 0) return val;
    }

    if (title && title.length > 1 && artist && artist.length > 1) {
        NSString *combined = [NSString stringWithFormat:@"%@ - %@", artist, title];
        NSString *val = dict[normalizeKey(combined)];
        if (val && val.length > 0) return val;

        NSString *combined2 = [NSString stringWithFormat:@"%@ — %@", artist, title];
        NSString *val2 = dict[normalizeKey(combined2)];
        if (val2 && val2.length > 0) return val2;
    }

    if (title && title.length > 1) {
        NSString *val = dict[normalizeKey(title)];
        if (val && val.length > 0) return val;
    }

    return nil;
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
        NSString *cleanVal = [scUrl stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        dict[normKey] = cleanVal;
        syncPushToCloud(normKey, cleanVal, NO);
    } else {
        [dict removeObjectForKey:normKey];
        syncPushToCloud(normKey, @"", NO);
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

#pragma mark - Direct Stream Cache & Resolution Engine (Zero Cooldown!)

static NSMutableDictionary<NSString *, NSURL *> *g_streamCache = nil;
static NSMutableDictionary<NSString *, NSNumber *> *g_streamCacheTimestamps = nil;

static void resolveSoundCloudUrl(NSString *rawUrl, void (^completion)(NSURL *streamUrl)) {
    if (!rawUrl || rawUrl.length == 0) {
        completion(nil);
        return;
    }

    if (!g_streamCache) {
        g_streamCache = [NSMutableDictionary dictionary];
    }
    if (!g_streamCacheTimestamps) {
        g_streamCacheTimestamps = [NSMutableDictionary dictionary];
    }

    NSURL *cached = g_streamCache[rawUrl];
    NSNumber *cachedTs = g_streamCacheTimestamps[rawUrl];
    if (cached) {
        // Подписи CloudFront для SoundCloud действительны ~3-5 минут. Не используем протухшие ссылки!
        if (!cachedTs || ([NSDate timeIntervalSinceReferenceDate] - [cachedTs doubleValue] < 180.0)) {
            completion(cached);
            return;
        } else {
            [g_streamCache removeObjectForKey:rawUrl];
            [g_streamCacheTimestamps removeObjectForKey:rawUrl];
        }
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
        g_streamCacheTimestamps[rawUrl] = @([NSDate timeIntervalSinceReferenceDate]);
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
                                        g_streamCacheTimestamps[rawUrl] = @([NSDate timeIntervalSinceReferenceDate]);
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

#pragma mark - KVO & Safe Player Seeking Engine

static BOOL g_isPlayerSeeking = NO;
static double g_pendingSeekTarget = -1.0;
static BOOL g_isUpdatingNowPlaying = NO;

static void updateNowPlayingCenter(void);
static void safeSeekPlayerToTime(double targetSeconds);

static void safeSeekPlayerToTime(double targetSeconds) {
    if (!ourAudioPlayer) return;
    if (isnan(targetSeconds) || targetSeconds < 0) return;

    // Защита от заиканий и перегрузки: если плеер уже выполняет перемотку,
    // просто запоминаем последнюю запрошенную точку и выполним её по окончании
    if (g_isPlayerSeeking) {
        g_pendingSeekTarget = targetSeconds;
        return;
    }

    g_isPlayerSeeking = YES;
    g_pendingSeekTarget = -1.0;

    CMTime seekTime = CMTimeMakeWithSeconds(targetSeconds, NSEC_PER_SEC);
    // Допуск 0.15 сек дает мгновенную, мягкую перемотку без треска и флуда декодера
    CMTime tolerance = CMTimeMakeWithSeconds(0.15, NSEC_PER_SEC);

    [ourAudioPlayer seekToTime:seekTime toleranceBefore:tolerance toleranceAfter:tolerance completionHandler:^(BOOL finished) {
        dispatch_async(dispatch_get_main_queue(), ^{
            g_isPlayerSeeking = NO;
            if (g_pendingSeekTarget >= 0) {
                double nextPos = g_pendingSeekTarget;
                g_pendingSeekTarget = -1.0;
                safeSeekPlayerToTime(nextPos);
            } else {
                if (isSpotifyCurrentlyPlaying && ourAudioPlayer) {
                    if (ourAudioPlayer.timeControlStatus != AVPlayerTimeControlStatusPlaying) {
                        [ourAudioPlayer play];
                    }
                }
                updateNowPlayingCenter();
            }
        });
    }];
}

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
                if (!g_isPlayerFading) {
                    ourAudioPlayer.volume = 1.0f;
                }
                double targetSeconds = getCurrentSpotifyPreciseTime();
                if (targetSeconds > 2.0) {
                    safeSeekPlayerToTime(targetSeconds);
                } else {
                    if (isSpotifyCurrentlyPlaying && ourAudioPlayer) {
                        [ourAudioPlayer play];
                    }
                }
            });
        } else if (item.status == AVPlayerItemStatusFailed) {
            NSLog(@"[AntiCensor] AVPlayerItem failed: %@. Spotify STAYS MUTED to prevent censorship leak!", item.error);
            // СТРОГО: Ни в коем случае НЕ размьючиваем Spotify! Цензурный оригинал НИКОГДА не должен прорываться в эфир!
            isMutingSpotify = YES;
            applyMuteStateToAllUnits();

            if (currentPlayingKey) {
                NSString *currRep = getOverrideForTrack(currentActiveSpotifyTrackURI, currentActiveSpotifyTrackTitle, currentActiveSpotifyTrackArtist);
                if (currRep) {
                    [g_streamCache removeObjectForKey:currRep];
                    if (g_streamCacheTimestamps) [g_streamCacheTimestamps removeObjectForKey:currRep];
                }
            }

            // Перезагружаем заменяющий поток в тишине через 1.0 сек
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (currentPlayingKey && isSpotifyCurrentlyPlaying) {
                    NSString *currRep = getOverrideForTrack(currentActiveSpotifyTrackURI, currentActiveSpotifyTrackTitle, currentActiveSpotifyTrackArtist);
                    if (currRep) {
                        startReplacementAudio(currentPlayingKey, currRep, getCurrentSpotifyPreciseTime());
                    }
                }
            });
        }
    }
}

@end

static AntiCensorPlayerObserver *g_playerObserver = nil;

static void fadeOutPlayer(AVPlayer *playerToFade, NSTimeInterval duration) {
    if (!playerToFade) return;
    int steps = 15;
    NSTimeInterval interval = duration / (NSTimeInterval)steps;
    for (int i = 1; i <= steps; i++) {
        float vol = 1.0f - ((float)i / (float)steps);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * interval * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            playerToFade.volume = vol;
            if (i == steps) {
                [playerToFade pause];
            }
        });
    }
}

static void fadeInPlayer(AVPlayer *playerToFade, NSTimeInterval duration) {
    if (!playerToFade) return;
    g_isPlayerFading = YES;
    playerToFade.volume = 0.0f;
    [playerToFade play];
    int steps = 15;
    NSTimeInterval interval = duration / (NSTimeInterval)steps;
    for (int i = 1; i <= steps; i++) {
        float vol = (float)i / (float)steps;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * interval * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            playerToFade.volume = vol;
            if (i == steps) {
                playerToFade.volume = 1.0f;
                g_isPlayerFading = NO;
            }
        });
    }
}

static void stopReplacementAudio(void) {
    isReplacementLoading = NO;
    currentPlayingKey = nil;
    currentPlayingUrl = nil;
    g_isPlayerSeeking = NO;
    g_pendingSeekTarget = -1.0;

    if (ourAudioPlayer) {
        if (isObservingPlayerItem) {
            @try {
                [ourAudioPlayer.currentItem removeObserver:g_playerObserver forKeyPath:@"status" context:kStatusObserverContext];
            } @catch (id ex) {}
            isObservingPlayerItem = NO;
        }
        AVPlayer *p = ourAudioPlayer;
        ourAudioPlayer = nil;
        // Плавное затухание заменяющего плеера при переходе на нативный трек
        fadeOutPlayer(p, 1.2);
    }

    isMutingSpotify = NO;
    applyMuteStateToAllUnits(); // Spotify возвращает свой звук на 100%!
}

static void handleTrackPlaybackUpdate(NSString *title, NSString *artist, NSString *trackURI, double position, BOOL isPlaying, BOOL hasElapsed, BOOL hasRate);

static void (*orig_setNowPlayingInfo)(id, SEL, NSDictionary *);

static void updateNowPlayingCenter(void) {
    if (!ourAudioPlayer) return;
    if (g_isUpdatingNowPlaying) return; // СТРОГАЯ ЗАЩИТА ОТ РЕКУРСИИ!

    g_isUpdatingNowPlaying = YES;
    @try {
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

        // Напрямую вызываем оригинальный метод, чтобы не проваливаться в собственный хук!
        if (orig_setNowPlayingInfo) {
            orig_setNowPlayingInfo(center, @selector(setNowPlayingInfo:), info);
        } else {
            center.nowPlayingInfo = info;
        }
    } @catch (id ex) {}
    g_isUpdatingNowPlaying = NO;
}

#define KARAOKE_CONTAINER_TAG 0xAC888

@interface AntiCensorLyricItem : NSObject
@property (nonatomic, assign) double time;
@property (nonatomic, copy) NSString *text;
@end

@implementation AntiCensorLyricItem
@end

@interface AntiCensorTapHandler : NSObject <UIGestureRecognizerDelegate>
+ (instancetype)sharedHandler;
- (void)onKaraokeLineTapped:(UITapGestureRecognizer *)gesture;
- (void)onKaraokeContainerTapped:(UITapGestureRecognizer *)gesture;
- (void)handleSeekToLyricIndex:(NSInteger)idx inView:(UIView *)view;
@end

static NSArray<AntiCensorLyricItem *> *g_currentKaraokeItems = nil;
static NSMutableArray<UILabel *> *g_currentKaraokeLabels = nil;
static NSString *g_currentKaraokeTrackKey = nil;
static NSInteger g_lastActiveKaraokeIdx = -1;

static double g_currentTrackDuration = 180.0;

static void seekSpotifyPlayback(double targetSeconds, double duration) {
    if (isnan(targetSeconds) || targetSeconds < 0) return;

    g_spotifyLastReportedPosition = targetSeconds;
    g_spotifyLastReportedTimestamp = [NSDate timeIntervalSinceReferenceDate];

    dispatch_async(dispatch_get_main_queue(), ^{
        NSArray *windows = [UIApplication sharedApplication].windows;
        for (UIWindow *win in windows) {
            if (!win || win.hidden) continue;
            NSMutableArray *queue = [NSMutableArray arrayWithObject:win];
            while (queue.count > 0) {
                UIView *v = queue.firstObject;
                [queue removeObjectAtIndex:0];
                if ([v isKindOfClass:[UISlider class]]) {
                    UISlider *slider = (UISlider *)v;
                    if (slider.bounds.size.width > 120.0) {
                        float val = 0.0f;
                        if (slider.maximumValue <= 1.05f && slider.maximumValue >= 0.95f) {
                            val = (duration > 0) ? (float)(targetSeconds / duration) : 0.0f;
                        } else if (slider.maximumValue > 10.0f) {
                            val = (float)targetSeconds;
                        }
                        slider.value = val;
                        [slider sendActionsForControlEvents:UIControlEventValueChanged];
                        [slider sendActionsForControlEvents:UIControlEventTouchUpInside];
                        return;
                    }
                }
                [queue addObjectsFromArray:v.subviews];
            }
        }
    });
}

@implementation AntiCensorTapHandler
+ (instancetype)sharedHandler {
    static AntiCensorTapHandler *s_inst = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        s_inst = [[AntiCensorTapHandler alloc] init];
    });
    return s_inst;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    return YES;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch {
    return YES;
}

- (void)handleSeekToLyricIndex:(NSInteger)idx inView:(UIView *)view {
    if (@available(iOS 10.0, *)) {
        UIImpactFeedbackGenerator *gen = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
        [gen prepare];
        [gen impactOccurred];
    }
    if (!g_currentKaraokeItems || idx < 0 || idx >= (NSInteger)g_currentKaraokeItems.count) return;

    double seekTarget = g_currentKaraokeItems[idx].time;
    if (seekTarget < 0) return;

    // 1. Перематываем наш аудиоплеер (если играет кастомный трек / файл с устройства)
    safeSeekPlayerToTime(seekTarget);

    // 2. Синхронно перематываем системный ползунок таймлайна и движок Spotify
    seekSpotifyPlayback(seekTarget, g_currentTrackDuration);

    // 3. Мгновенная визуальная подсветка нажатой строки белым цветом
    g_lastActiveKaraokeIdx = idx;
    [UIView animateWithDuration:0.15 animations:^{
        for (NSUInteger i = 0; i < g_currentKaraokeLabels.count; i++) {
            UILabel *lbl = g_currentKaraokeLabels[i];
            if ((NSInteger)i == idx) {
                lbl.textColor = [UIColor whiteColor];
                lbl.alpha = 1.0f;
                lbl.transform = CGAffineTransformMakeScale(1.02f, 1.02f);
            } else {
                lbl.textColor = [UIColor colorWithWhite:0.0 alpha:0.65];
                lbl.alpha = 0.85f;
                lbl.transform = CGAffineTransformIdentity;
            }
        }
    }];

    // 4. Плавное центрирование нажатой строки на экране (~35% от верха)
    UIScrollView *sv = (UIScrollView *)view.superview.superview;
    if (![sv isKindOfClass:[UIScrollView class]]) {
        sv = (UIScrollView *)view.superview;
    }
    if ([sv isKindOfClass:[UIScrollView class]]) {
        CGFloat targetY = view.frame.origin.y - (sv.bounds.size.height * 0.35);
        if (targetY < 0) targetY = 0;
        CGFloat maxY = sv.contentSize.height - sv.bounds.size.height;
        if (maxY < 0) maxY = 0;
        if (targetY > maxY) targetY = maxY;
        [sv setContentOffset:CGPointMake(0, targetY) animated:YES];
    }
}

- (void)onKaraokeLineTapped:(UITapGestureRecognizer *)gesture {
    UIView *view = gesture.view;
    NSInteger idx = view.tag;
    [self handleSeekToLyricIndex:idx inView:view];
}

- (void)onKaraokeContainerTapped:(UITapGestureRecognizer *)gesture {
    CGPoint pt = [gesture locationInView:gesture.view];
    for (NSUInteger i = 0; i < g_currentKaraokeLabels.count; i++) {
        UILabel *lbl = g_currentKaraokeLabels[i];
        if (pt.y >= lbl.frame.origin.y - 14.0 && pt.y <= CGRectGetMaxY(lbl.frame) + 14.0) {
            [self handleSeekToLyricIndex:i inView:lbl];
            return;
        }
    }
}
@end

static NSArray<AntiCensorLyricItem *> *parseLyricsForTrack(NSString *rawLrcOrText, double duration) {
    if (!rawLrcOrText || rawLrcOrText.length == 0) return nil;
    NSMutableArray<AntiCensorLyricItem *> *items = [NSMutableArray array];

    NSArray *rawLines = [rawLrcOrText componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"\\[(\\d{1,2}):(\\d{2})(?:\\.(\\d{1,3}))?\\](.*)" options:0 error:nil];

    BOOL anyTimestamp = NO;
    for (NSString *line in rawLines) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (trimmed.length == 0) continue;
        NSTextCheckingResult *match = [regex firstMatchInString:trimmed options:0 range:NSMakeRange(0, trimmed.length)];
        if (match && match.numberOfRanges >= 5) {
            int m = [[trimmed substringWithRange:[match rangeAtIndex:1]] intValue];
            int s = [[trimmed substringWithRange:[match rangeAtIndex:2]] intValue];
            double ms = 0.0;
            NSRange msRange = [match rangeAtIndex:3];
            if (msRange.location != NSNotFound) {
                NSString *msStr = [trimmed substringWithRange:msRange];
                ms = [msStr doubleValue] / (msStr.length == 3 ? 1000.0 : 100.0);
            }
            double t = (m * 60.0) + s + ms;
            NSString *content = [trimmed substringWithRange:[match rangeAtIndex:4]];
            content = [content stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            if (content.length > 0) {
                AntiCensorLyricItem *it = [[AntiCensorLyricItem alloc] init];
                it.time = t;
                it.text = content;
                [items addObject:it];
                anyTimestamp = YES;
            }
        } else {
            AntiCensorLyricItem *it = [[AntiCensorLyricItem alloc] init];
            it.time = -1.0;
            it.text = trimmed;
            [items addObject:it];
        }
    }

    if (items.count == 0) return nil;

    if (!anyTimestamp) {
        double dur = duration > 10.0 ? duration : 180.0;
        double intro = MIN(8.0, dur * 0.05);
        double outro = MAX(dur - 10.0, dur * 0.92);
        double span = MAX(10.0, outro - intro);
        double totalChars = 0;
        for (AntiCensorLyricItem *it in items) {
            totalChars += MAX(10, it.text.length);
        }
        double accum = 0;
        for (NSUInteger i = 0; i < items.count; i++) {
            items[i].time = intro + (span * (accum / totalChars));
            accum += MAX(10, items[i].text.length);
        }
    }

    [items sortUsingComparator:^NSComparisonResult(AntiCensorLyricItem *a, AntiCensorLyricItem *b) {
        if (a.time < b.time) return NSOrderedAscending;
        if (a.time > b.time) return NSOrderedDescending;
        return NSOrderedSame;
    }];

    return items;
}

static UILabel *findUnsyncedLyricsIndicatorLabel(UIView *root) {
    if (!root || root.hidden || root.alpha < 0.05) return nil;
    if (root.tag == KARAOKE_CONTAINER_TAG) return nil;

    if ([root isKindOfClass:[UILabel class]]) {
        UILabel *lbl = (UILabel *)root;
        NSString *txt = [lbl.text lowercaseString];
        if ([txt containsString:@"синхронизация текста"] ||
            [txt containsString:@"lyrics aren't synced"] ||
            [txt containsString:@"lyrics are not synced"]) {
            return lbl;
        }
    }
    for (UIView *sub in root.subviews) {
        UILabel *found = findUnsyncedLyricsIndicatorLabel(sub);
        if (found) return found;
    }
    return nil;
}

static UIScrollView *findLyricsScrollViewInView(UIView *win) {
    if (!win || win.hidden || win.alpha < 0.05) return nil;
    if (win.tag == KARAOKE_CONTAINER_TAG) return nil;

    // 1. Быстрый возврат, если контейнер караоке уже смонтирован в активном видимом скролле
    UIView *existing = [win viewWithTag:KARAOKE_CONTAINER_TAG];
    if (existing && [existing.superview isKindOfClass:[UIScrollView class]]) {
        UIScrollView *p = (UIScrollView *)existing.superview;
        if (!p.hidden && p.alpha > 0.05 && p.window != nil) {
            return p;
        }
    }

    // 2. Ищем по тексту-индикатору "Синхронизация текста..."
    UILabel *indicator = findUnsyncedLyricsIndicatorLabel(win);
    if (indicator && !indicator.hidden && indicator.window != nil) {
        // Поднимаемся по цепочке родителей индикатора и проверяем subviews на наличие UIScrollView экрана текста
        UIView *cur = indicator.superview;
        while (cur && cur != win) {
            for (UIView *sub in cur.subviews) {
                if ([sub isKindOfClass:[UIScrollView class]] && sub.tag != KARAOKE_CONTAINER_TAG) {
                    UIScrollView *sv = (UIScrollView *)sub;
                    if (sv.bounds.size.height > 250.0 && sv.bounds.size.width > 250.0) {
                        return sv;
                    }
                }
            }
            cur = cur.superview;
        }

        // Поиск в окне индикатора среди скроллов БЕЗ большой обложки альбома (чтобы исключить экран плеера)
        UIWindow *w = indicator.window ?: (UIWindow *)win;
        NSMutableArray *queue = [NSMutableArray arrayWithObject:w];
        UIScrollView *bestSV = nil;
        CGFloat maxH = 0;
        while (queue.count > 0) {
            UIView *v = queue.firstObject;
            [queue removeObjectAtIndex:0];
            if ([v isKindOfClass:[UIScrollView class]] && v.tag != KARAOKE_CONTAINER_TAG) {
                UIScrollView *sv = (UIScrollView *)v;
                BOOL hasLargeArt = NO;
                for (UIView *s in sv.subviews) {
                    if ([s isKindOfClass:[UIImageView class]] && s.bounds.size.width > 200.0) {
                        hasLargeArt = YES; break;
                    }
                }
                if (!hasLargeArt && sv.bounds.size.height > 250.0 && sv.bounds.size.width > 250.0) {
                    if (sv.bounds.size.height > maxH) {
                        maxH = sv.bounds.size.height;
                        bestSV = sv;
                    }
                }
            }
            [queue addObjectsFromArray:v.subviews];
        }
        if (bestSV) return bestSV;
    }

    // 3. Если у трека есть сохранённый пользователем текст — ищем открытый полноэкранный экран текста
    NSString *userLyrics = getLyricsForTrack(currentActiveSpotifyTrackURI, currentActiveSpotifyTrackTitle, currentActiveSpotifyTrackArtist);
    if (userLyrics && userLyrics.length > 0) {
        NSMutableArray *queue = [NSMutableArray arrayWithObject:win];
        while (queue.count > 0) {
            UIView *v = queue.firstObject;
            [queue removeObjectAtIndex:0];
            if ([v isKindOfClass:[UIScrollView class]] && v.tag != KARAOKE_CONTAINER_TAG) {
                UIScrollView *sv = (UIScrollView *)v;
                BOOL hasLargeArt = NO;
                for (UIView *s in sv.subviews) {
                    if ([s isKindOfClass:[UIImageView class]] && s.bounds.size.width > 200.0) {
                        hasLargeArt = YES; break;
                    }
                }
                if (!hasLargeArt && sv.bounds.size.height > 400.0 && sv.bounds.size.width > [UIScreen mainScreen].bounds.size.width * 0.8) {
                    return sv;
                }
            }
            [queue addObjectsFromArray:v.subviews];
        }
    }

    return nil;
}

static void collectAllLyricsLines(UIView *root, NSMutableArray<NSString *> *outLines) {
    if (!root || root.tag == KARAOKE_CONTAINER_TAG) return;

    NSMutableArray<NSDictionary *> *labelEntries = [NSMutableArray array];
    NSMutableArray *q = [NSMutableArray arrayWithObject:root];
    while (q.count > 0) {
        UIView *v = q.firstObject;
        [q removeObjectAtIndex:0];
        if (v.tag == KARAOKE_CONTAINER_TAG) continue;
        if ([v isKindOfClass:[UILabel class]] || [v isKindOfClass:[UITextView class]]) {
            NSString *t = nil;
            if ([v isKindOfClass:[UILabel class]]) {
                t = [((UILabel *)v).text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            } else if ([v isKindOfClass:[UITextView class]]) {
                t = [((UITextView *)v).text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            }
            if (t.length > 0) {
                NSString *low = [t lowercaseString];
                if (![low containsString:@"синхронизация"] &&
                    ![low containsString:@"lyrics aren't"] &&
                    ![low containsString:@"поделиться"] &&
                    ![low containsString:@"плейлист"] &&
                    ![low containsString:@"любимые"]) {
                    CGRect rect = [v convertRect:v.bounds toView:root];
                    [labelEntries addObject:@{
                        @"y": @(rect.origin.y),
                        @"text": t
                    }];
                }
            }
        }
        [q addObjectsFromArray:v.subviews];
    }

    // Сортируем строго сверху вниз по оси Y!
    [labelEntries sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"y"] compare:b[@"y"]];
    }];

    for (NSDictionary *d in labelEntries) {
        NSString *t = d[@"text"];
        NSArray *lines = [t componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
        for (NSString *ln in lines) {
            NSString *s = [ln stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (s.length > 0) {
                [outLines addObject:s];
            }
        }
    }
}

static void hideUnsyncedLyricsIndicator(UIView *viewOrWin) {
    UIWindow *win = [viewOrWin isKindOfClass:[UIWindow class]] ? (UIWindow *)viewOrWin : viewOrWin.window;
    if (!win) win = getKeyAppWindow();
    UILabel *indicator = findUnsyncedLyricsIndicatorLabel(win ?: viewOrWin);
    if (indicator) {
        indicator.hidden = YES;
        indicator.alpha = 0.0f;
        if (indicator.superview && indicator.superview != win) {
            indicator.superview.hidden = YES;
            indicator.superview.alpha = 0.0f;
        }
    }
}

static void checkAndSyncLyricsOnScreen(void) {
    NSArray *windows = [UIApplication sharedApplication].windows;
    for (UIWindow *win in windows) {
        if (!win || win.hidden) continue;

        // 1. Ищем ТОЛЬКО специализированный экран слов песни (никаких главных экранов!)
        UIScrollView *scrollView = findLyricsScrollViewInView(win);
        if (!scrollView) {
            UIView *existing = [win viewWithTag:KARAOKE_CONTAINER_TAG];
            if (existing && [existing.superview isKindOfClass:[UIScrollView class]]) {
                scrollView = (UIScrollView *)existing.superview;
            }
        }

        if (!scrollView) continue;

        // 2. Текущее время и трек
        double currentTime = 0.0;
        double duration = 0.0;
        if (ourAudioPlayer && ourAudioPlayer.currentItem) {
            currentTime = CMTimeGetSeconds(ourAudioPlayer.currentTime);
            CMTime d = ourAudioPlayer.currentItem.duration;
            if (CMTIME_IS_VALID(d) && !CMTIME_IS_INDEFINITE(d)) {
                duration = CMTimeGetSeconds(d);
            }
        }
        if (duration <= 1.0) {
            currentTime = getCurrentSpotifyPreciseTime();
            MPNowPlayingInfoCenter *center = [MPNowPlayingInfoCenter defaultCenter];
            NSNumber *durNum = center.nowPlayingInfo[MPMediaItemPropertyPlaybackDuration];
            if (durNum && [durNum doubleValue] > 0) {
                duration = [durNum doubleValue];
            }
        }
        if (isnan(currentTime) || currentTime < 0) currentTime = 0;
        if (isnan(duration) || duration <= 10.0) duration = 180.0;
        g_currentTrackDuration = duration;

        NSString *trackKey = currentActiveSpotifyTrackURI ?: (currentActiveSpotifyTrackTitle ?: @"");

        // 3. Полноэкранный караоке вид (в точности как нативный Spotify "двашки")
        UIView *existingContainer = [scrollView viewWithTag:KARAOKE_CONTAINER_TAG];
        if (existingContainer) {
            [scrollView bringSubviewToFront:existingContainer];
            for (UIView *sub in scrollView.subviews) {
                if (sub != existingContainer && sub.tag != KARAOKE_CONTAINER_TAG) {
                    sub.hidden = YES;
                    sub.userInteractionEnabled = NO;
                }
            }
        }

        if (!existingContainer || ![trackKey isEqualToString:g_currentKaraokeTrackKey]) {
            NSString *lyricsStr = getLyricsForTrack(currentActiveSpotifyTrackURI, currentActiveSpotifyTrackTitle, currentActiveSpotifyTrackArtist);
            if (!lyricsStr || lyricsStr.length == 0) {
                NSMutableArray<NSString *> *lines = [NSMutableArray array];
                collectAllLyricsLines(scrollView, lines);
                if (lines.count > 0) {
                    lyricsStr = [lines componentsJoinedByString:@"\n"];
                    // НЕ сохраняем автоматически в постоянную базу saveLyricsForTrack, чтобы не портить другие треки
                }
            }

            // Прячем серую плашку "Синхронизация текста..."
            hideUnsyncedLyricsIndicator(win);

            if (lyricsStr && lyricsStr.length > 0) {
                g_currentKaraokeTrackKey = trackKey;
                g_lastActiveKaraokeIdx = -1;
                g_currentKaraokeItems = parseLyricsForTrack(lyricsStr, duration);

                if (existingContainer) {
                    [existingContainer removeFromSuperview];
                }

                CGFloat viewW = scrollView.bounds.size.width;
                if (viewW < 200) viewW = [UIScreen mainScreen].bounds.size.width;
                CGFloat padX = 24.0;
                CGFloat contentW = viewW - (padX * 2);
                CGFloat curY = 40.0;

                UIView *container = [[UIView alloc] initWithFrame:CGRectMake(0, 0, viewW, 1000)];
                container.tag = KARAOKE_CONTAINER_TAG;
                container.userInteractionEnabled = YES;

                UITapGestureRecognizer *contTap = [[UITapGestureRecognizer alloc] initWithTarget:[AntiCensorTapHandler sharedHandler] action:@selector(onKaraokeContainerTapped:)];
                contTap.delegate = [AntiCensorTapHandler sharedHandler];
                contTap.cancelsTouchesInView = NO;
                [container addGestureRecognizer:contTap];

                g_currentKaraokeLabels = [NSMutableArray array];

                for (NSUInteger i = 0; i < g_currentKaraokeItems.count; i++) {
                    AntiCensorLyricItem *it = g_currentKaraokeItems[i];
                    UILabel *lbl = [[UILabel alloc] init];
                    lbl.numberOfLines = 0;
                    // Жирный крупный шрифт 25pt, в точности как на скрине нативного караоке Spotify
                    lbl.font = [UIFont systemFontOfSize:25.0 weight:UIFontWeightHeavy];
                    // Неактивные строки — тёмные/полупрозрачные черные (как на примере "двашки")
                    lbl.textColor = [UIColor colorWithWhite:0.0 alpha:0.65];
                    lbl.alpha = 0.85f;
                    lbl.text = it.text;
                    lbl.userInteractionEnabled = YES;
                    lbl.tag = i;

                    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:[AntiCensorTapHandler sharedHandler] action:@selector(onKaraokeLineTapped:)];
                    tap.delegate = [AntiCensorTapHandler sharedHandler];
                    tap.cancelsTouchesInView = NO;
                    [lbl addGestureRecognizer:tap];

                    CGSize maxS = CGSizeMake(contentW, CGFLOAT_MAX);
                    CGRect b = [it.text boundingRectWithSize:maxS
                                                     options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading
                                                  attributes:@{NSFontAttributeName: lbl.font}
                                                     context:nil];
                    CGFloat lineH = ceil(b.size.height);
                    lbl.frame = CGRectMake(padX, curY, contentW, lineH);
                    [container addSubview:lbl];
                    [g_currentKaraokeLabels addObject:lbl];

                    curY += lineH + 24.0;
                }

                curY += 280.0; // отступ снизу для комфортного скролла последних строк
                container.frame = CGRectMake(0, 0, viewW, curY);
                [scrollView addSubview:container];
                [scrollView bringSubviewToFront:container];
                scrollView.delaysContentTouches = NO;
                scrollView.canCancelContentTouches = YES;
                scrollView.contentSize = CGSizeMake(viewW, curY);

                // Отключаем клики на устаревших элементах Spotify под нашим контейнером
                for (UIView *sub in scrollView.subviews) {
                    if (sub != container && sub.tag != KARAOKE_CONTAINER_TAG) {
                        sub.hidden = YES;
                        sub.userInteractionEnabled = NO;
                    }
                }
            }
        }

        // 5. Актуализация активной строки караоке в реальном времени
        if (g_currentKaraokeItems && g_currentKaraokeLabels.count == g_currentKaraokeItems.count) {
            NSInteger activeIdx = 0;
            for (NSInteger i = 0; i < (NSInteger)g_currentKaraokeItems.count; i++) {
                if (currentTime >= g_currentKaraokeItems[i].time) {
                    activeIdx = i;
                } else {
                    break;
                }
            }

            if (activeIdx != g_lastActiveKaraokeIdx) {
                g_lastActiveKaraokeIdx = activeIdx;
                [UIView animateWithDuration:0.2 animations:^{
                    for (NSUInteger i = 0; i < g_currentKaraokeLabels.count; i++) {
                        UILabel *lbl = g_currentKaraokeLabels[i];
                        if ((NSInteger)i == activeIdx) {
                            lbl.textColor = [UIColor whiteColor]; // Активная поющаяся строка — чистый белый!
                            lbl.alpha = 1.0f;
                            lbl.transform = CGAffineTransformMakeScale(1.02f, 1.02f);
                        } else {
                            lbl.textColor = [UIColor colorWithWhite:0.0 alpha:0.65]; // Неактивные — темные
                            lbl.alpha = 0.85f;
                            lbl.transform = CGAffineTransformIdentity;
                        }
                    }
                }];
            }

            // Плавное следование скролла за активной строкой (по центру экрана ~35%)
            if (!scrollView.isDragging && !scrollView.isDecelerating && activeIdx < (NSInteger)g_currentKaraokeLabels.count) {
                UILabel *actLbl = g_currentKaraokeLabels[activeIdx];
                CGFloat targetY = actLbl.frame.origin.y - (scrollView.bounds.size.height * 0.35);
                if (targetY < 0) targetY = 0;
                CGFloat maxY = scrollView.contentSize.height - scrollView.bounds.size.height;
                if (maxY < 0) maxY = 0;
                if (targetY > maxY) targetY = maxY;
                if (fabs(scrollView.contentOffset.y - targetY) > 10.0) {
                    [scrollView setContentOffset:CGPointMake(0, targetY) animated:YES];
                }
            }
        }

        break;
    }
}

static void cleanupRogueBanners(void);

static void onPeriodicSyncCheck(NSTimer *timer) {
    // 0. Инжектим кнопку в боковое меню профиля только при его открытии
    checkAndInjectProfileDrawerButton();

    // 0.1 Очищаем любые случайные баннеры с основных вкладок (Главная, Медиатека, Поиск)
    cleanupRogueBanners();

    // 1. Проверяем и синхронизируем текст песни в реальном времени (караоке)
    checkAndSyncLyricsOnScreen();

    // 2. Периодический фоновый Cloud Sync каждые 60 секунд (каждые 240 тиков по 0.25 сек)
    static int s_cloudSyncCounter = 0;
    if (++s_cloudSyncCounter >= 240) {
        s_cloudSyncCounter = 0;
        syncPullFromCloud(nil);
    }

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

    // Синхронизируем системную позицию с нашим плеером, чтобы таймлайн Spotify следовал за звуком
    double ourTime = CMTimeGetSeconds(ourAudioPlayer.currentTime);
    if (!isnan(ourTime) && ourTime >= 0) {
        g_spotifyLastReportedPosition = ourTime;
        g_spotifyLastReportedTimestamp = [NSDate timeIntervalSinceReferenceDate];
    }

    // Гарантируем, что громкость нашего плеера всегда 1.0, когда трек должен играть и не идет плавный переход (crossfade)
    if (ourAudioPlayer && !g_isPlayerFading && ourAudioPlayer.volume < 0.95f) {
        ourAudioPlayer.volume = 1.0f;
    }

    if (ourAudioPlayer.timeControlStatus != AVPlayerTimeControlStatusPlaying && isSpotifyCurrentlyPlaying && !g_isPlayerSeeking) {
        [ourAudioPlayer play];
    }

    // Синхронизируем Dynamic Island и экран блокировки (раз в секунду)
    static NSTimeInterval lastNPUpdate = 0;
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (now - lastNPUpdate >= 1.0) {
        lastNPUpdate = now;
        updateNowPlayingCenter();
    }
}

static void playStreamUrl(NSURL *streamUrl, NSString *trackKey, double initialPosition) {
    if (!streamUrl || ![trackKey isEqualToString:currentPlayingKey]) {
        return;
    }

    isMutingSpotify = YES;
    applyMuteStateToAllUnits(); // Spotify в полном мьюте

    // КРИТИЧНО ДЛЯ AIRPODS, DYNAMIC ISLAND И LOCK SCREEN:
    AVAudioSession *session = [AVAudioSession sharedInstance];
    [session setCategory:AVAudioSessionCategoryPlayback
             withOptions:AVAudioSessionCategoryOptionMixWithOthers |
                         AVAudioSessionCategoryOptionAllowBluetooth |
                         AVAudioSessionCategoryOptionAllowAirPlay
                   error:nil];
    [session setActive:YES error:nil];

    AVPlayerItem *item = [AVPlayerItem playerItemWithURL:streamUrl];
    if (!g_playerObserver) {
        g_playerObserver = [[AntiCensorPlayerObserver alloc] init];
    }

    // Плавный переход (Crossfade): если уже играл трек, мягко затухаем его, а не обрываем звук
    if (ourAudioPlayer) {
        if (isObservingPlayerItem) {
            @try { [ourAudioPlayer.currentItem removeObserver:g_playerObserver forKeyPath:@"status" context:kStatusObserverContext]; } @catch (id ex) {}
            isObservingPlayerItem = NO;
        }
        AVPlayer *oldP = ourAudioPlayer;
        fadeOutPlayer(oldP, 1.5);
        ourAudioPlayer = nil;
    }

    [item addObserver:g_playerObserver forKeyPath:@"status" options:NSKeyValueObservingOptionNew context:kStatusObserverContext];
    isObservingPlayerItem = YES;
    ourAudioPlayer = [AVPlayer playerWithPlayerItem:item];
    if (@available(iOS 10.0, *)) {
        ourAudioPlayer.automaticallyWaitsToMinimizeStalling = NO;
    }

    if (initialPosition > 0.5) {
        [ourAudioPlayer seekToTime:CMTimeMakeWithSeconds(initialPosition, NSEC_PER_SEC)];
    }

    if (isSpotifyCurrentlyPlaying) {
        fadeInPlayer(ourAudioPlayer, 1.2);
        updateNowPlayingCenter();
    }
}

static void startReplacementAudio(NSString *trackKey, NSString *scUrl, double initialPosition) {
    if (!scUrl || scUrl.length == 0) return;

    if ([trackKey isEqualToString:currentPlayingKey] && [scUrl isEqualToString:currentPlayingUrl] && (ourAudioPlayer != nil || isReplacementLoading)) {
        return;
    }

    currentPlayingKey = trackKey;
    currentPlayingUrl = scUrl;
    isReplacementLoading = YES;

    // Spotify глушим для заменяющего трека: Цензурный трек НИКОГДА не звучит!
    isMutingSpotify = YES;
    applyMuteStateToAllUnits();

    // Быстрый кэш (0 мс задержки!)
    if (!g_streamCache) {
        g_streamCache = [NSMutableDictionary dictionary];
    }
    if (!g_streamCacheTimestamps) {
        g_streamCacheTimestamps = [NSMutableDictionary dictionary];
    }

    NSURL *cached = g_streamCache[scUrl];
    NSNumber *cachedTs = g_streamCacheTimestamps[scUrl];
    if (cached) {
        if (!cachedTs || ([NSDate timeIntervalSinceReferenceDate] - [cachedTs doubleValue] < 180.0)) {
            isReplacementLoading = NO;
            playStreamUrl(cached, trackKey, initialPosition);
            return;
        } else {
            [g_streamCache removeObjectForKey:scUrl];
            [g_streamCacheTimestamps removeObjectForKey:scUrl];
        }
    }

    // Разрешаем в фоне
    resolveSoundCloudUrl(scUrl, ^(NSURL *streamUrl) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (![trackKey isEqualToString:currentPlayingKey]) {
                return;
            }
            isReplacementLoading = NO;
            if (!streamUrl) {
                NSLog(@"[AntiCensor] Stream URL not resolved for %@. Spotify stays 100%% MUTED!", trackKey);
                isMutingSpotify = YES;
                applyMuteStateToAllUnits();
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
            lastKnownSpotifyPosition = 0.0;
            lastSpotifyPositionTimestamp = [NSDate timeIntervalSinceReferenceDate];
            g_currentKaraokeItems = nil;
            g_currentKaraokeLabels = nil;
            g_lastActiveKaraokeIdx = -1;
            g_currentKaraokeTrackKey = nil;
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
            static NSTimeInterval s_lastManualSeek = 0;
            NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
            if (diff > 3.5 && (now - s_lastManualSeek > 2.0)) {
                s_lastManualSeek = now;
                safeSeekPlayerToTime(position);
            }
        }
        if (ourAudioPlayer.timeControlStatus != AVPlayerTimeControlStatusPlaying && isSpotifyCurrentlyPlaying && !g_isPlayerSeeking) {
            [ourAudioPlayer play];
        }
    }
}

static void custom_setNowPlayingInfo(id target, SEL _cmd, NSDictionary *info) {
    if (orig_setNowPlayingInfo) orig_setNowPlayingInfo(target, _cmd, info);
    if (g_isUpdatingNowPlaying) return; // СТРОГАЯ ЗАЩИТА: Не обрабатываем собственные вызовы!
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

        NSDictionary *allOverrides = loadAllOverrides();
        NSDictionary *allLyrics = loadAllLyrics();

        if (allOverrides.count == 0 && allLyrics.count == 0) {
            UIAlertController *emptyAlert = [UIAlertController alertControllerWithTitle:@"AntiCensor Память"
                                                                                message:@"Сохранённых замен и текстов пока нет."
                                                                         preferredStyle:UIAlertControllerStyleAlert];
            [emptyAlert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
            [topVC presentViewController:emptyAlert animated:YES completion:nil];
            return;
        }

        UIAlertController *manageAlert = [UIAlertController alertControllerWithTitle:@"База данных AntiCensor"
                                                                             message:[NSString stringWithFormat:@"Замен треков: %lu | Текстов: %lu", (unsigned long)allOverrides.count, (unsigned long)allLyrics.count]
                                                                      preferredStyle:UIAlertControllerStyleActionSheet];

        UIAlertAction *cloudSyncAction = [UIAlertAction actionWithTitle:@"🌐 Синхронизировать всё с ПК" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull a) {
            syncPullFromCloud(^(BOOL success, NSUInteger count) {
                NSString *resMsg = success ? [NSString stringWithFormat:@"Синхронизация завершена!\nОбновлено элементов: %lu", (unsigned long)count] : @"Ошибка подключения к облаку.";
                UIAlertController *resAlert = [UIAlertController alertControllerWithTitle:@"🌐 AntiCensor Cloud" message:resMsg preferredStyle:UIAlertControllerStyleAlert];
                [resAlert addAction:[UIAlertAction actionWithTitle:@"ОК" style:UIAlertActionStyleDefault handler:nil]];
                [topVC presentViewController:resAlert animated:YES completion:nil];
            });
        }];
        [manageAlert addAction:cloudSyncAction];

        for (NSString *key in allOverrides) {
            NSString *val = allOverrides[key];
            NSString *icon = [val hasPrefix:@"local://"] ? @"📁" : @"☁️";
            NSString *rowTitle = [NSString stringWithFormat:@"%@ Удалить замену: %@", icon, key];
            [manageAlert addAction:[UIAlertAction actionWithTitle:rowTitle style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
                saveOverride(key, nil);
                if ([normalizeKey(currentActiveSpotifyTrackTitle) isEqualToString:key] ||
                    [normalizeKey(currentActiveSpotifyTrackURI) isEqualToString:key]) {
                    stopReplacementAudio();
                }
            }]];
        }

        for (NSString *key in allLyrics) {
            NSString *rowTitle = [NSString stringWithFormat:@"📝 Удалить текст: %@", key];
            [manageAlert addAction:[UIAlertAction actionWithTitle:rowTitle style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
                saveLyricsForTrack(key, nil);
            }]];
        }

        [manageAlert addAction:[UIAlertAction actionWithTitle:@"Очистить ВСЕ замены" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
            persistOverrides(@{});
            if (g_streamCache) [g_streamCache removeAllObjects];
            stopReplacementAudio();
        }]];

        [manageAlert addAction:[UIAlertAction actionWithTitle:@"Закрыть" style:UIAlertActionStyleCancel handler:nil]];

        if (manageAlert.popoverPresentationController) {
            manageAlert.popoverPresentationController.sourceView = topVC.view;
            manageAlert.popoverPresentationController.sourceRect = CGRectMake(topVC.view.bounds.size.width / 2.0, topVC.view.bounds.size.height / 2.0, 1, 1);
            manageAlert.popoverPresentationController.permittedArrowDirections = 0;
        }

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

    NSString *effectiveUri = self.targetURI;
    NSString *effectiveTitle = self.targetTitle ?: self.displayTrack;
    NSString *effectiveArtist = self.targetArtist ?: @"";

    if (effectiveUri && [effectiveUri hasPrefix:@"spotify:track:"] && effectiveUri.length > 15) {
        saveOverride(effectiveUri, storedUrl);
    }
    if (self.displayTrack.length > 1) {
        saveOverride(self.displayTrack, storedUrl);
    }
    if (effectiveTitle && effectiveTitle.length > 1) {
        saveOverride(effectiveTitle, storedUrl);
        if (effectiveArtist.length > 1) {
            saveOverride([NSString stringWithFormat:@"%@ - %@", effectiveArtist, effectiveTitle], storedUrl);
        }
    }

    // Привязываем переменные текущего воспроизведения, чтобы караоке и таймер были связаны с этим треком
    if (effectiveTitle.length > 0) currentActiveSpotifyTrackTitle = effectiveTitle;
    if (effectiveArtist.length > 0) currentActiveSpotifyTrackArtist = effectiveArtist;
    if (effectiveUri.length > 0) currentActiveSpotifyTrackURI = effectiveUri;
    currentPlayingKey = effectiveUri ?: effectiveTitle;
    currentPlayingUrl = nil;

    // Сбрасываем кэш караоке, чтобы текст мгновенно обновился и связался с аудио
    g_currentKaraokeTrackKey = nil;
    g_lastActiveKaraokeIdx = -1;

    // Пытаемся извлечь встроенный текст из локального аудиофайла (ID3 / USLT)
    NSString *existingLyrics = getLyricsForTrack(effectiveUri, effectiveTitle, effectiveArtist);
    if (!existingLyrics || existingLyrics.length == 0) {
        AVURLAsset *asset = [AVURLAsset assetWithURL:[NSURL fileURLWithPath:destPath]];
        NSString *embedded = [asset lyrics];
        if (embedded && embedded.length > 10) {
            saveLyricsForTrack(effectiveUri ?: effectiveTitle, embedded);
            if (effectiveTitle) saveLyricsForTrack(effectiveTitle, embedded);
        }
    }

    // Мгновенный плавный запуск локального аудиофайла
    startReplacementAudio(currentPlayingKey, storedUrl, 0.0);

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

static void showSoundCloudInputPrompt(NSString *uri, NSString *title, NSString *artist, NSString *displayTrack, NSString *existingUrl) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *topVC = getTopViewController();
        if (!topVC) return;

        NSString *disp = (displayTrack && displayTrack.length > 0) ? displayTrack : @"Текущий трек";
        NSString *initialText = (existingUrl && ![existingUrl hasPrefix:@"local://"]) ? existingUrl : @"";

        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"☁️ AntiCensor SoundCloud"
                                                                        message:[NSString stringWithFormat:@"Трек: %@\n\nВведите ссылку на трек из SoundCloud:", disp]
                                                                 preferredStyle:UIAlertControllerStyleAlert];

        [alert addTextFieldWithConfigurationHandler:^(UITextField * _Nonnull tf) {
            tf.placeholder = @"https://soundcloud.com/...";
            tf.text = initialText;
            tf.clearButtonMode = UITextFieldViewModeWhileEditing;
        }];

        UIAlertAction *pasteAction = [UIAlertAction actionWithTitle:@"📋 Вставить из буфера" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
            NSString *clip = [UIPasteboard generalPasteboard].string;
            if (clip && clip.length > 0) {
                showSoundCloudInputPrompt(uri, title, artist, displayTrack, [clip stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]);
            } else {
                showSoundCloudInputPrompt(uri, title, artist, displayTrack, initialText);
            }
        }];

        UIAlertAction *saveAction = [UIAlertAction actionWithTitle:@"✓ Применить замену" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
            NSString *inputUrl = [alert.textFields.firstObject.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (inputUrl.length > 0) {
                resolveSoundCloudUrl(inputUrl, ^(NSURL *u) {});

                if (uri && [uri hasPrefix:@"spotify:track:"] && uri.length > 15) {
                    saveOverride(uri, inputUrl);
                }
                if (disp.length > 1) {
                    saveOverride(disp, inputUrl);
                }
                if (title && title.length > 1) {
                    saveOverride(title, inputUrl);
                    if (artist && artist.length > 1) {
                        saveOverride([NSString stringWithFormat:@"%@ - %@", artist, title], inputUrl);
                    }
                }
                startReplacementAudio(uri ?: (title ?: disp), inputUrl, getCurrentSpotifyPreciseTime());
            }
        }];

        UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:@"Отмена" style:UIAlertActionStyleCancel handler:nil];

        [alert addAction:pasteAction];
        [alert addAction:saveAction];
        [alert addAction:cancelAction];

        [topVC presentViewController:alert animated:YES completion:nil];
    });
}

static void showLyricsEditPrompt(NSString *uri, NSString *title, NSString *artist, NSString *displayTrack, NSString *existingLyrics) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *top = getTopViewController();
        if (!top) return;

        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"📝 Текст песни"
                                                                        message:@"Вставьте текст песни (обычный или LRC с таймингами [00:15.20]):"
                                                                 preferredStyle:UIAlertControllerStyleAlert];

        [alert addTextFieldWithConfigurationHandler:^(UITextField * _Nonnull tf) {
            tf.placeholder = @"Текст песни...";
            tf.text = existingLyrics ?: @"";
            tf.clearButtonMode = UITextFieldViewModeWhileEditing;
        }];

        UIAlertAction *pasteBtn = [UIAlertAction actionWithTitle:@"📋 Вставить из буфера" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull a) {
            NSString *clip = [UIPasteboard generalPasteboard].string;
            if (clip && clip.length > 0) {
                showLyricsEditPrompt(uri, title, artist, displayTrack, clip);
            }
        }];

        UIAlertAction *saveBtn = [UIAlertAction actionWithTitle:@"💾 Сохранить и синхронизировать" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull a) {
            NSString *text = alert.textFields.firstObject.text;
            if (text && text.length > 0) {
                if (uri && [uri hasPrefix:@"spotify:track:"]) saveLyricsForTrack(uri, text);
                if (title && title.length > 0) saveLyricsForTrack(title, text);
                if (artist && title) saveLyricsForTrack([NSString stringWithFormat:@"%@ - %@", artist, title], text);
                if (displayTrack && displayTrack.length > 0) saveLyricsForTrack(displayTrack, text);
                g_currentKaraokeTrackKey = nil;
            }
        }];

        UIAlertAction *cancelBtn = [UIAlertAction actionWithTitle:@"Отмена" style:UIAlertActionStyleCancel handler:nil];

        [alert addAction:pasteBtn];
        [alert addAction:saveBtn];
        [alert addAction:cancelBtn];

        [top presentViewController:alert animated:YES completion:nil];
    });
}

static void showLyricsManagerDialog(NSString *targetURI, NSString *targetTitle, NSString *targetArtist, NSString *displayTrack) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *top = getTopViewController();
        if (!top) return;

        NSString *title = (targetTitle.length > 0) ? targetTitle : currentActiveSpotifyTrackTitle;
        NSString *uri = (targetURI.length > 0) ? targetURI : currentActiveSpotifyTrackURI;
        NSString *artist = (targetArtist.length > 0) ? targetArtist : currentActiveSpotifyTrackArtist;
        NSString *disp = (displayTrack.length > 0) ? displayTrack : ((artist.length > 0 && title.length > 0) ? [NSString stringWithFormat:@"%@ — %@", artist, title] : (title ?: @"Текущий трек"));

        NSString *currentLyrics = getLyricsForTrack(uri, title, artist);
        BOOL hasLyrics = (currentLyrics && currentLyrics.length > 0);

        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"📝 Управление текстом (AntiCensor)"
                                                                        message:[NSString stringWithFormat:@"Трек: %@\n%@", disp, hasLyrics ? @"\n✓ Для трека сохранён персональный текст." : @"\nТекст пока не сохранён вручную. Если у трека в Spotify текст не синхронизирован, AntiCensor автоматически синхронизирует его на экране в реальном времени."]
                                                                 preferredStyle:UIAlertControllerStyleAlert];

        UIAlertAction *editAction = [UIAlertAction actionWithTitle:hasLyrics ? @"✏️ Редактировать текст" : @"➕ Добавить / Вставить текст"
                                                             style:UIAlertActionStyleDefault
                                                           handler:^(UIAlertAction * _Nonnull a) {
            showLyricsEditPrompt(uri, title, artist, disp, currentLyrics);
        }];

        UIAlertAction *syncAction = [UIAlertAction actionWithTitle:@"🌐 Загрузить текст с ПК (Облако)"
                                                             style:UIAlertActionStyleDefault
                                                           handler:^(UIAlertAction * _Nonnull a) {
            syncPullFromCloud(^(BOOL success, NSUInteger count) {
                NSString *msg = success ? [NSString stringWithFormat:@"Синхронизация завершена!\nОбновлено записей: %lu", (unsigned long)count] : @"Не удалось связаться с облаком.";
                UIAlertController *res = [UIAlertController alertControllerWithTitle:@"🌐 AntiCensor Cloud" message:msg preferredStyle:UIAlertControllerStyleAlert];
                [res addAction:[UIAlertAction actionWithTitle:@"ОК" style:UIAlertActionStyleDefault handler:nil]];
                [top presentViewController:res animated:YES completion:nil];
            });
        }];

        UIAlertAction *deleteAction = nil;
        if (hasLyrics) {
            deleteAction = [UIAlertAction actionWithTitle:@"🗑️ Удалить этот текст" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull a) {
                saveLyricsForTrack(uri ?: (title ?: disp), nil);
                if (title && title.length > 0) saveLyricsForTrack(title, nil);
                if (artist && title) saveLyricsForTrack([NSString stringWithFormat:@"%@ - %@", artist, title], nil);
                g_currentKaraokeTrackKey = nil;
            }];
        }

        UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:@"Закрыть" style:UIAlertActionStyleCancel handler:nil];

        [alert addAction:editAction];
        [alert addAction:syncAction];
        if (deleteAction) [alert addAction:deleteAction];
        [alert addAction:cancelAction];

        [top presentViewController:alert animated:YES completion:nil];
    });
}

static void showAntiCensorMainOptionsDialog(NSString *targetURI, NSString *targetTitle, NSString *targetArtist) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *topVC = getTopViewController();
        if (!topVC) return;

        NSString *title = (targetTitle && targetTitle.length > 0) ? targetTitle : currentActiveSpotifyTrackTitle;
        NSString *uri = (targetURI && targetURI.length > 0) ? targetURI : currentActiveSpotifyTrackURI;
        NSString *artist = (targetArtist && targetArtist.length > 0) ? targetArtist : currentActiveSpotifyTrackArtist;

        NSString *displayTrack = @"";
        if (title && title.length > 0) {
            displayTrack = (artist && artist.length > 0) ? [NSString stringWithFormat:@"%@ — %@", artist, title] : title;
        } else if (uri && uri.length > 0) {
            displayTrack = uri;
        } else {
            displayTrack = @"Текущий трек Spotify";
        }

        NSString *existingUrl = getOverrideForTrack(uri, title, artist) ?: @"";
        NSString *existingLyrics = getLyricsForTrack(uri, title, artist) ?: @"";

        NSString *statusDesc = @"🎵 Звук: Оригинал Spotify";
        if ([existingUrl hasPrefix:@"local://"]) {
            statusDesc = @"📁 Звук: Заменено файлом с устройства";
        } else if (existingUrl.length > 0) {
            statusDesc = @"☁️ Звук: Заменено на SoundCloud";
        }
        if (existingLyrics.length > 0) {
            statusDesc = [statusDesc stringByAppendingString:@"\n📝 Текст: Добавлен свой текст"];
        }

        UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"⚡ AntiCensor"
                                                                       message:[NSString stringWithFormat:@"%@\n\n%@", displayTrack, statusDesc]
                                                                preferredStyle:UIAlertControllerStyleActionSheet];

        // 1. Файл с устройства
        UIAlertAction *localFileAction = [UIAlertAction actionWithTitle:@"📁 Загрузить файл с устройства (MP3/M4A/WAV)"
                                                                  style:UIAlertActionStyleDefault
                                                                handler:^(UIAlertAction * _Nonnull a) {
            openLocalAudioPicker(uri, title, artist, displayTrack);
        }];

        // 2. SoundCloud
        UIAlertAction *scAction = [UIAlertAction actionWithTitle:@"☁️ Заменить на трек из SoundCloud"
                                                           style:UIAlertActionStyleDefault
                                                         handler:^(UIAlertAction * _Nonnull a) {
            showSoundCloudInputPrompt(uri, title, artist, displayTrack, existingUrl);
        }];

        // 3. Текст песни
        UIAlertAction *lyricsAction = [UIAlertAction actionWithTitle:@"📝 Текст песни (Синхронизация / Добавить свой)"
                                                               style:UIAlertActionStyleDefault
                                                             handler:^(UIAlertAction * _Nonnull a) {
            showLyricsManagerDialog(uri, title, artist, displayTrack);
        }];

        // 4. Синхронизация с ПК
        UIAlertAction *cloudSyncAction = [UIAlertAction actionWithTitle:@"🌐 Синхронизировать с ПК прямо сейчас"
                                                                 style:UIAlertActionStyleDefault
                                                               handler:^(UIAlertAction * _Nonnull a) {
            syncPullFromCloud(^(BOOL success, NSUInteger count) {
                NSString *resMsg = success ? [NSString stringWithFormat:@"Синхронизация успешна!\nОбновлено элементов: %lu", (unsigned long)count] : @"Не удалось подключиться к облаку.\nПроверьте интернет.";
                UIAlertController *resAlert = [UIAlertController alertControllerWithTitle:@"🌐 AntiCensor Cloud" message:resMsg preferredStyle:UIAlertControllerStyleAlert];
                [resAlert addAction:[UIAlertAction actionWithTitle:@"Отлично" style:UIAlertActionStyleDefault handler:nil]];
                [topVC presentViewController:resAlert animated:YES completion:nil];
            });
        }];

        // 5. Удалить замену (если есть)
        UIAlertAction *removeOverrideAction = nil;
        if (existingUrl.length > 0) {
            removeOverrideAction = [UIAlertAction actionWithTitle:@"🗑️ Сбросить замену звука (Оригинал Spotify)"
                                                            style:UIAlertActionStyleDestructive
                                                          handler:^(UIAlertAction * _Nonnull a) {
                if (uri && uri.length > 5) saveOverride(uri, nil);
                if (displayTrack.length > 1) saveOverride(displayTrack, nil);
                if (title && title.length > 1) saveOverride(title, nil);
                if (artist && title) saveOverride([NSString stringWithFormat:@"%@ - %@", artist, title], nil);
                stopReplacementAudio();
            }];
        }

        // 6. Список всех замен
        UIAlertAction *manageAction = [UIAlertAction actionWithTitle:@"⚙️ Список всех замен и текстов"
                                                               style:UIAlertActionStyleDefault
                                                             handler:^(UIAlertAction * _Nonnull a) {
            showManageAllTracksDialog();
        }];

        UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:@"Отмена" style:UIAlertActionStyleCancel handler:nil];

        [sheet addAction:localFileAction];
        [sheet addAction:scAction];
        [sheet addAction:lyricsAction];
        [sheet addAction:cloudSyncAction];
        if (removeOverrideAction) [sheet addAction:removeOverrideAction];
        [sheet addAction:manageAction];
        [sheet addAction:cancelAction];

        if (sheet.popoverPresentationController) {
            sheet.popoverPresentationController.sourceView = topVC.view;
            sheet.popoverPresentationController.sourceRect = CGRectMake(topVC.view.bounds.size.width / 2.0, topVC.view.bounds.size.height / 2.0, 1, 1);
            sheet.popoverPresentationController.permittedArrowDirections = 0;
        }

        [topVC presentViewController:sheet animated:YES completion:nil];
    });
}

static void showReplacementDialogWithContext(NSString *targetURI, NSString *targetTitle, NSString *targetArtist) {
    showAntiCensorMainOptionsDialog(targetURI, targetTitle, targetArtist);
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

static void cleanupRogueBanners(void) {
    NSArray *windows = [UIApplication sharedApplication].windows;
    for (UIWindow *win in windows) {
        if (!win) continue;
        NSMutableArray *queue = [NSMutableArray arrayWithObject:win];
        while (queue.count > 0) {
            UIView *v = queue.firstObject;
            [queue removeObjectAtIndex:0];
            if (v.tag == 778899) {
                // Если этот баннер не внутри модально представленного контекстного контроллера — немедленно удаляем!
                UIResponder *resp = v.nextResponder;
                while (resp && ![resp isKindOfClass:[UIViewController class]]) {
                    resp = resp.nextResponder;
                }
                if ([resp isKindOfClass:[UIViewController class]]) {
                    UIViewController *vc = (UIViewController *)resp;
                    if (!vc.presentingViewController || [vc isKindOfClass:[UITabBarController class]] || [vc isKindOfClass:[UINavigationController class]]) {
                        [v removeFromSuperview];
                        continue;
                    }
                } else {
                    [v removeFromSuperview];
                    continue;
                }
            }
            [queue addObjectsFromArray:v.subviews];
        }
    }
}

static void checkAndInjectProfileDrawerButton(void) {
    NSArray *windows = [UIApplication sharedApplication].windows;
    for (UIWindow *win in windows) {
        if (!win || win.hidden) continue;

        UILabel *targetLabel = findDrawerLabel(win);
        if (!targetLabel) continue;

        // Если метка скрыта, прозрачна или вне экрана — меню закрыто
        CGRect inWin = [targetLabel convertRect:targetLabel.bounds toView:nil];
        if (targetLabel.hidden || targetLabel.alpha < 0.2 || !targetLabel.window || inWin.origin.x < -10.0 || inWin.origin.x > win.bounds.size.width * 0.85) {
            UIView *existingBtn = [win viewWithTag:889911];
            if (existingBtn) existingBtn.hidden = YES;
            continue;
        }

        // Находим контейнер бокового меню профиля (шириной ~75-85% экрана)
        UIView *drawerView = targetLabel;
        while (drawerView.superview && drawerView.superview != win) {
            if (drawerView.superview.bounds.size.width < win.bounds.size.width * 0.95 &&
                drawerView.superview.bounds.size.width > 150.0) {
                drawerView = drawerView.superview;
            } else {
                break;
            }
        }
        if (!drawerView) drawerView = targetLabel.superview ?: win;

        CGRect lblInDrawer = [targetLabel.superview convertRect:targetLabel.frame toView:drawerView];
        CGFloat btnY = CGRectGetMaxY(lblInDrawer) + 16.0;
        CGFloat width = drawerView.bounds.size.width;
        if (width < 100 || width > win.bounds.size.width) width = win.bounds.size.width * 0.78;

        if (btnY + 48.0 > drawerView.bounds.size.height && drawerView.bounds.size.height > 100) {
            btnY = MAX(10.0, CGRectGetMinY(lblInDrawer) - 56.0);
        }

        UIButton *btn = [drawerView viewWithTag:889911];
        if (!btn) {
            btn = createDrawerButton(CGRectMake(16.0, btnY, width - 32.0, 48.0));
            [drawerView addSubview:btn];
        } else {
            btn.frame = CGRectMake(16.0, btnY, width - 32.0, 48.0);
            btn.hidden = NO;
        }
        [drawerView bringSubviewToFront:btn];
    }
}

static UIView *createContextMenuActionRow(CGRect frame, NSString *uri, NSString *title, NSString *artist, UIViewController *sheetVC) {
    CGFloat rowH = 54.0;
    CGFloat rowW = (frame.size.width > 50) ? frame.size.width : [UIScreen mainScreen].bounds.size.width;
    UIView *row = [[UIView alloc] initWithFrame:CGRectMake(frame.origin.x, frame.origin.y, rowW, rowH)];
    row.tag = 778899;
    row.backgroundColor = [UIColor colorWithRed:0.11 green:0.11 blue:0.11 alpha:1.0];
    row.clipsToBounds = YES;
    row.userInteractionEnabled = YES;

    UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
    btn.frame = row.bounds;
    btn.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [btn addTarget:sheetVC action:@selector(anticensor_onContextMenuButtonTap:) forControlEvents:UIControlEventTouchUpInside];

    UIImageView *iconView = [[UIImageView alloc] initWithFrame:CGRectMake(18, (rowH - 24) / 2.0, 24, 24)];
    iconView.contentMode = UIViewContentModeScaleAspectFit;
    iconView.tintColor = [UIColor colorWithRed:0.18 green:0.85 blue:0.42 alpha:1.0];
    if (@available(iOS 13.0, *)) {
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:19 weight:UIImageSymbolWeightMedium];
        iconView.image = [UIImage systemImageNamed:@"bolt.fill" withConfiguration:cfg];
    }

    CGFloat textLeft = 56.0;
    CGFloat textWidth = rowW - textLeft - 16.0;

    UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(textLeft, 8, textWidth, 22)];
    titleLabel.text = @"⚡ AntiCensor (Замена / Текст)";
    titleLabel.textColor = [UIColor whiteColor];
    titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];

    UILabel *subLabel = [[UILabel alloc] initWithFrame:CGRectMake(textLeft, 30, textWidth, 16)];
    subLabel.text = @"Выбрать версию или текст песни";
    subLabel.textColor = [UIColor colorWithWhite:0.65 alpha:1.0];
    subLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];

    [row addSubview:iconView];
    [row addSubview:titleLabel];
    [row addSubview:subLabel];
    [row addSubview:btn];

    if (uri) objc_setAssociatedObject(btn, &kAntiCensorUriKey, uri, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (title) objc_setAssociatedObject(btn, &kAntiCensorTitleKey, title, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (artist) objc_setAssociatedObject(btn, &kAntiCensorArtistKey, artist, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    return row;
}

static void addAntiCensorRowToContextMenu(UIViewController *sheetVC) {
    if (!sheetVC || !sheetVC.isViewLoaded) return;
    // СТРОЖАЙШАЯ ЗАЩИТА: контекстное меню ВСЕГДА модально представлено поверх другого экрана!
    if (!sheetVC.presentingViewController) return;
    if ([sheetVC isKindOfClass:[UITabBarController class]] || [sheetVC isKindOfClass:[UINavigationController class]]) return;

    UIView *container = sheetVC.view;
    if (!container || !container.window) return;

    if ([container viewWithTag:778899]) return;

    // Проверяем, является ли это меню контекстным меню трека Spotify
    BOOL isContextMenu = NO;
    NSMutableArray *chkQueue = [NSMutableArray arrayWithObject:container];
    while (chkQueue.count > 0) {
        UIView *v = chkQueue.firstObject;
        [chkQueue removeObjectAtIndex:0];
        if ([v isKindOfClass:[UILabel class]]) {
            NSString *txt = [((UILabel *)v).text lowercaseString];
            if ([txt containsString:@"добавить в очередь"] || [txt containsString:@"add to queue"] ||
                [txt containsString:@"перейти в очередь"] || [txt containsString:@"go to queue"] ||
                [txt containsString:@"исключить из музыкальных"] || [txt containsString:@"exclude from your taste"] ||
                ([txt containsString:@"поделиться"] && [txt containsString:@"плейлист"])) {
                isContextMenu = YES;
                break;
            }
        }
        [chkQueue addObjectsFromArray:v.subviews];
    }
    if (!isContextMenu) return;

    NSString *extractedURI = nil;
    NSString *extractedTitle = nil;
    NSString *extractedArtist = nil;
    extractBestTrackInfo(sheetVC, &extractedURI, &extractedTitle, &extractedArtist);

    // 1. Ищем текстовую метку "Поделиться" / "Share" для вставки прямо над ней
    UILabel *shareLabel = nil;
    NSMutableArray *queue = [NSMutableArray arrayWithObject:container];
    while (queue.count > 0) {
        UIView *v = queue.firstObject;
        [queue removeObjectAtIndex:0];
        if ([v isKindOfClass:[UILabel class]]) {
            UILabel *lbl = (UILabel *)v;
            NSString *txt = [lbl.text lowercaseString];
            if ([txt containsString:@"поделиться"] || [txt isEqualToString:@"share"]) {
                shareLabel = lbl;
                break;
            }
        }
        [queue addObjectsFromArray:v.subviews];
    }

    if (shareLabel) {
        UIView *rowView = shareLabel;
        while (rowView.superview && rowView.superview != container && rowView.frame.size.height < 40.0) {
            rowView = rowView.superview;
        }
        UIView *parent = rowView.superview ?: container;
        if ([parent isKindOfClass:[UIStackView class]]) {
            UIStackView *sv = (UIStackView *)parent;
            NSUInteger idx = [sv.arrangedSubviews indexOfObject:rowView];
            UIView *actionRow = createContextMenuActionRow(CGRectZero, extractedURI, extractedTitle, extractedArtist, sheetVC);
            actionRow.tag = 778899;
            actionRow.translatesAutoresizingMaskIntoConstraints = NO;
            [sv insertArrangedSubview:actionRow atIndex:idx];
            [NSLayoutConstraint activateConstraints:@[
                [actionRow.heightAnchor constraintEqualToConstant:54.0],
                [actionRow.widthAnchor constraintEqualToAnchor:sv.widthAnchor]
            ]];
            return;
        } else {
            CGRect rowFrame = [rowView convertRect:rowView.bounds toView:parent];
            CGFloat targetY = rowFrame.origin.y;
            CGFloat targetW = parent.bounds.size.width > 50 ? parent.bounds.size.width : container.bounds.size.width;
            UIView *actionRow = createContextMenuActionRow(CGRectMake(0, targetY, targetW, 54.0), extractedURI, extractedTitle, extractedArtist, sheetVC);
            actionRow.tag = 778899;

            // Сдвигаем rowView ("Поделиться") и все следующие элементы вниз ровно на 54 пункта, чтобы избежать наложения!
            for (UIView *sub in parent.subviews) {
                if (sub != actionRow && sub.frame.origin.y >= targetY - 2.0) {
                    sub.frame = CGRectOffset(sub.frame, 0, 54.0);
                }
            }

            [parent addSubview:actionRow];

            if ([parent isKindOfClass:[UIScrollView class]]) {
                UIScrollView *sv = (UIScrollView *)parent;
                sv.contentSize = CGSizeMake(sv.contentSize.width, sv.contentSize.height + 54.0);
            }
            if ([parent.superview isKindOfClass:[UIScrollView class]]) {
                UIScrollView *sv = (UIScrollView *)parent.superview;
                sv.contentSize = CGSizeMake(sv.contentSize.width, sv.contentSize.height + 54.0);
            }
            return;
        }
    }

    // 2. Если "Поделиться" не найден, проверяем UITableView
    UITableView *targetTableView = nil;
    queue = [NSMutableArray arrayWithObject:container];
    while (queue.count > 0) {
        UIView *v = queue.firstObject;
        [queue removeObjectAtIndex:0];
        if ([v isKindOfClass:[UITableView class]]) {
            targetTableView = (UITableView *)v;
            break;
        }
        [queue addObjectsFromArray:v.subviews];
    }

    if (targetTableView) {
        CGFloat rowW = targetTableView.bounds.size.width;
        if (rowW < 100) rowW = container.bounds.size.width;

        UIView *existingHeader = targetTableView.tableHeaderView;
        if (existingHeader) {
            if ([existingHeader viewWithTag:778899]) return;
            existingHeader.clipsToBounds = NO;
            CGFloat existH = existingHeader.bounds.size.height;
            if (existH < 50.0) existH = 70.0;

            CGRect hFrame = existingHeader.frame;
            hFrame.size.height = existH + 54.0;
            existingHeader.frame = hFrame;

            UIView *actionRow = createContextMenuActionRow(CGRectMake(0, existH, rowW, 54.0), extractedURI, extractedTitle, extractedArtist, sheetVC);
            actionRow.tag = 778899;
            actionRow.autoresizingMask = UIViewAutoresizingFlexibleWidth;
            [existingHeader addSubview:actionRow];

            targetTableView.tableHeaderView = existingHeader;
            return;
        } else {
            UIView *newHeader = [[UIView alloc] initWithFrame:CGRectMake(0, 0, rowW, 54.0)];
            newHeader.tag = 778899;
            newHeader.backgroundColor = [UIColor clearColor];
            UIView *actionRow = createContextMenuActionRow(CGRectMake(0, 0, rowW, 54.0), extractedURI, extractedTitle, extractedArtist, sheetVC);
            actionRow.tag = 778899;
            [newHeader addSubview:actionRow];
            targetTableView.tableHeaderView = newHeader;
            return;
        }
    }
}

static void anticensor_onContextMenuButtonTap(UIViewController *callerVC, SEL _cmd, UIButton *sender) {
    NSString *uri = objc_getAssociatedObject(sender, &kAntiCensorUriKey);
    NSString *title = objc_getAssociatedObject(sender, &kAntiCensorTitleKey);
    NSString *artist = objc_getAssociatedObject(sender, &kAntiCensorArtistKey);
    [callerVC dismissViewControllerAnimated:YES completion:^{
        showAntiCensorMainOptionsDialog(uri, title, artist);
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
            [alert addAction:[UIAlertAction actionWithTitle:@"⚡ AntiCensor (Замена / Текст)"
                                                      style:UIAlertActionStyleDefault
                                                    handler:^(UIAlertAction * _Nonnull a) {
                showAntiCensorMainOptionsDialog(uri, nil, nil);
            }]];
        }
    } else {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            addAntiCensorRowToContextMenu(vcToPresent);
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            addAntiCensorRowToContextMenu(vcToPresent);
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.80 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            addAntiCensorRowToContextMenu(vcToPresent);
        });
    }

    if (orig_presentViewController) {
        orig_presentViewController(callerVC, _cmd, vcToPresent, animated, completion);
    }
}

static UIMenu * (*orig_menuWithTitle_image_identifier_options_children)(id, SEL, NSString *, UIImage *, id, NSUInteger, NSArray *);
static UIMenu * custom_menuWithTitle_image_identifier_options_children(id target, SEL _cmd, NSString *title, UIImage *image, id identifier, NSUInteger options, NSArray *children) {
    if (children && children.count > 0) {
        UIAction *action = [UIAction actionWithTitle:@"⚡ AntiCensor (Замена / Текст)"
                                               image:[UIImage systemImageNamed:@"bolt.fill"]
                                          identifier:@"com.anticensor.action"
                                             handler:^(UIAction *a) {
            showAntiCensorMainOptionsDialog(nil, title, nil);
        }];
        children = [@[action] arrayByAddingObjectsFromArray:children];
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

static void cleanupPoisonedLyricsDatabase(void) {
    NSMutableDictionary *lyricsDict = loadAllLyrics();
    if (!lyricsDict || lyricsDict.count == 0) return;
    NSMutableArray *toRemove = [NSMutableArray array];
    for (NSString *key in lyricsDict) {
        NSString *val = [lyricsDict[key] description];
        // Если текст ошибочно сохранён от другой песни (например, "эстетику" под "сборник хуйни")
        if ([key containsString:@"сборник"] && [val containsString:@"эстетику"]) {
            [toRemove addObject:key];
        }
        if ([key containsString:@"кишлак"] && [val containsString:@"эстетику"] && ![key containsString:@"эстетик"]) {
            [toRemove addObject:key];
        }
    }
    if (toRemove.count > 0) {
        for (NSString *k in toRemove) {
            [lyricsDict removeObjectForKey:k];
        }
        persistLyrics(lyricsDict);
    }
}

__attribute__((constructor)) static void initAntiCensor(void) {
    cleanupPoisonedLyricsDatabase();
    NSLog(@"[AntiCensor] Initializing AntiCensor iOS Tweak v4.0 (Cloud Sync + Native Context Menu + Lyrics Karaoke)...");

    // Инициализация аудиосессии для гарантированной поддержки Dynamic Island и экрана блокировки
    AVAudioSession *session = [AVAudioSession sharedInstance];
    [session setCategory:AVAudioSessionCategoryPlayback
             withOptions:AVAudioSessionCategoryOptionAllowBluetooth | AVAudioSessionCategoryOptionAllowAirPlay
                   error:nil];
    [session setActive:YES error:nil];

    // Уведомления прерывания аудио (звонки, будильники, Siri) и восстановления
    [[NSNotificationCenter defaultCenter] addObserverForName:AVAudioSessionInterruptionNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification * _Nonnull note) {
        NSNumber *type = note.userInfo[AVAudioSessionInterruptionTypeKey];
        if ([type unsignedIntegerValue] == AVAudioSessionInterruptionTypeEnded) {
            NSNumber *opt = note.userInfo[AVAudioSessionInterruptionOptionKey];
            if ([opt unsignedIntegerValue] & AVAudioSessionInterruptionOptionShouldResume) {
                if (ourAudioPlayer && isSpotifyCurrentlyPlaying) {
                    [ourAudioPlayer play];
                }
            }
        }
    }];

    // Восстановление после буферизации
    [[NSNotificationCenter defaultCenter] addObserverForName:AVPlayerItemPlaybackStalledNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification * _Nonnull note) {
        if (ourAudioPlayer && isSpotifyCurrentlyPlaying) {
            [ourAudioPlayer play];
        }
    }];

    // ОДНОКРАТНАЯ ПОЛНАЯ ОЧИСТКА БАЗЫ ДАННЫХ ОТ СТАРЫХ МУСОРНЫХ КЛЮЧЕЙ (WIPE CORRUPTED CACHE)
    BOOL isCleanedV35 = [[NSUserDefaults standardUserDefaults] boolForKey:DEFAULTS_VERSION_KEY];
    if (!isCleanedV35) {
        [[NSFileManager defaultManager] removeItemAtPath:getStorageFilePath() error:nil];
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:DEFAULTS_OVERRIDES_KEY];
        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:DEFAULTS_VERSION_KEY];
        [[NSUserDefaults standardUserDefaults] synchronize];
    }

    // v4.0: Скрытие плавающей пилюли
    BOOL isCleanedV40 = [[NSUserDefaults standardUserDefaults] boolForKey:DEFAULTS_VERSION_KEY_40];
    if (!isCleanedV40) {
        [[NSUserDefaults standardUserDefaults] setBool:NO forKey:DEFAULTS_HIDE_BANNER_KEY];
        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:DEFAULTS_HIDE_FLOAT_KEY];
        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:DEFAULTS_VERSION_KEY_40];
        [[NSUserDefaults standardUserDefaults] synchronize];
    }

    // 1. CoreAudio мьютер микшера Spotify с полным перехватом AudioUnitSetParameter и очисткой Dispose
    struct rebinding audioRebind[4];
    audioRebind[0].name = "AudioOutputUnitStart";
    audioRebind[0].replacement = (void *)custom_AudioOutputUnitStart;
    audioRebind[0].replaced = (void **)&orig_AudioOutputUnitStart;

    audioRebind[1].name = "AudioUnitInitialize";
    audioRebind[1].replacement = (void *)custom_AudioUnitInitialize;
    audioRebind[1].replaced = (void **)&orig_AudioUnitInitialize;

    audioRebind[2].name = "AudioUnitSetParameter";
    audioRebind[2].replacement = (void *)custom_AudioUnitSetParameter;
    audioRebind[2].replaced = (void **)&orig_AudioUnitSetParameter;

    audioRebind[3].name = "AudioComponentInstanceDispose";
    audioRebind[3].replacement = (void *)custom_AudioComponentInstanceDispose;
    audioRebind[3].replaced = (void **)&orig_AudioComponentInstanceDispose;

    ac_rebind_symbols(audioRebind, 4);

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

    // 5. Первоначальный Cloud Sync с ПК при старте
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        syncPullFromCloud(nil);
    });

    // 6. Фоновый высокочастотный таймер синхронизации и смены треков (каждые 250 мс)
    dispatch_async(dispatch_get_main_queue(), ^{
        periodicSyncTimer = [NSTimer scheduledTimerWithTimeInterval:0.25 repeats:YES block:^(NSTimer * _Nonnull timer) {
            onPeriodicSyncCheck(timer);
        }];
        [[NSRunLoop mainRunLoop] addTimer:periodicSyncTimer forMode:NSRunLoopCommonModes];
    });
}
