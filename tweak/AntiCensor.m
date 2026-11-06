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
#define NOWPLAYING_LYRICS_CARD_TAG 0xAC999

static void cleanupRogueBanners(void);
@class AntiCensorNowPlayingViewController;
static void presentAlbumNowPlayingScreen(int trackIdx);

static void setupFloatingBadge(void);
static void checkAndInjectProfileDrawerButton(void);
static void checkAndSyncLyricsOnScreen(void);
static void addAntiCensorRowToContextMenu(UIViewController *sheetVC);
static void syncPullFromCloud(void (^completion)(BOOL success, NSUInteger count));
static void performAntiCensorCloudSync(void);
static void syncPushToCloud(NSString *key, NSString *value, BOOL isLyrics);
static void showAntiCensorMainOptionsDialog(NSString *targetURI, NSString *targetTitle, NSString *targetArtist);
static void showSoundCloudInputPrompt(NSString *uri, NSString *title, NSString *artist, NSString *displayTrack, NSString *existingUrl);
static void showLyricsManagerDialog(NSString *targetURI, NSString *targetTitle, NSString *targetArtist, NSString *displayTrack);
static void showLyricsEditPrompt(NSString *uri, NSString *title, NSString *artist, NSString *displayTrack, NSString *existingLyrics);
static NSString *getLyricsForTrack(NSString *uri, NSString *title, NSString *artist);
static void saveLyricsForTrack(NSString *trackKey, NSString *lyrics);
static void persistLyrics(NSDictionary *dict);
static void startReplacementAudio(NSString *trackKey, NSString *scUrl, double initialPosition);
static void stopReplacementAudio(void);
static void safeSeekPlayerToTime(double targetSeconds);
static NSURLSessionDataTask *(*orig_dataTaskWithRequest_completionHandler)(id, SEL, NSURLRequest *, void (^)(NSData *, NSURLResponse *, NSError *)) = NULL;
static NSURLSessionDataTask *custom_dataTaskWithRequest_completionHandler(id self, SEL _cmd, NSURLRequest *request, void (^completionHandler)(NSData *, NSURLResponse *, NSError *));
static void (*orig_setNowPlayingInfo)(id, SEL, NSDictionary *) = NULL;


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


static NSString *const kAlbumUrls[12] = {
    @"https://spotik-in4b.onrender.com/audio/one_week_record.mp3",
    @"https://spotik-in4b.onrender.com/audio/needforspeed.mp3",
    @"https://spotik-in4b.onrender.com/audio/senpa1.mp3",
    @"https://spotik-in4b.onrender.com/audio/deyti.mp3",
    @"https://spotik-in4b.onrender.com/audio/krysha.mp3",
    @"https://spotik-in4b.onrender.com/audio/tvari.mp3",
    @"https://spotik-in4b.onrender.com/audio/ya_ne_vinovat.mp3",
    @"https://spotik-in4b.onrender.com/audio/fuckit.mp3",
    @"https://spotik-in4b.onrender.com/audio/shake_your_ass.mp3",
    @"https://spotik-in4b.onrender.com/audio/son.mp3",
    @"https://spotik-in4b.onrender.com/audio/notime.mp3",
    @"https://spotik-in4b.onrender.com/audio/eyforiya.mp3"
};

static NSString *const kAlbumTitles[12] = {
    @"ONE WEEK RECORD",
    @"NeedForSpeed",
    @"$enpa1",
    @"ХУЛИЁУ",
    @"КРЫША",
    @"ФАНТАСТИЧЕСКИЕ ТВАРИ - ver.2",
    @"Я не виноват что... Больше",
    @"FUCK IT",
    @"$HAKE YOUR A$$",
    @"МРАЗОТИК",
    @"NOTIME",
    @"ЧЁТНЫЙ - Bonus Track"
};

static NSString *const kAlbumURIs[12] = {
    @"spotify:track:0bzO2aZbO7RN0tl50wsCJz",
    @"spotify:track:0uWNvKc0B1OZsLMzlUzbpD",
    @"spotify:track:4YsCP1lZbeMlCaUT0ONML1",
    @"spotify:track:6DlxijdnCniTi2jRL7xfIO",
    @"spotify:track:49Aozh4YVr0sYx0rkCmNNU",
    @"spotify:track:22m03tWYBVctgdByCu2ohS",
    @"spotify:track:0efigJN3XSbD3xvjDLSCYY",
    @"spotify:track:5JsbDzwDiKjCuNGh7KE2Ja",
    @"spotify:track:1PbTwCZ4vihqw5bZc42Suj",
    @"spotify:track:02NrEHtVoV0QOGxsQHJ0id",
    @"spotify:track:035FY0eysDZd9akX73iKok",
    @"spotify:track:0qitLkJ4pa1MkHQ1sCoJh1"
};

static BOOL s_isAlbumScreenVisible = NO;

static int identifyAlbumTrackIndex(NSString *text) {
    if (!text || ![text isKindOfClass:[NSString class]] || text.length == 0) return -1;
    NSString *clean = text.lowercaseString;
    clean = [clean stringByReplacingOccurrencesOfString:@"ё" withString:@"е"];
    clean = [clean stringByReplacingOccurrencesOfString:@"$" withString:@"s"];
    clean = [clean stringByReplacingOccurrencesOfString:@"." withString:@" "];
    clean = [clean stringByReplacingOccurrencesOfString:@"-" withString:@" "];
    clean = [clean stringByReplacingOccurrencesOfString:@"_" withString:@" "];
    clean = [clean stringByReplacingOccurrencesOfString:@"•" withString:@" "];
    clean = [clean stringByReplacingOccurrencesOfString:@"—" withString:@" "];

    if ([clean containsString:@"one week"]) return 0;
    if ([clean containsString:@"needforspeed"] || [clean containsString:@"need for speed"]) return 1;
    if ([clean containsString:@"senpa1"] || [clean containsString:@"senpai"]) return 2;
    if ([clean containsString:@"хулиеу"] || [clean containsString:@"хули"] || [clean containsString:@"дейти"] || [clean containsString:@"дети"]) return 3;
    if ([clean containsString:@"крыша"] || [clean containsString:@"krysha"]) return 4;
    if ([clean containsString:@"твари"] || [clean containsString:@"фантастические"]) return 5;
    if ([clean containsString:@"не виноват"]) return 6;
    if ([clean containsString:@"fuck it"] || [clean containsString:@"fuckit"]) return 7;
    if ([clean containsString:@"shake your a"]) return 8;
    if ([clean containsString:@"мразотик"] || [clean containsString:@"сон"] || [clean containsString:@"mrazotik"]) return 9;
    if ([clean containsString:@"notime"] || [clean containsString:@"no time"]) return 10;
    if ([clean containsString:@"четный"] || [clean containsString:@"bonus track"] || [clean containsString:@"эйфория"] || [clean containsString:@"eyforiya"]) return 11;

    return -1;
}

static NSDictionary *getBuiltinDefaultOverrides(void) {
    static NSDictionary *builtin = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSMutableDictionary *dict = [NSMutableDictionary dictionary];

        // 12 album tracks: IDs, URIs, full titles and aliases
        for (int i = 0; i < 12; i++) {
            NSString *url = kAlbumUrls[i];
            NSString *uri = kAlbumURIs[i];
            NSString *idStr = [uri stringByReplacingOccurrencesOfString:@"spotify:track:" withString:@""];
            NSString *title = kAlbumTitles[i];

            dict[uri] = url;
            dict[uri.lowercaseString] = url;
            dict[idStr] = url;
            dict[normalizeKey(title)] = url;
            dict[normalizeKey([NSString stringWithFormat:@"m1raontheblock - %@", title])] = url;
        }

        dict[normalizeKey(@"one week record")] = kAlbumUrls[0];
        dict[normalizeKey(@"m1raontheblock - one week record")] = kAlbumUrls[0];

        dict[normalizeKey(@"needforspeed")] = kAlbumUrls[1];
        dict[normalizeKey(@"m1raontheblock - needforspeed")] = kAlbumUrls[1];
        dict[normalizeKey(@"m1raontheblock, vixi - needforspeed")] = kAlbumUrls[1];

        dict[normalizeKey(@"senpa1")] = kAlbumUrls[2];
        dict[normalizeKey(@"$enpa1")] = kAlbumUrls[2];
        dict[normalizeKey(@"m1raontheblock - senpa1")] = kAlbumUrls[2];
        dict[normalizeKey(@"m1raontheblock - $enpa1")] = kAlbumUrls[2];

        dict[normalizeKey(@"хулиёу")] = kAlbumUrls[3];
        dict[normalizeKey(@"хулиеу")] = kAlbumUrls[3];
        dict[normalizeKey(@"дейти")] = kAlbumUrls[3];
        dict[normalizeKey(@"дети")] = kAlbumUrls[3];
        dict[normalizeKey(@"m1raontheblock - хулиёу")] = kAlbumUrls[3];
        dict[normalizeKey(@"m1raontheblock - хулиеу")] = kAlbumUrls[3];
        dict[normalizeKey(@"m1raontheblock - дейти")] = kAlbumUrls[3];
        dict[normalizeKey(@"m1raontheblock - дети")] = kAlbumUrls[3];

        dict[normalizeKey(@"крыша")] = kAlbumUrls[4];
        dict[normalizeKey(@"krysha")] = kAlbumUrls[4];
        dict[normalizeKey(@"m1raontheblock - крыша")] = kAlbumUrls[4];
        dict[normalizeKey(@"m1raontheblock, vixi - крыша")] = kAlbumUrls[4];

        dict[normalizeKey(@"фантастические твари")] = kAlbumUrls[5];
        dict[normalizeKey(@"фантастические твари - ver.2")] = kAlbumUrls[5];
        dict[normalizeKey(@"твари")] = kAlbumUrls[5];
        dict[normalizeKey(@"m1raontheblock - фантастические твари")] = kAlbumUrls[5];
        dict[normalizeKey(@"m1raontheblock - фантастические твари - ver.2")] = kAlbumUrls[5];
        dict[normalizeKey(@"m1raontheblock, vixi, wzcqq - фантастические твари - ver.2")] = kAlbumUrls[5];

        dict[normalizeKey(@"я не виноват")] = kAlbumUrls[6];
        dict[normalizeKey(@"я не виноват что больше")] = kAlbumUrls[6];
        dict[normalizeKey(@"я не виноват что... больше")] = kAlbumUrls[6];
        dict[normalizeKey(@"m1raontheblock - я не виноват")] = kAlbumUrls[6];
        dict[normalizeKey(@"m1raontheblock - я не виноват что больше")] = kAlbumUrls[6];
        dict[normalizeKey(@"m1raontheblock - я не виноват что... больше")] = kAlbumUrls[6];

        dict[normalizeKey(@"fuck it")] = kAlbumUrls[7];
        dict[normalizeKey(@"m1raontheblock - fuck it")] = kAlbumUrls[7];
        dict[normalizeKey(@"m1raontheblock, vixi - fuck it")] = kAlbumUrls[7];

        dict[normalizeKey(@"shake your ass")] = kAlbumUrls[8];
        dict[normalizeKey(@"$hake your a$$")] = kAlbumUrls[8];
        dict[normalizeKey(@"m1raontheblock - shake your ass")] = kAlbumUrls[8];
        dict[normalizeKey(@"m1raontheblock - $hake your a$$")] = kAlbumUrls[8];

        dict[normalizeKey(@"сон")] = kAlbumUrls[9];
        dict[normalizeKey(@"мразотик")] = kAlbumUrls[9];
        dict[normalizeKey(@"m1raontheblock - сон")] = kAlbumUrls[9];
        dict[normalizeKey(@"m1raontheblock - мразотик")] = kAlbumUrls[9];

        dict[normalizeKey(@"notime")] = kAlbumUrls[10];
        dict[normalizeKey(@"m1raontheblock - notime")] = kAlbumUrls[10];

        dict[normalizeKey(@"чётный")] = kAlbumUrls[11];
        dict[normalizeKey(@"четный")] = kAlbumUrls[11];
        dict[normalizeKey(@"чётный - bonus track")] = kAlbumUrls[11];
        dict[normalizeKey(@"четный - bonus track")] = kAlbumUrls[11];
        dict[normalizeKey(@"эйфория")] = kAlbumUrls[11];
        dict[normalizeKey(@"эйфория - bonus track")] = kAlbumUrls[11];
        dict[normalizeKey(@"eyforiya")] = kAlbumUrls[11];
        dict[normalizeKey(@"m1raontheblock - чётный")] = kAlbumUrls[11];
        dict[normalizeKey(@"m1raontheblock - четный")] = kAlbumUrls[11];
        dict[normalizeKey(@"m1raontheblock - чётный - bonus track")] = kAlbumUrls[11];
        dict[normalizeKey(@"m1raontheblock - четный - bonus track")] = kAlbumUrls[11];
        dict[normalizeKey(@"m1raontheblock - эйфория")] = kAlbumUrls[11];
        dict[normalizeKey(@"m1raontheblock - эйфория - bonus track")] = kAlbumUrls[11];

        dict[@"spotify:track:2nryvrkn55a0leqvd2eduq"] = @"https://on.soundcloud.com/toxh9rgoOq8q9SJ5xt";
        dict[@"2nryvrkn55a0leqvd2eduq"] = @"https://on.soundcloud.com/toxh9rgoOq8q9SJ5xt";
        dict[normalizeKey(@"flip phone twerk")] = @"https://on.soundcloud.com/toxh9rgoOq8q9SJ5xt";
        dict[@"spotify:track:1vqfh4jra1tfndlhuan5ne"] = @"https://on.soundcloud.com/YiLKhavIH9btKwTbIf";
        dict[@"1vqfh4jra1tfndlhuan5ne"] = @"https://on.soundcloud.com/YiLKhavIH9btKwTbIf";
        dict[normalizeKey(@"стеклянный")] = @"https://on.soundcloud.com/YiLKhavIH9btKwTbIf";

        builtin = [dict copy];
    });
    return builtin;
}

static NSMutableDictionary *loadAllOverrides(void) {
    NSMutableDictionary *cleaned = [NSMutableDictionary dictionaryWithDictionary:getBuiltinDefaultOverrides()];
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
    BOOL needsPersist = NO;
    if (rawDict && [rawDict isKindOfClass:[NSDictionary class]]) {
        for (NSString *k in rawDict) {
            NSString *normK = normalizeKey(k);
            if (normK.length < 3 ||
                [normK isEqualToString:@"текущий трек spotify"] ||
                [normK isEqualToString:@"выбранный трек"] ||
                [normK isEqualToString:@"текущий трек"] ||
                [normK isEqualToString:@"spotify:track:"] ||
                [normK isEqualToString:@"spotify:"]) {
                needsPersist = YES;
                continue;
            }
            NSString *val = [rawDict[k] description];
            if (val && val.length > 0) {
                // Очистка любых фантомных строк для трека USB
                if ([normK containsString:@"usb"] && ([val containsString:@"разлюблю"] || [val containsString:@"кончатся"])) {
                    needsPersist = YES;
                    continue;
                }
                cleaned[normK] = val;
            }
        }
    }
    if (needsPersist) {
        persistLyrics(cleaned);
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
    // 35 секунд таймаут для гарантированного холодного старта Render.com контейнера
    req.timeoutInterval = 35.0;
    [req setValue:@"no-cache" forHTTPHeaderField:@"Cache-Control"];

    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        if (!data || err) {
            NSLog(@"[AntiCensor] Cloud sync pull failed or timed out: %@", err);
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
            __block NSUInteger totalCount = 0;

            // 1. Оверрайды треков с ПК
            NSDictionary *remoteOverrides = json[@"overrides"];
            if (remoteOverrides && [remoteOverrides isKindOfClass:[NSDictionary class]]) {
                NSMutableDictionary *localOverrides = loadAllOverrides();
                for (NSString *k in remoteOverrides) {
                    NSString *normK = normalizeKey(k);
                    NSString *remoteVal = [remoteOverrides[k] description];
                    if (remoteVal.length > 0) {
                        totalCount++;
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
                        totalCount++;
                        NSString *currTxt = localLyrics[normK];
                        if (![currTxt isEqualToString:remoteTxt]) {
                            localLyrics[normK] = remoteTxt;
                            updatedCount++;
                        }
                    }
                }
                persistLyrics(localLyrics);
            }

            NSLog(@"[AntiCensor] Cloud sync pull SUCCESS, updated: %lu, total items: %lu", (unsigned long)updatedCount, (unsigned long)totalCount);
            if (completion) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    completion(YES, (updatedCount > 0) ? updatedCount : totalCount);
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

    // 1. Strict match by Spotify track URI (e.g. spotify:track:6wLq5...)
    if (uri && [uri hasPrefix:@"spotify:track:"] && uri.length > 15) {
        NSString *val = dict[normalizeKey(uri)];
        if (val && val.length > 0) return val;
    }

    // 2. Strict match by Artist - Title (Must have BOTH artist and title to prevent random collisions!)
    if (title && title.length > 1 && artist && artist.length > 1) {
        NSString *combined = [NSString stringWithFormat:@"%@ - %@", artist, title];
        NSString *val = dict[normalizeKey(combined)];
        if (val && val.length > 0) return val;

        NSString *combined2 = [NSString stringWithFormat:@"%@ • %@", artist, title];
        NSString *val2 = dict[normalizeKey(combined2)];
        if (val2 && val2.length > 0) return val2;
    }

    // Note: NEVER match by naked title alone! Single-word titles caused random lyrics to attach to arbitrary tracks.
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
static NSString *getStreamCacheFilePath(void) {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *docDir = paths.firstObject;
    return [docDir stringByAppendingPathComponent:@"AntiCensor_StreamCache.json"];
}

static void saveStreamCacheToDisk(void) {
    if (!g_streamCache || g_streamCache.count == 0) return;
    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    for (NSString *k in g_streamCache) {
        NSURL *u = g_streamCache[k];
        NSNumber *ts = g_streamCacheTimestamps[k] ?: @([NSDate timeIntervalSinceReferenceDate]);
        if (u && u.absoluteString) {
            dict[k] = @{ @"url": u.absoluteString, @"ts": ts };
        }
    }
    NSData *data = [NSJSONSerialization dataWithJSONObject:dict options:0 error:nil];
    if (data) {
        [data writeToFile:getStreamCacheFilePath() atomically:YES];
    }
}

static void loadStreamCacheFromDisk(void) {
    if (!g_streamCache) g_streamCache = [NSMutableDictionary dictionary];
    if (!g_streamCacheTimestamps) g_streamCacheTimestamps = [NSMutableDictionary dictionary];
    NSString *path = getStreamCacheFilePath();
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) return;
    NSDictionary *dict = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (!dict || ![dict isKindOfClass:[NSDictionary class]]) return;
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    for (NSString *k in dict) {
        NSDictionary *item = dict[k];
        if ([item isKindOfClass:[NSDictionary class]]) {
            NSString *urlStr = item[@"url"];
            NSNumber *ts = item[@"ts"];
            if (urlStr && ts && (now - [ts doubleValue] < 7200.0)) {
                NSURL *u = [NSURL URLWithString:urlStr];
                if (u) {
                    g_streamCache[k] = u;
                    g_streamCacheTimestamps[k] = ts;
                }
            }
        }
    }
}


static void resolveSoundCloudUrl(NSString *rawUrl, void (^completion)(NSURL *streamUrl)) {
    if (!rawUrl || rawUrl.length == 0) {
        if (completion) completion(nil);
        return;
    }

    if (!g_streamCache || !g_streamCacheTimestamps) {
        loadStreamCacheFromDisk();
    }

    // 1. Instant Cache check with 2-hour TTL (7200 seconds)
    NSURL *cached = g_streamCache[rawUrl];
    NSNumber *cachedTs = g_streamCacheTimestamps[rawUrl];
    if (cached) {
        if (!cachedTs || ([NSDate timeIntervalSinceReferenceDate] - [cachedTs doubleValue] < 7200.0)) {
            if (completion) completion(cached);
            return;
        } else {
            [g_streamCache removeObjectForKey:rawUrl];
            [g_streamCacheTimestamps removeObjectForKey:rawUrl];
        }
    }

    // 2. Direct local file check
    if ([rawUrl hasPrefix:@"local://"]) {
        NSString *filename = [rawUrl substringFromIndex:@"local://".length];
        NSString *fullPath = [getLocalAudioDirectoryPath() stringByAppendingPathComponent:filename];
        if ([[NSFileManager defaultManager] fileExistsAtPath:fullPath]) {
            NSURL *u = [NSURL fileURLWithPath:fullPath];
            g_streamCache[rawUrl] = u;
            if (completion) completion(u);
            return;
        }
    }

    if ([rawUrl hasPrefix:@"file://"] || [rawUrl hasPrefix:@"/"]) {
        NSURL *u = [rawUrl hasPrefix:@"file://"] ? [NSURL URLWithString:rawUrl] : [NSURL fileURLWithPath:rawUrl];
        if ([[NSFileManager defaultManager] fileExistsAtPath:u.path]) {
            g_streamCache[rawUrl] = u;
            if (completion) completion(u);
            return;
        }
    }

    // 3. Direct audio URLs (MP3 / M3U8) -> ZERO latency!
    if ([rawUrl hasSuffix:@".mp3"] || [rawUrl hasSuffix:@".m3u8"] || [rawUrl containsString:@"media-streaming.soundcloud.cloud"] || [rawUrl containsString:@"cf-media.sndcdn.com"]) {
        NSURL *u = [NSURL URLWithString:rawUrl];
        g_streamCache[rawUrl] = u;
        g_streamCacheTimestamps[rawUrl] = @([NSDate timeIntervalSinceReferenceDate]);
        if (completion) completion(u);
        return;
    }

    NSString *server = getServerURL();
    NSString *encoded = [rawUrl stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
    NSURL *renderFallback = [NSURL URLWithString:[NSString stringWithFormat:@"%@/sc?url=%@", server, encoded]];

    // 4. SoundCloud API v2 Resolution (Handles on.soundcloud.com natively without extra redirect roundtrip!)
    void (^doApiResolve)(NSString *) = ^(NSString *canonicalUrl) {
        NSString *clean = [canonicalUrl componentsSeparatedByString:@"?"].firstObject;
        NSString *endpoint = [NSString stringWithFormat:@"https://api-v2.soundcloud.com/resolve?url=%@&client_id=%@",
                              [clean stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]],
                              SC_CLIENT_ID];
        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:endpoint]];
        [req setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X)" forHTTPHeaderField:@"User-Agent"];
        [req setTimeoutInterval:2.5];

        [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
            if (!data || err) {
                if (completion) completion(renderFallback);
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
                        [req2 setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X)" forHTTPHeaderField:@"User-Agent"];
                        [req2 setTimeoutInterval:2.5];

                        [[[NSURLSession sharedSession] dataTaskWithRequest:req2 completionHandler:^(NSData *d2, NSURLResponse *r2, NSError *e2) {
                            if (d2 && !e2) {
                                NSDictionary *sJson = [NSJSONSerialization JSONObjectWithData:d2 options:0 error:nil];
                                NSString *media = sJson[@"url"];
                                if (media && media.length > 0) {
                                    NSURL *fastUrl = [NSURL URLWithString:media];
                                    if (fastUrl) {
                                        g_streamCache[rawUrl] = fastUrl;
                                        g_streamCacheTimestamps[rawUrl] = @([NSDate timeIntervalSinceReferenceDate]);
                                        saveStreamCacheToDisk();
                                    }
                                    if (completion) completion(fastUrl);
                                    return;
                                }
                            }
                            if (completion) completion(renderFallback);
                        }] resume];
                        return;
                    }
                }
            } @catch (id ex) {}
            if (completion) completion(renderFallback);
        }] resume];
    };

    doApiResolve(rawUrl);
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
static NSTimeInterval g_lastForegroundOrScreenTransitionTimestamp = 0;

static NSTimer *periodicSyncTimer = nil;
static UIButton *floatingPillButton = nil;

static double getCurrentSpotifyPreciseTime(void) {
    if (ourAudioPlayer && ourAudioPlayer.currentItem) {
        double ourPos = CMTimeGetSeconds(ourAudioPlayer.currentTime);
        if (!isnan(ourPos) && ourPos >= 0) {
            return ourPos;
        }
    }
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

    if (ourAudioPlayer.currentItem) {
        CMTime d = ourAudioPlayer.currentItem.duration;
        if (CMTIME_IS_VALID(d) && !CMTIME_IS_INDEFINITE(d)) {
            double dur = CMTimeGetSeconds(d);
            if (dur > 2.0 && targetSeconds > dur - 1.0) {
                targetSeconds = dur - 1.0;
            }
        }
    }

    g_pendingSeekTarget = targetSeconds;

    if (g_isPlayerSeeking) {
        return;
    }

    g_isPlayerSeeking = YES;
    double toSeek = g_pendingSeekTarget;
    g_pendingSeekTarget = -1.0;

    CMTime seekTime = CMTimeMakeWithSeconds(toSeek, NSEC_PER_SEC);
    CMTime tolerance = CMTimeMakeWithSeconds(0.3, NSEC_PER_SEC);

    // Сторожевой сброс флага перемотки: если плеер зависнет, не теряем отложенный запрос!
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (g_isPlayerSeeking) {
            g_isPlayerSeeking = NO;
            if (g_pendingSeekTarget >= 0) {
                double nextPos = g_pendingSeekTarget;
                g_pendingSeekTarget = -1.0;
                safeSeekPlayerToTime(nextPos);
            }
        }
    });

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
                    if (ourAudioPlayer) {
                        isSpotifyCurrentlyPlaying = YES;
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

    // СТРОГАЯ ОЧИСТКА: Удаляем инжектированную обложку и альбом Coll. of $hiTт, чтобы у других треков Spotify отображалась ИХ родная обложка!
    @try {
        MPNowPlayingInfoCenter *center = [MPNowPlayingInfoCenter defaultCenter];
        NSDictionary *curr = center.nowPlayingInfo;
        if (curr) {
            NSMutableDictionary *info = [curr mutableCopy];
            if ([info[MPMediaItemPropertyAlbumTitle] isEqualToString:@"Coll. of $hiTт (vol. 0.5)"]) {
                [info removeObjectForKey:MPMediaItemPropertyAlbumTitle];
                [info removeObjectForKey:MPMediaItemPropertyArtwork];
                if (orig_setNowPlayingInfo) {
                    orig_setNowPlayingInfo(center, @selector(setNowPlayingInfo:), info);
                } else {
                    center.nowPlayingInfo = info;
                }
            }
        }
    } @catch (id ex) {}
}

static void handleTrackPlaybackUpdate(NSString *title, NSString *artist, NSString *trackURI, double position, BOOL isPlaying, BOOL hasElapsed, BOOL hasRate);


static NSString *const s_albumCoverBase64 =
    @"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"
    @"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"
    @"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"
    @"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"
    @"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"
    @"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"
    @"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"
    @"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"
    @"VDIqyx0fbfb2xbszrL9JNRRqWHC03dLdRp81Tk6p80dm+SOm7VXaXUxItyz9yc50jHc29sVtSr4KNkuxERAaVadU6f3moGy2MT8PqGswQcMWfJCL+zF2v4Wt8KGui0r1upx4FJQ3t96jdKKvTm3kBvmsQ26tt8t1fxO5rPRNbo05bPegvt46yp/mjRSXnRrtADhAAAAAWwx5MnyKvejGi5cpcKlauvYvMATyqJX3TUL3f4b/AILSyUo9rfk3XxtWnUAnqopc8WSMIzcJKMuJUs/qAg3VUgDAAAAAAAAAAAAAAAAAAAAABtGUoNSi3Fq6abTTXldM1ACfqtZLWbJZIr3YxUHkTdckVxujxuXFVSvVEAb2AtyZZZdtaJQioRS4jFdL35dW3du5Wk20kqt9PGv11N2wBJyaSTbdklVt/ldvyMg1um1HpWLFBUi80a5Zxa3bv/FF/MoxV21TdJ3YBrmz9P1uPE809PljjXMpRaS/O6Xa1Ql4NXlhoNZjlJyjleKEU3WknLdKleO6r/B8gYOKAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAADu4dsdPLWahLLKscWnxzrR7Kbpd1xpGKolS27lEXPrsmXT4dNGsMWKKW23fny5Spyq3S6c8gS/LPZF1GaOfI8mzY5Uqtzd11W66qulWqkYxrctWovUeEsfNRBZKVaJKnjd3p5lZbnnPZUlbtEAAAAAAB6eCeAGx4XzPsqxY1uEd2FtOLPHWtoD3g9ZddYmfmA8NSqfUruWvI1aeRPV8WRVw3qkQBcs36lnDj0cuev3OrDDXJlT2Z7Nz07+mWaqSsaOxscWWPTl+HRnh1Y6Wd0J4aSVUerwOTn4vm8fjvis47q9FSl1WIzLZo+X5cbL57vW9dwSXcXxXjVAPBFoAAAACyG6TSik3Wv4r0NU6OqLcMbn4xiGOVxu4sxmWV1Ee12vyKeOdJq9LcUVfKtkyyM4Sq8lZPluqrbzV6qySLMuvDPWXZfjlhfOazPqxykyizDPG/XUV08vq+PJtNxbb4q7eX8znysu1ufTq3XnL/1c2WttzsuWWlQOURFsMk8ddkpR8nzT60VAb5Yk49Rmwz9yGSSlWrly351q3VWdeURgN3ZWLcuV5ZuclFN87YqKfbRUSfkkVAAAAAAAAB0vTMy0+twZHWkZXp1qvJ2b5OaBrHWy+ra7NleVZ8uOrqowk1GC6RSVnRdWr8skaP03H6hT2tTixT+3iyV3JrrCnzRfNK1XDBBqBqZPNDFqHGkp7oZJJUjOcPtWW1Nxa3JdVWhlnrmmx6L0zS4IfZy89ZNwlul5t/krAY1gqpVVrS1aeH86HgGDJ9Xo8KwR1OnXtR3KOmVZSz5qO82ldXun9mK4qz30r1SWGVJqM8ix+1p5S+xXpXpGt3RbmrJmRqd0j4cJZtRghkwqU8acqzjSktyX2rblTwrzczHWaLRQ02ODksuozygvcS/iOvf7sYuzk7VdW91ZMDd2N7VXp9TD1KWLRYYvHi2whO38SeOCrOUpXjGEmkklSUpOrZi7Ws0HuJbsW9yxOS+04PvQjJcpOm6hjSasR7Mj1/pcNTmyT0cY+1ihtm4/LvgvljX5qJUlStG6EnHrNPPDp/T8GdY8axV1GaqiqNVnCFUm5ydqrgxqVYwMzj1LRw1sYx0GCLWBUcknCqUbY90knkk1RpKvjW4EUvNYOeu1na9PyAiPAAAAAAAAAAAAPQA8AAAAAABM0WbHp9Vhy5YucYTUnFUvTzs6O9OpDADO/UfUPRdcoTyfeJyhaKhFwk0/FytSvxT4sYIAEvUZoZHGOLG8WOFVCLluld3lKVFWT4bokkqKxEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAbxW5pNSarfbzT42rTitgA0LcixqT9uUpR5Tktsr9HRtVTtVOjACoAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
    @"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"
    @"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"
    @"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"
    @"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"
    @"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"
    @"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"
    @"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"
    @"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"
    @"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"
    @"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"
    @"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"
    @"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"
    @"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"
    @"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAegB4bW6/6fzDRKVqX0SaXKd1/qYt8T9EV+sd/7lBZKNOVQhupWaULMsbFYKxWAACTp9RPS5oZsbpKDqvB06eTVmRiUukWysfV8Pq+n1eGkYZZzlB7scMcpUqr3ptp21Z8102pnp5WlKF01KPzQa+0v6NcNclmvO/Zbx5zXTl2/9VmvO/ZuGU+nLtk+p+l5smfSQeTdVd1OS2uSSXeo22quqvzSvBy9F6pHJqIYpSwqU4xm8iUlHL0aca0x5E71q4yVinLunnjZdb6kL3Tzxsv+Tr6rQ/ecUovLk3V3wlVJRmvl7sUlRPnq1yzoQnHIqxdbtPmzXKdbpp9GV7RQ2ix/bLNp4za1CyTi4vFB+5HHPFK72ylVrfxVuStRHWg/b1OSDollpPH4NqNMkf8ANbdTqrlm/HZC9liCJicMsYLJCuLP3lF/9PL9vFTlJvc49tUbyg8Esim92DK96vWeGb5p1cK95NXjLpQkzy0fLNbp/uuqy4foSaXk+OrqqcMzD1nQT1WN6in8bElGW35c8F8uSPa106Oy6EUtIp68bYCCIgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAB6AHgAD08Ab0Lq7o35KSe9xBfuZY+e6h6eAbWAAAegB4AAm6TPHBk78VKMrS8UuySun5MhF/Fce2U+r/APxUL8MsZfu7ZKH0fDnyJ456fdn3r7FXNxj/AOVVpbiMqNPiO0wrRa7Noppwbp1jen8mX54dFbx8k7Z/dF+eHR+hhya8ZTqj6RLWY9RDZmw6nSv5o5MmOkYSjxJZItxTT8aJqzsWaD1HDr4WonS8Xw/z57Uyj3dHJxanVPuin3dGfFJOrD7o8x6rFqozxZf4eXD3sn2dmy6yxvXa3dUbpw7HK1HpmLL6lix78kIezKe1SUaw3UeODS3bVK7TbUY2VijtWKeyPhXqdZljglLJp9RDbkTxT2NwlGfzQ6NQpeDklSy5Rk+LdFezlbm6NKT/AOrH4W3JWkvirGjTT5LrVjnP3ccXBS/3INUePIubUspLvJcJ1Rm/reg96Lnj/wBxY2+j96Mfmj4rJFKqd90e0iVmm93zcAREnT4XqMscalGNftSdIxS6t/V1dii6dgzulJcr4jMbcb4XZ8XsZZY67qdV1KW23VkmMSytyvlqAIgAAAAAAAAAAAAAAAAAAB6AHgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAZ56B6fp82CWTLijOr6o1Zu4wMM7MmBn1bN6FoslXCCxOl6d6Pntk7eaa7SpZM9XfSLceWy3eL5SZ3i/R+Gpm571DCvlcIOMsv61JSlSCfD5lylQrW5WW9lS63HK4+GCmfy/ReH2cz+Kf1MqXy8XwzVybX9fF8M2A7WZr/wDHJr3H7loWitt591cV6NulWc/VF3Tx2qui6XTPjl/ewozn/wCMzoq5oVpez57LeJUt1x/3uayzu6+vhuOrM9sEMol6BnUs0YyU3jklVVSdYp9Vy26UVb34Kk9T4uNfrj0xcyef6OeoRrRYpeU19aTr8KdpBuv7lCzpxvuxg6uf0rXafH7mTDJRVKuzSr5O17GJ3HU7q1nRqb6nKLfay0rslTxo+hBPpy1vXhWs6M7N68KgQFYGzUlymgllMpN6G2WNQRGAKAAAAEeoAP/Z";

static UIImage *getAlbumArtworkImage(void) {
    static UIImage *s_img = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *localPath = [getLocalAudioDirectoryPath() stringByAppendingPathComponent:@"cover.jpg"];
        if ([[NSFileManager defaultManager] fileExistsAtPath:localPath]) {
            s_img = [UIImage imageWithContentsOfFile:localPath];
        }
        if (!s_img) {
            NSData *data = [[NSData alloc] initWithBase64EncodedString:s_albumCoverBase64 options:NSDataBase64DecodingIgnoreUnknownCharacters];
            if (data && data.length > 1000) {
                s_img = [UIImage imageWithData:data];
                @try {
                    [data writeToFile:localPath atomically:YES];
                } @catch (id ex) {}
            }
        }
    });
    return s_img;
}


static BOOL isCurrentTrackFromAlbum(NSString *uri, NSString *title, NSString *artist, NSString *streamUrl) {
    if (streamUrl && [streamUrl containsString:@"spotik-in4b.onrender.com/audio/"]) {
        return YES;
    }
    if (uri && [uri containsString:@"1f1OCxkJ43A1qy9qqFNfuX"]) {
        return YES;
    }
    for (int i = 0; i < 12; i++) {
        if (uri && [uri containsString:kAlbumURIs[i]]) return YES;
        NSString *idStr = [kAlbumURIs[i] stringByReplacingOccurrencesOfString:@"spotify:track:" withString:@""];
        if (uri && [uri containsString:idStr]) return YES;
    }
    NSString *aLower = artist.lowercaseString ?: @"";
    if ([aLower containsString:@"m1raontheblock"]) {
        return YES;
    }
    if (title && identifyAlbumTrackIndex(title) >= 0) {
        return YES;
    }
    return NO;
}

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

        // СТРОГАЯ ИЗОЛЯЦИЯ: Обложка и альбом Coll. of $hiTт устанавливаются ТОЛЬКО если сейчас действительно играет трек из этого альбома!
        BOOL isAlbum = isCurrentTrackFromAlbum(currentActiveSpotifyTrackURI, currentActiveSpotifyTrackTitle, currentActiveSpotifyTrackArtist, currentPlayingUrl);
        if (isAlbum) {
            info[MPMediaItemPropertyAlbumTitle] = @"Coll. of $hiTт (vol. 0.5)";

            static MPMediaItemArtwork *s_cachedArtwork = nil;
            static dispatch_once_t artToken;
            dispatch_once(&artToken, ^{
                UIImage *coverImg = getAlbumArtworkImage();
                if (coverImg) {
                    if (@available(iOS 10.0, *)) {
                        s_cachedArtwork = [[MPMediaItemArtwork alloc] initWithBoundsSize:coverImg.size requestHandler:^UIImage * _Nonnull(CGSize size) {
                            return coverImg;
                        }];
                    }
                }
            });
            if (s_cachedArtwork) {
                info[MPMediaItemPropertyArtwork] = s_cachedArtwork;
            }
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



@class AntiCensorNowPlayingViewController;
static __weak AntiCensorNowPlayingViewController *g_activeNowPlayingVC = nil;
static void presentAlbumNowPlayingScreen(int trackIdx);

static NSString *formatTrackTime(double sec) {
    if (isnan(sec) || sec < 0) sec = 0;
    int m = (int)(sec / 60.0);
    int s = (int)sec % 60;
    return [NSString stringWithFormat:@"%d:%02d", m, s];
}

@interface AntiCensorNowPlayingViewController : UIViewController <UIGestureRecognizerDelegate>
@property (nonatomic, assign) int trackIndex;
@property (nonatomic, strong) CAGradientLayer *gradientLayer;
@property (nonatomic, strong) UIView *artworkShadowView;
@property (nonatomic, strong) UIImageView *artworkImageView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *artistLabel;
@property (nonatomic, strong) UISlider *scrubberSlider;
@property (nonatomic, strong) UILabel *currentTimeLabel;
@property (nonatomic, strong) UILabel *totalTimeLabel;
@property (nonatomic, strong) UIButton *playPauseButton;
@property (nonatomic, strong) UIButton *prevButton;
@property (nonatomic, strong) UIButton *nextButton;
@property (nonatomic, strong) UIButton *heartButton;
@property (nonatomic, strong) UIView *lyricsCard;
@property (nonatomic, strong) UILabel *lyricsCardLine;
@property (nonatomic, strong) NSTimer *uiTimer;
@property (nonatomic, assign) BOOL isScrubbing;
@property (nonatomic, assign) BOOL isLiked;
- (instancetype)initWithAlbumTrackIndex:(int)idx;
- (void)updateWithTrackIndex:(int)idx;
@end

@implementation AntiCensorNowPlayingViewController

- (instancetype)initWithAlbumTrackIndex:(int)idx {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _trackIndex = (idx >= 0 && idx < 12) ? idx : 0;
        _isLiked = YES;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithRed:0.07f green:0.07f blue:0.08f alpha:1.0f];

    self.gradientLayer = [CAGradientLayer layer];
    self.gradientLayer.colors = @[
        (id)[UIColor colorWithRed:0.18f green:0.20f blue:0.22f alpha:1.0f].CGColor,
        (id)[UIColor colorWithRed:0.07f green:0.07f blue:0.08f alpha:1.0f].CGColor
    ];
    self.gradientLayer.locations = @[@0.0, @0.65];
    [self.view.layer insertSublayer:self.gradientLayer atIndex:0];

    UISwipeGestureRecognizer *swipe = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(onDismissAction:)];
    swipe.direction = UISwipeGestureRecognizerDirectionDown;
    [self.view addGestureRecognizer:swipe];

    // Top Navigation Bar
    UIButton *chevron = [UIButton buttonWithType:UIButtonTypeSystem];
    chevron.translatesAutoresizingMaskIntoConstraints = NO;
    [chevron setTitle:@"⌄" forState:UIControlStateNormal];
    chevron.titleLabel.font = [UIFont systemFontOfSize:28.0 weight:UIFontWeightBold];
    [chevron setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [chevron addTarget:self action:@selector(onDismissAction:) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:chevron];

    UILabel *headerLbl = [[UILabel alloc] init];
    headerLbl.translatesAutoresizingMaskIntoConstraints = NO;
    headerLbl.numberOfLines = 2;
    headerLbl.textAlignment = NSTextAlignmentCenter;
    NSMutableAttributedString *attr = [[NSMutableAttributedString alloc] initWithString:@"ИЗ АЛЬБОМА\n" attributes:@{
        NSFontAttributeName: [UIFont systemFontOfSize:10.0 weight:UIFontWeightBold],
        NSForegroundColorAttributeName: [UIColor colorWithWhite:0.65 alpha:1.0]
    }];
    [attr appendAttributedString:[[NSAttributedString alloc] initWithString:@"Coll. of $hiTт (vol. 0.5)" attributes:@{
        NSFontAttributeName: [UIFont systemFontOfSize:12.0 weight:UIFontWeightBold],
        NSForegroundColorAttributeName: [UIColor whiteColor]
    }]];
    headerLbl.attributedText = attr;
    [self.view addSubview:headerLbl];

    UIButton *menuBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    menuBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [menuBtn setTitle:@"•••" forState:UIControlStateNormal];
    menuBtn.titleLabel.font = [UIFont systemFontOfSize:18.0 weight:UIFontWeightBold];
    [menuBtn setTitleColor:[UIColor colorWithWhite:0.75 alpha:1.0] forState:UIControlStateNormal];
    [menuBtn addTarget:self action:@selector(onMenuAction:) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:menuBtn];

    // Artwork Container & Image
    self.artworkShadowView = [[UIView alloc] init];
    self.artworkShadowView.translatesAutoresizingMaskIntoConstraints = NO;
    self.artworkShadowView.layer.shadowColor = [UIColor blackColor].CGColor;
    self.artworkShadowView.layer.shadowOpacity = 0.55f;
    self.artworkShadowView.layer.shadowRadius = 18.0f;
    self.artworkShadowView.layer.shadowOffset = CGSizeMake(0, 8);
    [self.view addSubview:self.artworkShadowView];

    self.artworkImageView = [[UIImageView alloc] init];
    self.artworkImageView.translatesAutoresizingMaskIntoConstraints = NO;
    self.artworkImageView.layer.cornerRadius = 12.0f;
    self.artworkImageView.clipsToBounds = YES;
    self.artworkImageView.contentMode = UIViewContentModeScaleAspectFill;
    self.artworkImageView.image = getAlbumArtworkImage();
    [self.artworkShadowView addSubview:self.artworkImageView];

    // Track Title & Artist
    self.titleLabel = [[UILabel alloc] init];
    self.titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.titleLabel.font = [UIFont systemFontOfSize:20.0 weight:UIFontWeightBold];
    self.titleLabel.textColor = [UIColor whiteColor];
    self.titleLabel.text = kAlbumTitles[self.trackIndex];
    [self.view addSubview:self.titleLabel];

    self.artistLabel = [[UILabel alloc] init];
    self.artistLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.artistLabel.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightMedium];
    self.artistLabel.textColor = [UIColor colorWithRed:0.7f green:0.7f blue:0.7f alpha:1.0f];
    self.artistLabel.text = @"m1raOnTheBlock";
    [self.view addSubview:self.artistLabel];

    self.heartButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.heartButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.heartButton setTitle:@"💚" forState:UIControlStateNormal];
    self.heartButton.titleLabel.font = [UIFont systemFontOfSize:22.0];
    [self.heartButton addTarget:self action:@selector(onHeartAction:) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.heartButton];

    // Scrubber Slider
    self.scrubberSlider = [[UISlider alloc] init];
    self.scrubberSlider.translatesAutoresizingMaskIntoConstraints = NO;
    self.scrubberSlider.minimumValue = 0.0f;
    self.scrubberSlider.maximumValue = 180.0f;
    self.scrubberSlider.minimumTrackTintColor = [UIColor whiteColor];
    self.scrubberSlider.maximumTrackTintColor = [UIColor colorWithWhite:1.0 alpha:0.25f];
    [self.scrubberSlider addTarget:self action:@selector(onSliderDrag:) forControlEvents:UIControlEventValueChanged];
    [self.scrubberSlider addTarget:self action:@selector(onSliderEnd:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside];
    [self.view addSubview:self.scrubberSlider];

    self.currentTimeLabel = [[UILabel alloc] init];
    self.currentTimeLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.currentTimeLabel.font = [UIFont systemFontOfSize:11.0 weight:UIFontWeightRegular];
    self.currentTimeLabel.textColor = [UIColor colorWithWhite:0.65 alpha:1.0];
    self.currentTimeLabel.text = @"0:00";
    [self.view addSubview:self.currentTimeLabel];

    self.totalTimeLabel = [[UILabel alloc] init];
    self.totalTimeLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.totalTimeLabel.font = [UIFont systemFontOfSize:11.0 weight:UIFontWeightRegular];
    self.totalTimeLabel.textColor = [UIColor colorWithWhite:0.65 alpha:1.0];
    self.totalTimeLabel.text = @"3:00";
    self.totalTimeLabel.textAlignment = NSTextAlignmentRight;
    [self.view addSubview:self.totalTimeLabel];

    // Controls
    self.prevButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.prevButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.prevButton setTitle:@"⏮" forState:UIControlStateNormal];
    self.prevButton.titleLabel.font = [UIFont systemFontOfSize:26.0 weight:UIFontWeightBold];
    [self.prevButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [self.prevButton addTarget:self action:@selector(onPrevTrackAction:) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.prevButton];

    self.playPauseButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.playPauseButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.playPauseButton.layer.cornerRadius = 32.0f;
    self.playPauseButton.backgroundColor = [UIColor whiteColor];
    [self.playPauseButton setTitleColor:[UIColor blackColor] forState:UIControlStateNormal];
    self.playPauseButton.titleLabel.font = [UIFont systemFontOfSize:22.0 weight:UIFontWeightBold];
    [self.playPauseButton setTitle:@"❚❚" forState:UIControlStateNormal];
    [self.playPauseButton addTarget:self action:@selector(onPlayPauseAction:) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.playPauseButton];

    self.nextButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.nextButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.nextButton setTitle:@"⏭" forState:UIControlStateNormal];
    self.nextButton.titleLabel.font = [UIFont systemFontOfSize:26.0 weight:UIFontWeightBold];
    [self.nextButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [self.nextButton addTarget:self action:@selector(onNextTrackAction:) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.nextButton];

    // Lyrics Preview Card
    self.lyricsCard = [[UIView alloc] init];
    self.lyricsCard.translatesAutoresizingMaskIntoConstraints = NO;
    self.lyricsCard.layer.cornerRadius = 14.0f;
    self.lyricsCard.backgroundColor = [UIColor colorWithRed:0.16f green:0.24f blue:0.18f alpha:0.75f];
    self.lyricsCard.clipsToBounds = YES;
    UITapGestureRecognizer *lTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onLyricsCardTapped:)];
    [self.lyricsCard addGestureRecognizer:lTap];
    [self.view addSubview:self.lyricsCard];

    UILabel *lyricsTitle = [[UILabel alloc] init];
    lyricsTitle.translatesAutoresizingMaskIntoConstraints = NO;
    lyricsTitle.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightBold];
    lyricsTitle.textColor = [UIColor whiteColor];
    lyricsTitle.text = @"Текст песни  ⤢";
    [self.lyricsCard addSubview:lyricsTitle];

    self.lyricsCardLine = [[UILabel alloc] init];
    self.lyricsCardLine.translatesAutoresizingMaskIntoConstraints = NO;
    self.lyricsCardLine.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightBold];
    self.lyricsCardLine.textColor = [UIColor whiteColor];
    self.lyricsCardLine.numberOfLines = 2;
    self.lyricsCardLine.text = @"Нажмите, чтобы открыть караоке...";
    [self.lyricsCard addSubview:self.lyricsCardLine];

    // AutoLayout Constraints
    UILayoutGuide *guide = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [chevron.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor constant:16],
        [chevron.topAnchor constraintEqualToAnchor:guide.topAnchor constant:4],
        [chevron.widthAnchor constraintEqualToConstant:44],
        [chevron.heightAnchor constraintEqualToConstant:44],

        [headerLbl.centerXAnchor constraintEqualToAnchor:guide.centerXAnchor],
        [headerLbl.centerYAnchor constraintEqualToAnchor:chevron.centerYAnchor],

        [menuBtn.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor constant:-16],
        [menuBtn.centerYAnchor constraintEqualToAnchor:chevron.centerYAnchor],
        [menuBtn.widthAnchor constraintEqualToConstant:44],
        [menuBtn.heightAnchor constraintEqualToConstant:44],

        // Artwork
        [self.artworkShadowView.topAnchor constraintEqualToAnchor:headerLbl.bottomAnchor constant:14],
        [self.artworkShadowView.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor constant:36],
        [self.artworkShadowView.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor constant:-36],
        [self.artworkShadowView.heightAnchor constraintEqualToAnchor:self.artworkShadowView.widthAnchor],

        [self.artworkImageView.topAnchor constraintEqualToAnchor:self.artworkShadowView.topAnchor],
        [self.artworkImageView.bottomAnchor constraintEqualToAnchor:self.artworkShadowView.bottomAnchor],
        [self.artworkImageView.leadingAnchor constraintEqualToAnchor:self.artworkShadowView.leadingAnchor],
        [self.artworkImageView.trailingAnchor constraintEqualToAnchor:self.artworkShadowView.trailingAnchor],

        // Title & Artist
        [self.titleLabel.topAnchor constraintEqualToAnchor:self.artworkShadowView.bottomAnchor constant:16],
        [self.titleLabel.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor constant:28],
        [self.titleLabel.trailingAnchor constraintEqualToAnchor:self.heartButton.leadingAnchor constant:-12],

        [self.artistLabel.topAnchor constraintEqualToAnchor:self.titleLabel.bottomAnchor constant:3],
        [self.artistLabel.leadingAnchor constraintEqualToAnchor:self.titleLabel.leadingAnchor],
        [self.artistLabel.trailingAnchor constraintEqualToAnchor:self.titleLabel.trailingAnchor],

        [self.heartButton.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor constant:-28],
        [self.heartButton.centerYAnchor constraintEqualToAnchor:self.titleLabel.bottomAnchor],
        [self.heartButton.widthAnchor constraintEqualToConstant:36],
        [self.heartButton.heightAnchor constraintEqualToConstant:36],

        // Slider
        [self.scrubberSlider.topAnchor constraintEqualToAnchor:self.artistLabel.bottomAnchor constant:16],
        [self.scrubberSlider.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor constant:28],
        [self.scrubberSlider.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor constant:-28],

        [self.currentTimeLabel.topAnchor constraintEqualToAnchor:self.scrubberSlider.bottomAnchor constant:2],
        [self.currentTimeLabel.leadingAnchor constraintEqualToAnchor:self.scrubberSlider.leadingAnchor],

        [self.totalTimeLabel.topAnchor constraintEqualToAnchor:self.scrubberSlider.bottomAnchor constant:2],
        [self.totalTimeLabel.trailingAnchor constraintEqualToAnchor:self.scrubberSlider.trailingAnchor],

        // Controls
        [self.playPauseButton.topAnchor constraintEqualToAnchor:self.currentTimeLabel.bottomAnchor constant:12],
        [self.playPauseButton.centerXAnchor constraintEqualToAnchor:guide.centerXAnchor],
        [self.playPauseButton.widthAnchor constraintEqualToConstant:64],
        [self.playPauseButton.heightAnchor constraintEqualToConstant:64],

        [self.prevButton.centerYAnchor constraintEqualToAnchor:self.playPauseButton.centerYAnchor],
        [self.prevButton.trailingAnchor constraintEqualToAnchor:self.playPauseButton.leadingAnchor constant:-36],
        [self.prevButton.widthAnchor constraintEqualToConstant:40],
        [self.prevButton.heightAnchor constraintEqualToConstant:40],

        [self.nextButton.centerYAnchor constraintEqualToAnchor:self.playPauseButton.centerYAnchor],
        [self.nextButton.leadingAnchor constraintEqualToAnchor:self.playPauseButton.trailingAnchor constant:36],
        [self.nextButton.widthAnchor constraintEqualToConstant:40],
        [self.nextButton.heightAnchor constraintEqualToConstant:40],

        // Lyrics Card
        [self.lyricsCard.topAnchor constraintEqualToAnchor:self.playPauseButton.bottomAnchor constant:14],
        [self.lyricsCard.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor constant:24],
        [self.lyricsCard.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor constant:-24],
        [self.lyricsCard.bottomAnchor constraintLessThanOrEqualToAnchor:guide.bottomAnchor constant:-12],
        [self.lyricsCard.heightAnchor constraintGreaterThanOrEqualToConstant:70],

        [lyricsTitle.topAnchor constraintEqualToAnchor:self.lyricsCard.topAnchor constant:10],
        [lyricsTitle.leadingAnchor constraintEqualToAnchor:self.lyricsCard.leadingAnchor constant:14],

        [self.lyricsCardLine.topAnchor constraintEqualToAnchor:lyricsTitle.bottomAnchor constant:4],
        [self.lyricsCardLine.leadingAnchor constraintEqualToAnchor:self.lyricsCard.leadingAnchor constant:14],
        [self.lyricsCardLine.trailingAnchor constraintEqualToAnchor:self.lyricsCard.trailingAnchor constant:-14],
        [self.lyricsCardLine.bottomAnchor constraintLessThanOrEqualToAnchor:self.lyricsCard.bottomAnchor constant:-10]
    ]];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    self.gradientLayer.frame = self.view.bounds;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    g_activeNowPlayingVC = self;
    [self startTimer];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    if (g_activeNowPlayingVC == self) g_activeNowPlayingVC = nil;
    [self stopTimer];
}

- (void)startTimer {
    [self stopTimer];
    __weak typeof(self) weakSelf = self;
    self.uiTimer = [NSTimer scheduledTimerWithTimeInterval:0.25 repeats:YES block:^(NSTimer * _Nonnull t) {
        [weakSelf onTimerTick];
    }];
    [[NSRunLoop mainRunLoop] addTimer:self.uiTimer forMode:NSRunLoopCommonModes];
}

- (void)stopTimer {
    if (self.uiTimer) {
        [self.uiTimer invalidate];
        self.uiTimer = nil;
    }
}

- (void)onTimerTick {
    if (!ourAudioPlayer) return;
    if (self.isScrubbing) return;

    double cur = CMTimeGetSeconds(ourAudioPlayer.currentTime);
    double dur = CMTimeGetSeconds(ourAudioPlayer.currentItem.duration);
    if (!isnan(dur) && dur > 1.0) {
        self.scrubberSlider.maximumValue = (float)dur;
        self.totalTimeLabel.text = formatTrackTime(dur);
    }
    if (!isnan(cur) && cur >= 0) {
        self.scrubberSlider.value = (float)cur;
        self.currentTimeLabel.text = formatTrackTime(cur);
    }
    BOOL isPlaying = (ourAudioPlayer.timeControlStatus == AVPlayerTimeControlStatusPlaying && isSpotifyCurrentlyPlaying);
    [self.playPauseButton setTitle:(isPlaying ? @"❚❚" : @"▶") forState:UIControlStateNormal];

    if (g_currentKaraokeItems && g_currentKaraokeItems.count > 0) {
        NSString *bestText = nil;
        for (AntiCensorLyricItem *it in g_currentKaraokeItems) {
            if (cur >= it.time) {
                bestText = it.text;
            } else {
                break;
            }
        }
        if (bestText && bestText.length > 0) {
            self.lyricsCardLine.text = bestText;
        }
    }
}

- (void)updateWithTrackIndex:(int)idx {
    if (idx < 0 || idx >= 12) return;
    self.trackIndex = idx;
    NSString *title = kAlbumTitles[idx];
    NSString *url = kAlbumUrls[idx];
    NSString *uri = kAlbumURIs[idx];

    self.titleLabel.text = title;
    self.scrubberSlider.value = 0.0f;
    self.currentTimeLabel.text = @"0:00";
    self.lyricsCardLine.text = @"Загрузка текста...";

    isMutingSpotify = YES;
    applyMuteStateToAllUnits();
    isSpotifyCurrentlyPlaying = YES;
    currentActiveSpotifyTrackTitle = title;
    currentActiveSpotifyTrackArtist = @"m1raOnTheBlock";
    currentActiveSpotifyTrackURI = uri;

    startReplacementAudio(title, url, 0.0);
    cleanupRogueBanners();
    updateNowPlayingCenter();
}

- (void)onDismissAction:(id)sender {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)onMenuAction:(id)sender {
    showAntiCensorMainOptionsDialog(kAlbumURIs[self.trackIndex], kAlbumTitles[self.trackIndex], @"m1raOnTheBlock");
}

- (void)onLyricsCardTapped:(UITapGestureRecognizer *)gesture {
    showLyricsManagerDialog(kAlbumURIs[self.trackIndex], kAlbumTitles[self.trackIndex], @"m1raOnTheBlock", kAlbumTitles[self.trackIndex]);
}

- (void)onHeartAction:(id)sender {
    self.isLiked = !self.isLiked;
    [self.heartButton setTitle:(self.isLiked ? @"💚" : @"🤍") forState:UIControlStateNormal];
    if (@available(iOS 10.0, *)) {
        UIImpactFeedbackGenerator *fb = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
        [fb prepare];
        [fb impactOccurred];
    }
}

- (void)onPlayPauseAction:(id)sender {
    if (ourAudioPlayer) {
        if (ourAudioPlayer.timeControlStatus == AVPlayerTimeControlStatusPlaying) {
            [ourAudioPlayer pause];
            isSpotifyCurrentlyPlaying = NO;
        } else {
            [ourAudioPlayer play];
            isSpotifyCurrentlyPlaying = YES;
        }
        updateNowPlayingCenter();
        BOOL isPlaying = (ourAudioPlayer.timeControlStatus == AVPlayerTimeControlStatusPlaying && isSpotifyCurrentlyPlaying);
        [self.playPauseButton setTitle:(isPlaying ? @"❚❚" : @"▶") forState:UIControlStateNormal];
        if (@available(iOS 10.0, *)) {
            UIImpactFeedbackGenerator *fb = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
            [fb prepare];
            [fb impactOccurred];
        }
    }
}

- (void)onPrevTrackAction:(id)sender {
    double cur = ourAudioPlayer ? CMTimeGetSeconds(ourAudioPlayer.currentTime) : 0;
    if (cur > 3.0) {
        safeSeekPlayerToTime(0.0);
        updateNowPlayingCenter();
        return;
    }
    int prevIdx = (self.trackIndex - 1 + 12) % 12;
    [self updateWithTrackIndex:prevIdx];
}

- (void)onNextTrackAction:(id)sender {
    int nextIdx = (self.trackIndex + 1) % 12;
    [self updateWithTrackIndex:nextIdx];
}

- (void)onSliderDrag:(UISlider *)sender {
    self.isScrubbing = YES;
    self.currentTimeLabel.text = formatTrackTime(sender.value);
}

- (void)onSliderEnd:(UISlider *)sender {
    self.isScrubbing = NO;
    g_lastUserManualLyricsSeekTimestamp = [NSDate timeIntervalSinceReferenceDate];
    safeSeekPlayerToTime(sender.value);
    updateNowPlayingCenter();
}

@end

static void presentAlbumNowPlayingScreen(int trackIdx) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (g_activeNowPlayingVC) {
            [g_activeNowPlayingVC updateWithTrackIndex:trackIdx];
            return;
        }

        UIViewController *topVC = getTopViewController();
        if (!topVC) return;

        AntiCensorNowPlayingViewController *vc = [[AntiCensorNowPlayingViewController alloc] initWithAlbumTrackIndex:trackIdx];
        if (@available(iOS 13.0, *)) {
            vc.modalPresentationStyle = UIModalPresentationAutomatic;
        } else {
            vc.modalPresentationStyle = UIModalPresentationFullScreen;
        }
        vc.modalTransitionStyle = UIModalTransitionStyleCoverVertical;

        [topVC presentViewController:vc animated:YES completion:nil];
    });
}

@interface AntiCensorCellTapHandler : NSObject <UIGestureRecognizerDelegate>
+ (instancetype)sharedHandler;
- (void)handleCellTap:(UITapGestureRecognizer *)gesture;
- (void)handleBigPlayButtonTap:(id)sender;
@end

static void unGreyAndEnableCell(UIView *cell);
static void (*orig_UITableViewCell_layoutSubviews)(id, SEL) = NULL;
static void custom_UITableViewCell_layoutSubviews(UITableViewCell *self, SEL _cmd);
static void (*orig_UICollectionViewCell_layoutSubviews)(id, SEL) = NULL;
static void custom_UICollectionViewCell_layoutSubviews(UICollectionViewCell *self, SEL _cmd);

@implementation AntiCensorCellTapHandler

+ (instancetype)sharedHandler {
    static AntiCensorCellTapHandler *s = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        s = [[AntiCensorCellTapHandler alloc] init];
    });
    return s;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    return YES;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch {
    return YES;
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    return YES;
}

- (void)handleBigPlayButtonTap:(id)sender {
    NSLog(@"[AntiCensor iOS] Big Play button tapped on album page!");
    if (ourAudioPlayer != nil && currentPlayingUrl && isCurrentTrackFromAlbum(currentActiveSpotifyTrackURI, currentActiveSpotifyTrackTitle, currentActiveSpotifyTrackArtist, currentPlayingUrl)) {
        if (ourAudioPlayer.timeControlStatus == AVPlayerTimeControlStatusPlaying) {
            [ourAudioPlayer pause];
            isSpotifyCurrentlyPlaying = NO;
        } else {
            [ourAudioPlayer play];
            isSpotifyCurrentlyPlaying = YES;
        }
        updateNowPlayingCenter();
        cleanupRogueBanners();
        return;
    }
    // Start track 1: ONE WEEK RECORD and open the Now Playing screen!
    isMutingSpotify = YES;
    applyMuteStateToAllUnits();
    isSpotifyCurrentlyPlaying = YES;
    currentActiveSpotifyTrackTitle = kAlbumTitles[0];
    currentActiveSpotifyTrackArtist = @"m1raOnTheBlock";
    currentActiveSpotifyTrackURI = kAlbumURIs[0];
    startReplacementAudio(kAlbumTitles[0], kAlbumUrls[0], 0.0);
    cleanupRogueBanners();
    presentAlbumNowPlayingScreen(0);
}

- (void)handleCellTap:(UITapGestureRecognizer *)gesture {
    UIView *targetView = gesture.view;
    if (!targetView) return;

    UIView *actualCell = targetView;
    while (actualCell && ![actualCell isKindOfClass:[UICollectionViewCell class]] && ![actualCell isKindOfClass:[UITableViewCell class]]) {
        actualCell = actualCell.superview;
    }
    if (!actualCell) actualCell = targetView;

    int matchedTrackIdx = -1;
    NSMutableArray *views = [NSMutableArray arrayWithObject:actualCell];
    NSMutableArray<UILabel *> *labels = [NSMutableArray array];
    while (views.count > 0) {
        UIView *v = views.firstObject;
        [views removeObjectAtIndex:0];
        if ([v isKindOfClass:[UILabel class]]) {
            UILabel *lbl = (UILabel *)v;
            [labels addObject:lbl];
            if (matchedTrackIdx < 0 && lbl.text && lbl.text.length > 0) {
                int idx = identifyAlbumTrackIndex(lbl.text);
                if (idx >= 0) matchedTrackIdx = idx;
            }
        }
        [views addObjectsFromArray:v.subviews];
    }

    if (matchedTrackIdx < 0 && s_isAlbumScreenVisible) {
        UIView *p = actualCell.superview;
        while (p && ![p isKindOfClass:[UICollectionView class]] && ![p isKindOfClass:[UITableView class]]) {
            p = p.superview;
        }
        if ([p isKindOfClass:[UICollectionView class]]) {
            NSIndexPath *ip = [((UICollectionView *)p) indexPathForCell:(UICollectionViewCell *)actualCell];
            if (ip && ip.item < 12) matchedTrackIdx = (int)ip.item;
        } else if ([p isKindOfClass:[UITableView class]]) {
            NSIndexPath *ip = [((UITableView *)p) indexPathForCell:(UITableViewCell *)actualCell];
            if (ip && ip.row < 12) matchedTrackIdx = (int)ip.row;
        }
    }

    if (matchedTrackIdx >= 0 && matchedTrackIdx < 12) {
        NSString *matchedTitle = kAlbumTitles[matchedTrackIdx];
        NSString *matchedUrl = kAlbumUrls[matchedTrackIdx];
        NSString *matchedURI = kAlbumURIs[matchedTrackIdx];

        NSLog(@"[AntiCensor iOS] Cell tap matched album track [%d] '%@' -> %@", matchedTrackIdx + 1, matchedTitle, matchedUrl);

        BOOL isSameTrack = (currentPlayingUrl && [currentPlayingUrl isEqualToString:matchedUrl]);
        if (!isSameTrack || !ourAudioPlayer || ourAudioPlayer.timeControlStatus != AVPlayerTimeControlStatusPlaying) {
            isMutingSpotify = YES;
            applyMuteStateToAllUnits();

            isSpotifyCurrentlyPlaying = YES;
            currentActiveSpotifyTrackTitle = matchedTitle;
            currentActiveSpotifyTrackArtist = @"m1raOnTheBlock";
            currentActiveSpotifyTrackURI = matchedURI;

            startReplacementAudio(matchedTitle, matchedUrl, 0.0);
            cleanupRogueBanners();
        }

        // Открываем нативный Spotify экран трека с плавной анимацией выезда снизу вверх!
        presentAlbumNowPlayingScreen(matchedTrackIdx);
    }
}

@end

static void unGreyAndEnableCell(UIView *cell) {
    if (!cell) return;

    int matchedTrackIdx = -1;
    NSString *matchedTrackTitle = nil;

    NSMutableArray *views = [NSMutableArray arrayWithObject:cell];
    NSMutableArray<UILabel *> *labels = [NSMutableArray array];
    NSMutableArray<UIView *> *allDescendants = [NSMutableArray array];

    while (views.count > 0) {
        UIView *v = views.firstObject;
        [views removeObjectAtIndex:0];
        [allDescendants addObject:v];

        if ([v isKindOfClass:[UILabel class]]) {
            UILabel *lbl = (UILabel *)v;
            [labels addObject:lbl];
            NSString *t = lbl.text;
            if (t && t.length > 0 && matchedTrackIdx < 0) {
                int idx = identifyAlbumTrackIndex(t);
                if (idx >= 0) {
                    matchedTrackIdx = idx;
                    matchedTrackTitle = t;
                }
            }
        }
        [views addObjectsFromArray:v.subviews];
    }

    if (matchedTrackIdx < 0 && s_isAlbumScreenVisible) {
        UIView *p = cell.superview;
        while (p && ![p isKindOfClass:[UICollectionView class]] && ![p isKindOfClass:[UITableView class]]) {
            p = p.superview;
        }
        if ([p isKindOfClass:[UICollectionView class]]) {
            NSIndexPath *ip = [((UICollectionView *)p) indexPathForCell:(UICollectionViewCell *)cell];
            if (ip && ip.item < 12) {
                matchedTrackIdx = (int)ip.item;
                matchedTrackTitle = kAlbumTitles[matchedTrackIdx];
            }
        } else if ([p isKindOfClass:[UITableView class]]) {
            NSIndexPath *ip = [((UITableView *)p) indexPathForCell:(UITableViewCell *)cell];
            if (ip && ip.row < 12) {
                matchedTrackIdx = (int)ip.row;
                matchedTrackTitle = kAlbumTitles[matchedTrackIdx];
            }
        }
    }

    if (matchedTrackIdx >= 0 && matchedTrackIdx < 12) {
        cell.userInteractionEnabled = YES;
        cell.alpha = 1.0f;
        UIView *contentView = cell;
        if ([cell isKindOfClass:[UITableViewCell class]]) {
            contentView = ((UITableViewCell *)cell).contentView;
        } else if ([cell isKindOfClass:[UICollectionViewCell class]]) {
            contentView = ((UICollectionViewCell *)cell).contentView;
        }
        contentView.userInteractionEnabled = YES;
        contentView.alpha = 1.0f;

        for (UIView *desc in allDescendants) {
            desc.userInteractionEnabled = YES;
            if (desc.alpha < 0.95f) {
                desc.alpha = 1.0f;
            }
        }

        BOOL isCurrentPlayingTrack = (ourAudioPlayer != nil &&
                                      ourAudioPlayer.timeControlStatus == AVPlayerTimeControlStatusPlaying &&
                                      isSpotifyCurrentlyPlaying &&
                                      currentPlayingUrl &&
                                      [currentPlayingUrl isEqualToString:kAlbumUrls[matchedTrackIdx]]);

        for (UILabel *lbl in labels) {
            lbl.alpha = 1.0f;
            lbl.hidden = NO;
            NSString *lText = lbl.text.lowercaseString ?: @"";
            BOOL isSubtitle = [lText containsString:@"m1raontheblock"] || lbl.font.pointSize < 13.0;

            if (isCurrentPlayingTrack) {
                if (isSubtitle) {
                    lbl.textColor = [UIColor colorWithRed:0x1D/255.0 green:0xB9/255.0 blue:0x54/255.0 alpha:0.8];
                } else {
                    lbl.textColor = [UIColor colorWithRed:0x1D/255.0 green:0xB9/255.0 blue:0x54/255.0 alpha:1.0];
                }
            } else {
                if (isSubtitle) {
                    lbl.textColor = [UIColor colorWithWhite:0.7 alpha:1.0];
                } else {
                    lbl.textColor = [UIColor whiteColor];
                }
            }
        }

        BOOL hasTap = NO;
        for (UIGestureRecognizer *gr in contentView.gestureRecognizers) {
            if ([gr.name isEqualToString:@"AntiCensorTap"]) {
                hasTap = YES;
                break;
            }
        }
        if (!hasTap) {
            UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:[AntiCensorCellTapHandler sharedHandler] action:@selector(handleCellTap:)];
            tap.name = @"AntiCensorTap";
            tap.delegate = [AntiCensorCellTapHandler sharedHandler];
            tap.cancelsTouchesInView = YES;
            [contentView addGestureRecognizer:tap];
        }
    }
}

static void custom_UITableViewCell_layoutSubviews(UITableViewCell *self, SEL _cmd) {
    if (orig_UITableViewCell_layoutSubviews) orig_UITableViewCell_layoutSubviews(self, _cmd);
    unGreyAndEnableCell(self);
}

static void custom_UICollectionViewCell_layoutSubviews(UICollectionViewCell *self, SEL _cmd) {
    if (orig_UICollectionViewCell_layoutSubviews) orig_UICollectionViewCell_layoutSubviews(self, _cmd);
    unGreyAndEnableCell(self);
}

@interface AntiCensorTapHandler : NSObject <UIGestureRecognizerDelegate>
+ (instancetype)sharedHandler;
- (void)onKaraokeLineTapped:(UITapGestureRecognizer *)gesture;
- (void)onLyricsContainerTapped:(UITapGestureRecognizer *)gesture;
- (void)onNowPlayingCardTapped:(UITapGestureRecognizer *)gesture;
- (void)onDismissSwipeDown:(UISwipeGestureRecognizer *)gesture;
- (void)onChevronDismissTapped:(id)sender;
- (void)handleSeekToLyricIndex:(NSInteger)idx inView:(UIView *)view;
@end

static __weak UILabel *g_activeNowPlayingCardLabel = nil;
static __weak UIView *g_activeKaraokeContainer = nil;

static NSArray<AntiCensorLyricItem *> *g_currentKaraokeItems = nil;
static NSMutableArray<UILabel *> *g_currentKaraokeLabels = nil;
static NSString *g_currentKaraokeTrackKey = nil;
static NSInteger g_lastActiveKaraokeIdx = -1;

static double g_currentTrackDuration = 180.0;
static NSTimeInterval g_lastUserLyricsInteractionTime = 0;
static NSTimeInterval g_lastUserManualLyricsSeekTimestamp = 0;

static void seekSpotifyPlayback(double targetSeconds, double duration) {
    if (isnan(targetSeconds) || targetSeconds < 0) return;

    g_spotifyLastReportedPosition = targetSeconds;
    g_spotifyLastReportedTimestamp = [NSDate timeIntervalSinceReferenceDate];
    lastKnownSpotifyPosition = targetSeconds;
    lastSpotifyPositionTimestamp = [NSDate timeIntervalSinceReferenceDate];
    g_lastUserLyricsInteractionTime = [NSDate timeIntervalSinceReferenceDate];

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
                    NSString *cls = NSStringFromClass([slider class]);
                    // Пропускаем регуляторы громкости, чтобы не сбивать звук наушников
                    if (![cls containsString:@"Volume"] && slider.bounds.size.width > 80.0) {
                        float minV = slider.minimumValue;
                        float maxV = slider.maximumValue;
                        if (maxV > minV) {
                            float val = 0.0f;
                            if (maxV <= 1.05f && maxV >= 0.95f) {
                                val = (duration > 0) ? (float)(targetSeconds / duration) : 0.0f;
                            } else {
                                val = (float)targetSeconds;
                            }
                            if (val < minV) val = minV;
                            if (val > maxV) val = maxV;
                            slider.value = val;
                            [slider sendActionsForControlEvents:UIControlEventValueChanged];
                            [slider sendActionsForControlEvents:UIControlEventTouchUpInside];
                            [slider sendActionsForControlEvents:UIControlEventPrimaryActionTriggered];
                        }
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

- (void)onDismissSwipeDown:(UISwipeGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateEnded) return;
    if (g_activeKaraokeContainer && [g_activeKaraokeContainer isKindOfClass:[UIScrollView class]]) {
        UIScrollView *sv = (UIScrollView *)g_activeKaraokeContainer;
        if (sv.contentOffset.y > 40.0) {
            return; // Пользователь скроллит текст вверх из глубины
        }
    }
    UIViewController *topVC = getKeyAppWindow().rootViewController;
    while (topVC.presentedViewController && !topVC.presentedViewController.isBeingDismissed) {
        topVC = topVC.presentedViewController;
    }
    if (topVC && topVC != getKeyAppWindow().rootViewController) {
        [topVC dismissViewControllerAnimated:YES completion:nil];
    }
}

- (void)onChevronDismissTapped:(id)sender {
    UIViewController *topVC = getKeyAppWindow().rootViewController;
    while (topVC.presentedViewController && !topVC.presentedViewController.isBeingDismissed) {
        topVC = topVC.presentedViewController;
    }
    if (topVC && topVC != getKeyAppWindow().rootViewController) {
        [topVC dismissViewControllerAnimated:YES completion:nil];
    }
}

- (void)handleSeekToLyricIndex:(NSInteger)idx inView:(UIView *)view {
    if (@available(iOS 10.0, *)) {
        UIImpactFeedbackGenerator *gen = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
        [gen prepare];
        [gen impactOccurred];
    }
    if (!g_currentKaraokeItems || idx < 0 || idx >= (NSInteger)g_currentKaraokeItems.count) return;

    double seekTarget = g_currentKaraokeItems[idx].time;
    if (seekTarget < 0) {
        if (g_currentTrackDuration > 0 && g_currentKaraokeItems.count > 0) {
            seekTarget = ((double)idx / (double)g_currentKaraokeItems.count) * g_currentTrackDuration;
        } else {
            return;
        }
    }

    // Защита от дребезга контактов: не запускаем перемотку на тот же таймкод повторно в течение 0.15 сек
    static double s_lastSeekTarget = -1.0;
    static NSTimeInterval s_lastSeekTime = 0;
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (fabs(seekTarget - s_lastSeekTarget) < 0.05 && (now - s_lastSeekTime < 0.15)) {
        return;
    }
    s_lastSeekTarget = seekTarget;
    s_lastSeekTime = now;

    // Сразу фиксируем время взаимодействия, чтобы автоскролл и сетевые события Spotify не перебивали наш выбор
    g_lastUserManualLyricsSeekTimestamp = now;
    g_lastUserLyricsInteractionTime = now;
    lastKnownSpotifyPosition = seekTarget;
    lastSpotifyPositionTimestamp = now;
    g_spotifyLastReportedPosition = seekTarget;
    g_spotifyLastReportedTimestamp = now;

    // 1. Перематываем наш аудиоплеер (если играет кастомный трек / файл с устройства)
    safeSeekPlayerToTime(seekTarget);

    // 2. Синхронно перематываем системный ползунок таймлайна и движок Spotify
    seekSpotifyPlayback(seekTarget, g_currentTrackDuration);

    // 2.1 Гарантируем запуск воспроизведения после перемотки
    if (ourAudioPlayer && isSpotifyCurrentlyPlaying) {
        if (ourAudioPlayer.timeControlStatus != AVPlayerTimeControlStatusPlaying) {
            [ourAudioPlayer play];
        }
    }

    // 3. Мгновенная визуальная подсветка нажатой строки белым цветом
    g_lastActiveKaraokeIdx = idx;
    [UIView animateWithDuration:0.15 animations:^{
        for (NSUInteger i = 0; i < g_currentKaraokeLabels.count; i++) {
            UILabel *lbl = g_currentKaraokeLabels[i];
            if ((NSInteger)i == idx) {
                lbl.textColor = [UIColor whiteColor];
                lbl.alpha = 1.0f;
                lbl.transform = CGAffineTransformIdentity;
            } else {
                lbl.textColor = [UIColor blackColor];
                lbl.alpha = 1.0f;
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
        CGFloat targetY = view.frame.origin.y - (sv.bounds.size.height * 0.22);
        if (targetY < 0) targetY = 0;
        CGFloat maxY = sv.contentSize.height - sv.bounds.size.height;
        if (maxY < 0) maxY = 0;
        if (targetY > maxY) targetY = maxY;
        [sv setContentOffset:CGPointMake(0, targetY) animated:YES];
    }
}

- (void)onKaraokeLineTapped:(UITapGestureRecognizer *)gesture {
    g_lastUserLyricsInteractionTime = [NSDate timeIntervalSinceReferenceDate];
    UIView *view = gesture.view;
    NSInteger idx = view.tag;
    [self handleSeekToLyricIndex:idx inView:view];
}

- (void)onLyricsContainerTapped:(UITapGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateEnded) return;
    g_lastUserLyricsInteractionTime = [NSDate timeIntervalSinceReferenceDate];
    if (!g_currentKaraokeLabels || g_currentKaraokeLabels.count == 0) return;

    CGPoint pt = [gesture locationInView:gesture.view];
    for (UILabel *l in g_currentKaraokeLabels) {
        if (CGRectContainsPoint(l.frame, pt)) {
            return; // Уже обработано жестом нажатия конкретной строки!
        }
    }

    NSInteger closestIdx = -1;
    CGFloat minDistance = CGFLOAT_MAX;

    for (NSUInteger i = 0; i < g_currentKaraokeLabels.count; i++) {
        UILabel *lbl = g_currentKaraokeLabels[i];
        CGFloat midY = CGRectGetMidY(lbl.frame);
        CGFloat dist = fabs(pt.y - midY);
        if (dist < minDistance) {
            minDistance = dist;
            closestIdx = (NSInteger)i;
        }
    }

    if (closestIdx >= 0 && minDistance < 120.0) {
        [self handleSeekToLyricIndex:closestIdx inView:g_currentKaraokeLabels[closestIdx]];
    }
}

- (void)onNowPlayingCardTapped:(UITapGestureRecognizer *)gesture {
    g_lastUserLyricsInteractionTime = [NSDate timeIntervalSinceReferenceDate];
    if (!g_currentKaraokeItems || g_currentKaraokeItems.count == 0) return;
    double curTime = getCurrentSpotifyPreciseTime();
    NSInteger activeIdx = 0;
    for (NSInteger i = 0; i < (NSInteger)g_currentKaraokeItems.count; i++) {
        if (g_currentKaraokeItems[i].time >= 0 && curTime >= g_currentKaraokeItems[i].time) {
            activeIdx = i;
        } else if (g_currentKaraokeItems[i].time >= 0) {
            break;
        }
    }
    [self handleSeekToLyricIndex:activeIdx inView:gesture.view];
}
@end

static UIFont *getSpotifyBoldFont(CGFloat size) {
    UIFont *f = [UIFont fontWithName:@"SpotifyMix-Bold" size:size];
    if (!f) f = [UIFont fontWithName:@"SpotifyMixUI-Bold" size:size];
    if (!f) f = [UIFont fontWithName:@"CircularSpUI-Bold" size:size];
    if (!f) f = [UIFont fontWithName:@"CircularSp-Bold" size:size];
    if (!f) f = [UIFont systemFontOfSize:size weight:UIFontWeightHeavy];
    return f;
}

static NSArray<AntiCensorLyricItem *> *parseLyricsForTrack(NSString *rawLrcOrText, double duration) {
    if (!rawLrcOrText || rawLrcOrText.length == 0) return nil;
    NSMutableArray<AntiCensorLyricItem *> *items = [NSMutableArray array];

    NSString *cleanText = [rawLrcOrText stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"];
    cleanText = [cleanText stringByReplacingOccurrencesOfString:@"\r" withString:@"\n"];

    NSRegularExpression *tagRegex = [NSRegularExpression regularExpressionWithPattern:@"\\[(\\d{1,2}):(\\d{2})(?:\\.(\\d{1,3}))?\\]" options:0 error:nil];
    NSArray<NSTextCheckingResult *> *matches = [tagRegex matchesInString:cleanText options:0 range:NSMakeRange(0, cleanText.length)];

    if (matches.count > 0) {
        // Текст до первого тега (если есть) — относится к 0.0s (начало песни)
        NSUInteger firstTagPos = matches[0].range.location;
        if (firstTagPos > 0) {
            NSString *preTag = [[cleanText substringToIndex:firstTagPos] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (preTag.length > 0) {
                AntiCensorLyricItem *it = [[AntiCensorLyricItem alloc] init];
                it.time = 0.0;
                it.text = preTag;
                [items addObject:it];
            }
        }

        for (NSUInteger mIdx = 0; mIdx < matches.count; mIdx++) {
            NSTextCheckingResult *m = matches[mIdx];
            int mins = [[cleanText substringWithRange:[m rangeAtIndex:1]] intValue];
            int secs = [[cleanText substringWithRange:[m rangeAtIndex:2]] intValue];
            double ms = 0.0;
            if ([m rangeAtIndex:3].location != NSNotFound) {
                NSString *msStr = [cleanText substringWithRange:[m rangeAtIndex:3]];
                ms = [msStr doubleValue] / pow(10.0, (double)msStr.length);
            }
            double tagTime = (mins * 60.0) + secs + ms;

            NSUInteger start = NSMaxRange(m.range);
            NSUInteger end = (mIdx + 1 < matches.count) ? matches[mIdx + 1].range.location : cleanText.length;
            if (end > start) {
                NSString *chunk = [cleanText substringWithRange:NSMakeRange(start, end - start)];
                NSArray *chunkLines = [chunk componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
                for (NSString *cl in chunkLines) {
                    NSString *trimmed = [cl stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                    if (trimmed.length > 0) {
                        AntiCensorLyricItem *it = [[AntiCensorLyricItem alloc] init];
                        it.time = tagTime;
                        it.text = trimmed;
                        [items addObject:it];
                    }
                }
            }
        }
    } else {
        NSArray *rawLines = [cleanText componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
        for (NSString *line in rawLines) {
            NSString *trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            if (trimmed.length > 0) {
                AntiCensorLyricItem *it = [[AntiCensorLyricItem alloc] init];
                it.time = -1.0;
                it.text = trimmed;
                [items addObject:it];
            }
        }

        if (items.count > 0) {
            double dur = duration > 10.0 ? duration : 180.0;
            double intro = MIN(5.0, dur * 0.04);
            double outro = MAX(dur - 8.0, dur * 0.94);
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
    }

    if (items.count == 0) return nil;

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
        if ([txt containsString:@"синхронизац"] ||
            [txt containsString:@"не синхронизирован"] ||
            [txt containsString:@"lyrics aren't synced"] ||
            [txt containsString:@"lyrics are not synced"] ||
            [txt containsString:@"not synced"]) {
            return lbl;
        }
    }
    for (UIView *sub in root.subviews) {
        UILabel *found = findUnsyncedLyricsIndicatorLabel(sub);
        if (found) return found;
    }
    return nil;
}

// Проверка: относится ли view к экрану плеера (Now Playing) с большой обложкой
static BOOL isViewPartOfNowPlayingPlayer(UIView *view) {
    if (!view) return NO;

    // Рекурсивный поиск большой обложки альбома (>= 150x150)
    // Экран слов НИКОГДА не имеет большой обложки альбома! На плеере она всегда есть!
    NSMutableArray *q = [NSMutableArray arrayWithObject:view];
    while (q.count > 0) {
        UIView *v = q.firstObject;
        [q removeObjectAtIndex:0];
        if ([v isKindOfClass:[UIImageView class]]) {
            CGSize sz = v.bounds.size;
            if (sz.width >= 150.0 && sz.height >= 150.0) {
                return YES;
            }
        }
        [q addObjectsFromArray:v.subviews];
    }
    return NO;
}

// Проверка: является ли scroll view полноэкранным экраном слов песни
static BOOL isFullScreenLyricsScrollView(UIScrollView *sv) {
    if (!sv || sv.hidden || sv.alpha < 0.05 || sv.window == nil) return NO;
    if (sv.tag == KARAOKE_CONTAINER_TAG) return NO;

    CGSize sz = sv.bounds.size;
    // Полноэкранный экран слов всегда крупный (высота > 300, ширина > 250)
    if (sz.height < 300.0 || sz.width < 250.0) return NO;

    // Должен быть виден на экране прямо сейчас
    CGRect rInWin = [sv convertRect:sv.bounds toView:nil];
    CGRect screenBounds = [UIScreen mainScreen].bounds;
    if (!CGRectIntersectsRect(rInWin, screenBounds)) return NO;
    if (rInWin.size.height < 250.0) return NO;

    // СТРОЖАЙШЕ: если сам скролл содержит большую обложку альбома — это плеер Now Playing, а НЕ экран слов!
    if (isViewPartOfNowPlayingPlayer(sv)) {
        return NO;
    }

    // СТРОЖАЙШЕ: если сам скролл содержит ползунок таймлайна UISlider — это плеер Now Playing!
    // (На экране слов UISlider находится внизу экрана в панели управления, а НЕ внутри списка строк)
    for (UIView *sub in sv.subviews) {
        if ([sub isKindOfClass:[UISlider class]]) return NO;
    }

    // СТРОЖАЙШЕ: проверяем, содержит ли этот скролл карточки плеера ("Сведения", "Credits", "Текст")
    // Если содержит — это основной экран плеера Now Playing, его нельзя заменять на караоке!
    for (UIView *sub in sv.subviews) {
        if ([sub isKindOfClass:[UILabel class]]) {
            NSString *t = [((UILabel *)sub).text lowercaseString];
            if ([t isEqualToString:@"сведения"] || [t isEqualToString:@"credits"] ||
                [t isEqualToString:@"рекомендации"] || [t isEqualToString:@"похожие треки"]) {
                return NO;
            }
        }
        if (sub.tag == NOWPLAYING_LYRICS_CARD_TAG) {
            return NO;
        }
    }

    // СТРОЖАЙШЕ: Исключаем главные экраны (Главная, Поиск, Медиатека)
    UIResponder *resp = sv;
    while (resp) {
        if ([resp isKindOfClass:[UIViewController class]]) {
            UIViewController *vc = (UIViewController *)resp;
            NSString *cls = NSStringFromClass([vc class]);
            if ([cls containsString:@"Search"] || [cls containsString:@"Home"] ||
                [cls containsString:@"Feed"] || [cls containsString:@"Browse"] ||
                [cls containsString:@"Library"] || [cls containsString:@"Collection"] ||
                [cls containsString:@"Hub"] || [cls containsString:@"Overview"] ||
                [cls containsString:@"YourLibrary"]) {
                return NO;
            }
        }
        if ([resp isKindOfClass:[UITabBarController class]]) {
            UITabBarController *tbc = (UITabBarController *)resp;
            if (!tbc.presentedViewController) return NO;
        }
        resp = resp.nextResponder;
    }

    // Проверяем: либо класс VC содержит "lyrics", либо класс view содержит "lyrics",
    // либо ТОЛЬКО внутри самого scroll view есть индикатор "синхронизация текста"
    BOOL hasLyricsIndicator = (findUnsyncedLyricsIndicatorLabel(sv) != nil);

    NSString *svCls = [NSStringFromClass([sv class]) lowercaseString];
    NSString *pCls = sv.superview ? [NSStringFromClass([sv.superview class]) lowercaseString] : @"";
    NSString *accId = sv.accessibilityIdentifier ? [sv.accessibilityIdentifier lowercaseString] : @"";
    BOOL classMentionsLyrics = ([svCls containsString:@"lyric"] || [pCls containsString:@"lyric"] || [accId containsString:@"lyric"]);

    BOOL vcMentionsLyrics = NO;
    UIResponder *res = sv;
    while (res) {
        if ([res isKindOfClass:[UIViewController class]]) {
            UIViewController *vc = (UIViewController *)res;
            NSString *cName = [NSStringFromClass([vc class]) lowercaseString];
            NSString *title = vc.title ? [vc.title lowercaseString] : @"";
            if ([cName containsString:@"lyric"] || [title containsString:@"lyric"]) {
                vcMentionsLyrics = YES;
                break;
            }
        }
        res = res.nextResponder;
    }

    if (classMentionsLyrics || vcMentionsLyrics || hasLyricsIndicator) {
        return YES;
    }

    return NO;
}

static UIScrollView *findLyricsScrollViewInView(UIView *win) {
    if (!win || win.hidden || win.alpha < 0.05) return nil;
    if (win.tag == KARAOKE_CONTAINER_TAG) return nil;

    // Ищем полноэкранный экран слов ТОЛЬКО среди представленных view controller'ов (modal / presented)
    UIViewController *topVC = getKeyAppWindow().rootViewController;
    while (topVC.presentedViewController && !topVC.presentedViewController.isBeingDismissed) {
        topVC = topVC.presentedViewController;
    }
    if (topVC && topVC.view && !topVC.view.hidden) {
        // Проверяем, что это модальный экран (не корневой таббар/навигация)
        if (topVC != getKeyAppWindow().rootViewController) {
            NSMutableArray *queue = [NSMutableArray arrayWithObject:topVC.view];
            while (queue.count > 0) {
                UIView *v = queue.firstObject;
                [queue removeObjectAtIndex:0];
                if ([v isKindOfClass:[UIScrollView class]] && v.tag != KARAOKE_CONTAINER_TAG) {
                    UIScrollView *sv = (UIScrollView *)v;
                    if (isFullScreenLyricsScrollView(sv)) {
                        return sv;
                    }
                }
                [queue addObjectsFromArray:v.subviews];
            }
        }
    }

    return nil;
}

static void hideUnsyncedLyricsIndicator(UIView *viewOrWin) {
    UIWindow *win = [viewOrWin isKindOfClass:[UIWindow class]] ? (UIWindow *)viewOrWin : viewOrWin.window;
    if (!win) win = getKeyAppWindow();
    UILabel *indicator = findUnsyncedLyricsIndicatorLabel(win ?: viewOrWin);
    if (indicator) {
        indicator.hidden = YES;
        indicator.alpha = 0.0f;

        UIView *badge = indicator.superview;
        // Скрываем ТОЛЬКО саму плашку индикатора (серую полоску), ни в коем случае не трогая шапку и кнопки!
        if (badge && badge != win && badge != win.rootViewController.view) {
            BOOL containsInteractiveElements = NO;
            BOOL containsOtherText = NO;
            for (UIView *sub in badge.subviews) {
                if ([sub isKindOfClass:[UIButton class]] || [sub isKindOfClass:[UIControl class]]) {
                    containsInteractiveElements = YES;
                    break;
                }
                if ([sub isKindOfClass:[UILabel class]] && sub != indicator) {
                    UILabel *otherLbl = (UILabel *)sub;
                    if (otherLbl.text.length > 0) {
                        containsOtherText = YES;
                        break;
                    }
                }
            }
            if (!containsInteractiveElements && !containsOtherText && badge.bounds.size.height < 50.0) {
                badge.hidden = YES;
                badge.alpha = 0.0f;
                badge.backgroundColor = [UIColor clearColor];
                if (badge.layer) {
                    badge.layer.opacity = 0.0f;
                }
            } else {
                badge.backgroundColor = [UIColor clearColor];
            }
        }
    }
}

// Гарантирует, что верхняя шапка (кнопка '⌵', название, артист) и нижняя панель управления плеером (Play/Pause, слайдер, Share, More) всегда видны и доступны!
static BOOL isRogueLyricsOrStreamElement(UIView *v) {
    if (!v || v.tag == KARAOKE_CONTAINER_TAG) return NO;

    // Слайдер таймлайна и компоненты прогресс-бара НИКОГДА не являются rogue-элементами!
    if ([v isKindOfClass:[UISlider class]]) return NO;
    NSString *clsName = NSStringFromClass([v class]);
    if ([clsName containsString:@"Slider"] || [clsName containsString:@"Progress"] || [clsName containsString:@"Track"]) {
        return NO;
    }

    NSString *acc = @"";
    if ([v isKindOfClass:[UIButton class]]) {
        UIButton *b = (UIButton *)v;
        acc = [NSString stringWithFormat:@"%@ %@ %@ %@",
            b.accessibilityLabel ?: @"",
            b.accessibilityIdentifier ?: @"",
            b.titleLabel.text ?: @"",
            b.currentTitle ?: @""];
    } else {
        acc = [NSString stringWithFormat:@"%@ %@ %@",
            v.accessibilityLabel ?: @"",
            v.accessibilityIdentifier ?: @"",
            clsName];
    }
    acc = [acc lowercaseString];

    // Глушим микрофон караоке и кнопку перевода
    if ([acc containsString:@"sing"] ||
        [acc containsString:@"vocal"] ||
        [acc containsString:@"karaoke"] ||
        [acc containsString:@"караоке"] ||
        [acc containsString:@"translat"] ||
        [acc containsString:@"перевод"]) {
        return YES;
    }

    // Глушим плашку "прямая трансляция"
    if ([acc containsString:@"трансляц"] ||
        [acc containsString:@"прямая"] ||
        [acc containsString:@"live broadcast"] ||
        [acc containsString:@"live stream"]) {
        return YES;
    }

    if ([v isKindOfClass:[UILabel class]]) {
        NSString *txt = [((UILabel *)v).text lowercaseString] ?: @"";
        if ([txt containsString:@"трансляц"] ||
            [txt containsString:@"прямая"] ||
            [txt containsString:@"live broadcast"] ||
            [txt containsString:@"live stream"] ||
            [txt containsString:@"синхронизац"] ||
            [txt containsString:@"не синхронизирован"]) {
            return YES;
        }
    }

    // Рекурсивно проверяем текст дочерних меток внутри контейнера на наличие "прямая трансляция"
    for (UIView *sub in v.subviews) {
        if ([sub isKindOfClass:[UILabel class]]) {
            NSString *st = [((UILabel *)sub).text lowercaseString] ?: @"";
            if ([st containsString:@"трансляц"] ||
                [st containsString:@"прямая"] ||
                [st containsString:@"live broadcast"] ||
                [st containsString:@"live stream"]) {
                return YES;
            }
        }
    }

    return NO;
}

// Гарантирует, что верхняя шапка и нижняя панель управления плеером (Play/Pause, слайдер, Share, More) всегда видны и доступны!
static void ensureHeaderAndChevronVisible(UIViewController *topVC) {
    if (!topVC || !topVC.view) return;
    CGFloat screenH = [UIScreen mainScreen].bounds.size.height;

    NSMutableArray *q = [NSMutableArray arrayWithObject:topVC.view];
    while (q.count > 0) {
        UIView *v = q.firstObject;
        [q removeObjectAtIndex:0];
        if (v.tag == KARAOKE_CONTAINER_TAG) continue;

        CGPoint ptInWin = [v convertPoint:CGPointZero toView:nil];

        // 0. Строго глушим элементы "прямая трансляция", микрофон караоке и перевод
        if (isRogueLyricsOrStreamElement(v)) {
            v.hidden = YES;
            v.alpha = 0.0f;
            v.userInteractionEnabled = NO;
            if (v.superview && v.superview != topVC.view && v.superview != topVC.view.window && v.superview.bounds.size.height < 50.0) {
                BOOL isSafeToHideParent = YES;
                for (UIView *sibling in v.superview.subviews) {
                    if ([sibling isKindOfClass:[UISlider class]] ||
                        [NSStringFromClass([sibling class]) containsString:@"Slider"] ||
                        [NSStringFromClass([sibling class]) containsString:@"Progress"]) {
                        isSafeToHideParent = NO;
                        break;
                    }
                }
                if (isSafeToHideParent) {
                    v.superview.hidden = YES;
                    v.superview.alpha = 0.0f;
                    v.superview.userInteractionEnabled = NO;
                }
            }
            continue;
        }

        // 1. Ползунок таймлайна UISlider / ProgressBar — ВСЕГДА ВИДИМ И АКТИВЕН!
        NSString *clsName = NSStringFromClass([v class]);
        BOOL isSliderOrProgress = ([v isKindOfClass:[UISlider class]] ||
                                   [clsName containsString:@"Slider"] ||
                                   [clsName containsString:@"Progress"] ||
                                   [clsName containsString:@"Track"]);
        if (isSliderOrProgress) {
            v.hidden = NO;
            v.alpha = 1.0f;
            v.userInteractionEnabled = YES;
            UIView *p = v.superview;
            while (p && p != topVC.view && p != topVC.view.window) {
                p.hidden = NO;
                p.alpha = 1.0f;
                p.userInteractionEnabled = YES;
                p = p.superview;
            }
            if (v.superview) {
                [v.superview bringSubviewToFront:v];
            }
        }

        // 2. Кнопки: верхняя навигация и нижние элементы плеера (Play/Pause, Share, More)
        if ([v isKindOfClass:[UIButton class]] || [v isKindOfClass:[UIControl class]]) {
            UIButton *btn = [v isKindOfClass:[UIButton class]] ? (UIButton *)v : nil;
            BOOL isTopHeader = (ptInWin.y < 140.0);
            BOOL isBottomControls = (ptInWin.y > screenH - 240.0);

            if (isTopHeader || isBottomControls) {
                v.hidden = NO;
                v.alpha = 1.0f;
                v.userInteractionEnabled = YES;

                if (isTopHeader && ptInWin.x < 120.0 && btn) {
                    [btn addTarget:[AntiCensorTapHandler sharedHandler] action:@selector(onChevronDismissTapped:) forControlEvents:UIControlEventTouchUpInside];
                }

                UIView *p = v.superview;
                while (p && p != topVC.view && p != topVC.view.window) {
                    p.hidden = NO;
                    p.alpha = 1.0f;
                    p.userInteractionEnabled = YES;
                    p = p.superview;
                }
                if (v.superview) {
                    [v.superview bringSubviewToFront:v];
                }
            }
        }

        // 3. Текстовые метки: шапка и нижние таймкоды
        if ([v isKindOfClass:[UILabel class]]) {
            UILabel *lbl = (UILabel *)v;
            BOOL isTopLabel = (ptInWin.y < 140.0 && lbl.font.pointSize < 24.0);
            // Ниже экрана (панель плеера) таймкоды трека (например "0:15", "-1:31")
            BOOL isBottomTimestamp = (ptInWin.y > screenH - 240.0 && [lbl.text containsString:@":"]);

            if (isTopLabel || isBottomTimestamp) {
                lbl.hidden = NO;
                lbl.alpha = 1.0f;
                UIView *p = lbl.superview;
                while (p && p != topVC.view && p != topVC.view.window) {
                    p.hidden = NO;
                    p.alpha = 1.0f;
                    p = p.superview;
                }
            }
        }

        [q addObjectsFromArray:v.subviews];
    }
}

// Рекурсивно скрывает нативный текст Spotify внутри scroll view, исключая наш караоке-контейнер и шапку навигации
static void hideOriginalLyricsViews(UIView *root) {
    if (!root || root.tag == KARAOKE_CONTAINER_TAG) return;
    NSMutableArray *q = [NSMutableArray arrayWithObject:root];
    while (q.count > 0) {
        UIView *v = q.firstObject;
        [q removeObjectAtIndex:0];
        if (v.tag == KARAOKE_CONTAINER_TAG) continue;

        // Никогда не скрываем кнопки и интерактивные элементы
        if ([v isKindOfClass:[UIButton class]] || [v isKindOfClass:[UIControl class]]) {
            continue;
        }

        // Никогда не скрываем слайдер и элементы таймлайна
        NSString *clsName = NSStringFromClass([v class]);
        if ([v isKindOfClass:[UISlider class]] || [clsName containsString:@"Slider"] || [clsName containsString:@"Progress"]) {
            continue;
        }

        if ([v isKindOfClass:[UICollectionViewCell class]]) {
            UIView *cv = ((UICollectionViewCell *)v).contentView;
            if (cv) {
                cv.alpha = 0.0f;
                [q addObjectsFromArray:cv.subviews];
            }
        }
        if ([v isKindOfClass:[UILabel class]] || [v isKindOfClass:[UITextView class]]) {
            UILabel *lbl = (UILabel *)v;
            // Проверяем: если метка находится в верхней шапке (y < 130 pt) и шрифт небольшой, это заголовок трека / артист! Не скрываем!
            CGPoint ptInWin = [v convertPoint:CGPointZero toView:nil];
            if (ptInWin.y < 130.0 && lbl.font.pointSize < 24.0) {
                continue;
            }
            v.hidden = YES;
            v.alpha = 0.0f;
        }
        [q addObjectsFromArray:v.subviews];
    }
}

// Рекурсивно восстанавливает нативный текст Spotify
static void restoreOriginalLyricsViews(UIView *root) {
    if (!root || root.tag == KARAOKE_CONTAINER_TAG) return;
    NSMutableArray *q = [NSMutableArray arrayWithObject:root];
    while (q.count > 0) {
        UIView *v = q.firstObject;
        [q removeObjectAtIndex:0];
        if (v.tag == KARAOKE_CONTAINER_TAG) continue;
        if ([v isKindOfClass:[UICollectionViewCell class]]) {
            UIView *cv = ((UICollectionViewCell *)v).contentView;
            if (cv) {
                cv.alpha = 1.0f;
                [q addObjectsFromArray:cv.subviews];
            }
        }
        if ([v isKindOfClass:[UILabel class]] || [v isKindOfClass:[UITextView class]]) {
            v.hidden = NO;
            v.alpha = 1.0f;
        }
        [q addObjectsFromArray:v.subviews];
    }
}

// Обновление карточки "Текст" в лайв-режиме на экране плеера (в точности то, что обвёл пользователь)
static void updateNowPlayingLyricsCard(UIView *win, double currentTime, NSString *userLyrics) {
    if (!userLyrics || userLyrics.length == 0) {
        if (g_activeNowPlayingCardLabel) {
            UIView *card = g_activeNowPlayingCardLabel.superview;
            [g_activeNowPlayingCardLabel removeFromSuperview];
            g_activeNowPlayingCardLabel = nil;
            if (card) {
                for (UIView *cur in card.subviews) {
                    if (cur.hidden) { cur.hidden = NO; cur.alpha = 1.0f; }
                }
            }
        }
        return;
    }

    if (!g_currentKaraokeItems || g_currentKaraokeItems.count == 0) return;

    // Собираем 4 строчки в лайв-формате в точности по дизайну карточки Spotify (Скриншот 3)
    NSInteger activeIdx = -1;
    for (NSInteger i = 0; i < (NSInteger)g_currentKaraokeItems.count; i++) {
        if (g_currentKaraokeItems[i].time >= 0 && currentTime >= g_currentKaraokeItems[i].time) {
            activeIdx = i;
        } else if (g_currentKaraokeItems[i].time >= 0) {
            break;
        }
    }

    NSInteger startIdx = (activeIdx >= 0) ? activeIdx : 0;
    NSMutableAttributedString *attrStr = [[NSMutableAttributedString alloc] init];
    NSMutableParagraphStyle *paraStyle = [[NSMutableParagraphStyle alloc] init];
    paraStyle.lineSpacing = 3.0;
    paraStyle.paragraphSpacing = 14.0;

    for (NSInteger k = startIdx; k < (NSInteger)g_currentKaraokeItems.count && k < startIdx + 4; k++) {
        NSString *line = g_currentKaraokeItems[k].text;
        if (!line || line.length == 0) continue;

        UIColor *color = (k == activeIdx) ? [UIColor whiteColor] : [UIColor blackColor];
        NSDictionary *attrs = @{
            NSFontAttributeName: getSpotifyBoldFont(19.0),
            NSForegroundColorAttributeName: color,
            NSParagraphStyleAttributeName: paraStyle
        };

        if (attrStr.length > 0) {
            [attrStr appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n"]];
        }
        [attrStr appendAttributedString:[[NSAttributedString alloc] initWithString:line attributes:attrs]];
    }
    if (attrStr.length == 0) return;

    CGFloat maxCardH = [UIScreen mainScreen].bounds.size.height * 0.65;
    UIWindow *parentWin = [win isKindOfClass:[UIWindow class]] ? (UIWindow *)win : win.window;
    UIView *rootView = parentWin.rootViewController.view;

    NSMutableArray *cQueue = [NSMutableArray arrayWithObject:win];
    while (cQueue.count > 0) {
        UIView *v = cQueue.firstObject;
        [cQueue removeObjectAtIndex:0];
        if ([v isKindOfClass:[UILabel class]]) {
            UILabel *l = (UILabel *)v;
            NSString *t = [l.text lowercaseString];
            if ([t isEqualToString:@"текст"] || [t isEqualToString:@"lyrics"]) {
                UIView *trueCard = nil;
                UIView *p = l.superview;
                while (p && p != win && p != rootView) {
                    if (p.bounds.size.height >= 180.0 && p.bounds.size.height <= maxCardH) {
                        trueCard = p;
                        break;
                    }
                    p = p.superview;
                }
                if (!trueCard) {
                    p = l.superview;
                    while (p && p != win && p != rootView) {
                        if (p.bounds.size.height >= 110.0 && p.bounds.size.height <= maxCardH) {
                            trueCard = p;
                            break;
                        }
                        p = p.superview;
                    }
                }
                UIView *card = trueCard;

                // Проверяем, что это действительно карточка плеера, а не корневой экран приложения
                if (card && card != win && card != rootView) {

                    CGRect lInCard = [l convertRect:l.bounds toView:card];
                    CGFloat padX = (lInCard.origin.x > 0 && lInCard.origin.x < 50.0) ? lInCard.origin.x : 16.0;
                    CGFloat topY = CGRectGetMaxY(lInCard) + 8.0;
                    CGFloat cardW = card.bounds.size.width;
                    if (cardW < 100.0) cardW = [UIScreen mainScreen].bounds.size.width - 32.0;
                    CGFloat cardH = card.bounds.size.height;
                    if (cardH < 100.0) cardH = 240.0;
                    CGFloat w = cardW - (padX * 2.0);
                    CGFloat h = cardH - topY - 12.0;
                    if (h < 60.0) h = 160.0;

                    // Создаем или находим наш собственный лейбл лайв-текста внутри карточки
                    UILabel *cardLbl = [card viewWithTag:NOWPLAYING_LYRICS_CARD_TAG];
                    if (!cardLbl) {
                        cardLbl = [[UILabel alloc] initWithFrame:CGRectMake(padX, topY, w, h)];
                        cardLbl.tag = NOWPLAYING_LYRICS_CARD_TAG;
                        cardLbl.numberOfLines = 0;
                        cardLbl.lineBreakMode = NSLineBreakByWordWrapping;
                        cardLbl.backgroundColor = [UIColor clearColor];
                        cardLbl.userInteractionEnabled = YES;

                        UITapGestureRecognizer *cardTap = [[UITapGestureRecognizer alloc] initWithTarget:[AntiCensorTapHandler sharedHandler] action:@selector(onNowPlayingCardTapped:)];
                        cardTap.cancelsTouchesInView = NO;
                        [cardLbl addGestureRecognizer:cardTap];

                        [card addSubview:cardLbl];
                    }

                    // ВСЕГДА актуализируем фрейм, полностью прозрачный фон (без серого квадрата!) и атрибутированный текст
                    cardLbl.frame = CGRectMake(padX, topY, w, h);
                    cardLbl.backgroundColor = [UIColor clearColor];
                    cardLbl.hidden = NO;
                    cardLbl.alpha = 1.0f;
                    cardLbl.attributedText = attrStr;
                    [card bringSubviewToFront:cardLbl];
                    g_activeNowPlayingCardLabel = cardLbl;

                    // Скрываем ТОЛЬКО нативные текстовые лейблы Spotify внутри карточки,
                    // НЕ трогая кнопки действий (поделиться, развернуть), жесты и контейнеры!
                    NSMutableArray *cardQueue = [NSMutableArray arrayWithObject:card];
                    while (cardQueue.count > 0) {
                        UIView *cur = cardQueue.firstObject;
                        [cardQueue removeObjectAtIndex:0];
                        if (cur == cardLbl || cur == l) continue;
                        if ([cur isKindOfClass:[UIButton class]] || [cur isKindOfClass:[UIControl class]]) {
                            continue; // Кнопки шаринга и перехода в полноэкранный режим не трогаем!
                        }
                        if ([cur isKindOfClass:[UILabel class]] || [cur isKindOfClass:[UITextView class]]) {
                            cur.hidden = YES;
                            cur.alpha = 0.0f;
                        } else {
                            [cardQueue addObjectsFromArray:cur.subviews];
                        }
                    }
                    return;
                }
            }
        }
        [cQueue addObjectsFromArray:v.subviews];
    }
}

static void checkAndSyncLyricsOnScreen(void) {
    // 0. Если открыт алерт/диалог (UIAlertController) или экран закрывается (dismiss), даем ему спокойно работать/закрыться
    UIWindow *keyWin = getKeyAppWindow();
    UIViewController *top = keyWin.rootViewController;
    while (top.presentedViewController) {
        if (top.isBeingDismissed) return;
        if ([top.presentedViewController isKindOfClass:[UIAlertController class]] ||
            [top.presentedViewController isKindOfClass:[UIActivityViewController class]] ||
            [top.presentedViewController isKindOfClass:[UIDocumentPickerViewController class]]) {
            return; // СТРОЖАЙШЕ: НИКОГДА не инжектим караоке, когда открыт диалог/алерт!
        }
        top = top.presentedViewController;
    }
    if (top && (top.isBeingDismissed || [top isKindOfClass:[UIAlertController class]])) {
        return;
    }

    // 0.1 СТРОЖАЙШЕ: проверяем, добавил ли пользователь кастомный текст для этого трека
    NSString *userLyrics = getLyricsForTrack(currentActiveSpotifyTrackURI, currentActiveSpotifyTrackTitle, currentActiveSpotifyTrackArtist);
    if (!userLyrics || userLyrics.length == 0) {
        // Пользователь НЕ добавлял кастомный текст для этого трека!
        // СПОТИФАЕВСКИЕ ТРЕКИ НЕ ТРОГАЕМ ВООБЩЕ!
        if (g_activeNowPlayingCardLabel) {
            UIView *card = g_activeNowPlayingCardLabel.superview;
            [g_activeNowPlayingCardLabel removeFromSuperview];
            g_activeNowPlayingCardLabel = nil;
            if (card) {
                for (UIView *cur in card.subviews) {
                    if (cur.hidden) { cur.hidden = NO; cur.alpha = 1.0f; }
                }
            }
        }
        if (g_activeKaraokeContainer) {
            UIView *p = g_activeKaraokeContainer.superview;
            [g_activeKaraokeContainer removeFromSuperview];
            g_activeKaraokeContainer = nil;
            if (p) {
                for (UIView *cur in p.subviews) {
                    if (cur.hidden) { cur.hidden = NO; cur.alpha = 1.0f; cur.userInteractionEnabled = YES; }
                }
                restoreOriginalLyricsViews(p);
            }
        }

        // Гарантированно убираем любые старые оверлеи текста из окон
        NSArray *windows = [UIApplication sharedApplication].windows;
        for (UIWindow *win in windows) {
            if (!win) continue;
            UIView *ex = [win viewWithTag:KARAOKE_CONTAINER_TAG];
            if (ex) {
                if (ex.superview) {
                    for (UIView *sub in ex.superview.subviews) {
                        sub.hidden = NO;
                        sub.alpha = 1.0f;
                        sub.userInteractionEnabled = YES;
                    }
                    restoreOriginalLyricsViews(ex.superview);
                }
                [ex removeFromSuperview];
            }
            UIView *cardPreview = [win viewWithTag:NOWPLAYING_LYRICS_CARD_TAG];
            if (cardPreview) {
                UIView *card = cardPreview.superview;
                if (card) {
                    NSMutableArray *rq = [NSMutableArray arrayWithObject:card];
                    while (rq.count > 0) {
                        UIView *cur = rq.firstObject;
                        [rq removeObjectAtIndex:0];
                        if (cur.hidden) {
                            cur.hidden = NO;
                            cur.alpha = 1.0f;
                        }
                        [rq addObjectsFromArray:cur.subviews];
                    }
                }
                [cardPreview removeFromSuperview];
            }
        }
        g_currentKaraokeTrackKey = nil;
        g_currentKaraokeItems = nil;
        g_currentKaraokeLabels = nil;
        g_lastActiveKaraokeIdx = -1;
        return;
    }

    // 1. Текущее время и трек
    double currentTime = getCurrentSpotifyPreciseTime();
    double duration = 0.0;
    if (ourAudioPlayer && ourAudioPlayer.currentItem) {
        CMTime d = ourAudioPlayer.currentItem.duration;
        if (CMTIME_IS_VALID(d) && !CMTIME_IS_INDEFINITE(d)) {
            duration = CMTimeGetSeconds(d);
        }
    }
    if (duration <= 1.0) {
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

    // Подгружаем текст песни для текущего трека (если еще не загружен)
    if (!g_currentKaraokeItems || ![trackKey isEqualToString:g_currentKaraokeTrackKey]) {
        g_currentKaraokeTrackKey = trackKey;
        g_lastActiveKaraokeIdx = -1;
        g_currentKaraokeItems = parseLyricsForTrack(userLyrics, duration);
    }

    NSArray *windows = [UIApplication sharedApplication].windows;
    for (UIWindow *win in windows) {
        if (!win || win.hidden) continue;

        // 2. ВСЕГДА обновляем карточку "Текст" на экране плеера в реальном времени!
        updateNowPlayingLyricsCard(win, currentTime, userLyrics);

        // 3. Ищем ТОЛЬКО специализированный полноэкранный экран слов песни
        UIScrollView *scrollView = findLyricsScrollViewInView(win);
        if (!scrollView) continue;

        // 4. Полноэкранный караоке вид точь-в-точь по дизайну Spotify (Скриншот 4)
        CGFloat screenW = [UIScreen mainScreen].bounds.size.width;
        CGFloat screenH = [UIScreen mainScreen].bounds.size.height;

        UIViewController *topVC = win.rootViewController;
        BOOL alertActive = NO;
        while (topVC.presentedViewController && !topVC.presentedViewController.isBeingDismissed) {
            if ([topVC.presentedViewController isKindOfClass:[UIAlertController class]] ||
                [topVC.presentedViewController isKindOfClass:[UIActivityViewController class]] ||
                [topVC.presentedViewController isKindOfClass:[UIDocumentPickerViewController class]]) {
                alertActive = YES;
                break;
            }
            topVC = topVC.presentedViewController;
        }
        if (alertActive || !topVC || !topVC.view || [topVC isKindOfClass:[UIAlertController class]]) continue;

        // Находим настоящий LyricsViewController, владеющий нативным скроллом
        UIViewController *lyricsVC = nil;
        UIResponder *resp = scrollView;
        while (resp) {
            if ([resp isKindOfClass:[UIViewController class]]) {
                lyricsVC = (UIViewController *)resp;
                break;
            }
            resp = resp.nextResponder;
        }
        if (!lyricsVC) lyricsVC = topVC;
        if ([lyricsVC isKindOfClass:[UIAlertController class]]) continue;

        CGRect sf = [scrollView convertRect:scrollView.bounds toView:lyricsVC.view];
        CGFloat topY = sf.origin.y;
        if (topY < 60.0 || topY > 160.0) topY = 115.0;
        // Гарантируем, что оверлей караоке строго заканчивается над нижней панелью плеера (Share, Slider, Play)
        CGFloat maxH = screenH - 290.0 - topY;
        CGFloat height = sf.size.height;
        if (height > maxH || height < 100.0) height = maxH;
        if (height < 200.0) height = 280.0;

        CGRect targetFrame = CGRectMake(0, topY, screenW, height);

        UIView *existingContainer = [lyricsVC.view viewWithTag:KARAOKE_CONTAINER_TAG];
        if (!existingContainer && g_activeKaraokeContainer && g_activeKaraokeContainer.window != nil) {
            existingContainer = g_activeKaraokeContainer;
        }

        if (existingContainer) {
            if (existingContainer.superview != lyricsVC.view) {
                [existingContainer removeFromSuperview];
                existingContainer = nil;
                g_activeKaraokeContainer = nil;
            } else {
                if (!CGRectEqualToRect(existingContainer.frame, targetFrame)) {
                    existingContainer.frame = targetFrame;
                }
                existingContainer.clipsToBounds = YES;
                hideOriginalLyricsViews(scrollView);
                hideUnsyncedLyricsIndicator(win);
                ensureHeaderAndChevronVisible(lyricsVC);
            }
        }

        if (!existingContainer || ![trackKey isEqualToString:g_currentKaraokeTrackKey]) {
            hideUnsyncedLyricsIndicator(win);

            if (g_currentKaraokeItems && g_currentKaraokeItems.count > 0) {
                if (existingContainer) {
                    [existingContainer removeFromSuperview];
                    existingContainer = nil;
                }

                CGFloat viewW = screenW;
                CGFloat padX = 24.0;
                CGFloat contentW = viewW - (padX * 2);
                CGFloat curY = 24.0;

                // Создаем собственный UIScrollView оверлей прямо в lyricsVC.view между шапкой и панелью плеера
                UIScrollView *containerScroll = [[UIScrollView alloc] initWithFrame:targetFrame];
                containerScroll.tag = KARAOKE_CONTAINER_TAG;
                containerScroll.backgroundColor = [UIColor clearColor];
                containerScroll.userInteractionEnabled = YES;
                containerScroll.scrollEnabled = YES;
                containerScroll.bounces = YES;
                containerScroll.alwaysBounceVertical = YES;
                containerScroll.delaysContentTouches = NO;
                containerScroll.canCancelContentTouches = YES;
                containerScroll.showsVerticalScrollIndicator = YES;
                containerScroll.clipsToBounds = YES;
                if (@available(iOS 11.0, *)) {
                    containerScroll.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
                }
                containerScroll.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
                containerScroll.contentInset = UIEdgeInsetsMake(0, 0, 80.0, 0);

                UITapGestureRecognizer *lyricsTap = [[UITapGestureRecognizer alloc] initWithTarget:[AntiCensorTapHandler sharedHandler] action:@selector(onLyricsContainerTapped:)];
                lyricsTap.delegate = [AntiCensorTapHandler sharedHandler];
                lyricsTap.cancelsTouchesInView = NO;
                [containerScroll addGestureRecognizer:lyricsTap];

                g_currentKaraokeLabels = [NSMutableArray array];

                for (NSUInteger i = 0; i < g_currentKaraokeItems.count; i++) {
                    AntiCensorLyricItem *it = g_currentKaraokeItems[i];
                    UILabel *lbl = [[UILabel alloc] init];
                    lbl.numberOfLines = 0;
                    lbl.lineBreakMode = NSLineBreakByWordWrapping;
                    lbl.font = getSpotifyBoldFont(24.0);
                    lbl.textColor = [UIColor blackColor];
                    lbl.alpha = 1.0f;
                    lbl.transform = CGAffineTransformIdentity;
                    lbl.text = it.text;
                    lbl.userInteractionEnabled = YES;
                    lbl.tag = i;

                    UITapGestureRecognizer *lineTap = [[UITapGestureRecognizer alloc] initWithTarget:[AntiCensorTapHandler sharedHandler] action:@selector(onKaraokeLineTapped:)];
                    lineTap.delegate = [AntiCensorTapHandler sharedHandler];
                    lineTap.cancelsTouchesInView = NO;
                    [lbl addGestureRecognizer:lineTap];

                    CGSize maxS = CGSizeMake(contentW, CGFLOAT_MAX);
                    CGRect b = [it.text boundingRectWithSize:maxS
                                                     options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading
                                                  attributes:@{NSFontAttributeName: lbl.font}
                                                     context:nil];
                    CGFloat lineH = MAX(28.0, ceil(b.size.height));
                    lbl.frame = CGRectMake(padX, curY, contentW, lineH);
                    [containerScroll addSubview:lbl];
                    [g_currentKaraokeLabels addObject:lbl];

                    curY += lineH + 16.0;
                }

                curY += 80.0;
                containerScroll.contentSize = CGSizeMake(viewW, curY);

                hideOriginalLyricsViews(scrollView);

                [lyricsVC.view addSubview:containerScroll];
                g_activeKaraokeContainer = containerScroll;

                if (lyricsVC) {
                    ensureHeaderAndChevronVisible(lyricsVC);
                }
            }
        }

        


// 5. Актуализация активной строки в реальном времени
        if (g_currentKaraokeItems && g_currentKaraokeLabels.count == g_currentKaraokeItems.count) {
            NSInteger activeIdx = -1;
            for (NSInteger i = 0; i < (NSInteger)g_currentKaraokeItems.count; i++) {
                if (g_currentKaraokeItems[i].time >= 0 && currentTime >= g_currentKaraokeItems[i].time) {
                    activeIdx = i;
                } else if (g_currentKaraokeItems[i].time >= 0) {
                    break;
                }
            }

            UIScrollView *activeScroll = [g_activeKaraokeContainer isKindOfClass:[UIScrollView class]] ? (UIScrollView *)g_activeKaraokeContainer : scrollView;
            if (activeScroll.isDragging || activeScroll.isDecelerating) {
                g_lastUserLyricsInteractionTime = [NSDate timeIntervalSinceReferenceDate];
            }

            // СКРОЛЛИМ И ОБНОВЛЯЕМ ТОЛЬКО ПРИ РЕАЛЬНОЙ СМЕНЕ СТРОКИ! (Исключает вечный ролл!)
            if (activeIdx != g_lastActiveKaraokeIdx) {
                g_lastActiveKaraokeIdx = activeIdx;
                [UIView animateWithDuration:0.25 animations:^{
                    for (NSUInteger i = 0; i < g_currentKaraokeLabels.count; i++) {
                        UILabel *lbl = g_currentKaraokeLabels[i];
                        if ((NSInteger)i == activeIdx) {
                            lbl.textColor = [UIColor whiteColor];
                            lbl.alpha = 1.0f;
                            lbl.transform = CGAffineTransformIdentity;
                        } else {
                            lbl.textColor = [UIColor blackColor];
                            lbl.alpha = 1.0f;
                            lbl.transform = CGAffineTransformIdentity;
                        }
                    }
                }];

                NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
                BOOL userRecentlyInteracted = (now - g_lastUserLyricsInteractionTime < 4.5);

                // Плавное следование скролла за активной строкой (только один раз при смене строки)
                if (!userRecentlyInteracted && !activeScroll.isDragging && !activeScroll.isDecelerating
                    && activeIdx >= 0 && activeIdx < (NSInteger)g_currentKaraokeLabels.count) {
                    UILabel *actLbl = g_currentKaraokeLabels[activeIdx];
                    CGFloat targetY = actLbl.frame.origin.y - (activeScroll.bounds.size.height * 0.28);
                    if (targetY < 0) targetY = 0;
                    CGFloat maxY = activeScroll.contentSize.height - activeScroll.bounds.size.height + activeScroll.contentInset.bottom;
                    if (maxY < 0) maxY = 0;
                    if (targetY > maxY) targetY = maxY;
                    [activeScroll setContentOffset:CGPointMake(0, targetY) animated:YES];
                }
            }
        }

        break;
    }
}

static void cleanupRogueBanners(void);
@class AntiCensorNowPlayingViewController;
static void presentAlbumNowPlayingScreen(int trackIdx);


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
        lastKnownSpotifyPosition = ourTime;
        lastSpotifyPositionTimestamp = [NSDate timeIntervalSinceReferenceDate];
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
    applyMuteStateToAllUnits();

    AVAudioSession *session = [AVAudioSession sharedInstance];
    [session setCategory:AVAudioSessionCategoryPlayback
             withOptions:AVAudioSessionCategoryOptionMixWithOthers |
                         AVAudioSessionCategoryOptionAllowBluetooth |
                         AVAudioSessionCategoryOptionAllowAirPlay
                   error:nil];
    [session setActive:YES error:nil];

    AVPlayerItem *item = [AVPlayerItem playerItemWithURL:streamUrl];
    if (@available(iOS 10.0, *)) {
        item.preferredForwardBufferDuration = 0.5; // Fast buffering for instant audio start!
    }

    if (!g_playerObserver) {
        g_playerObserver = [[AntiCensorPlayerObserver alloc] init];
    }

    if (ourAudioPlayer) {
        if (isObservingPlayerItem) {
            @try { [ourAudioPlayer.currentItem removeObserver:g_playerObserver forKeyPath:@"status" context:kStatusObserverContext]; } @catch (id ex) {}
            isObservingPlayerItem = NO;
        }
        AVPlayer *oldP = ourAudioPlayer;
        [oldP pause];
        ourAudioPlayer = nil;
    }

    [item addObserver:g_playerObserver forKeyPath:@"status" options:NSKeyValueObservingOptionNew context:kStatusObserverContext];
    isObservingPlayerItem = YES;
    ourAudioPlayer = [AVPlayer playerWithPlayerItem:item];
    if (@available(iOS 10.0, *)) {
        ourAudioPlayer.automaticallyWaitsToMinimizeStalling = NO;
    }

    if (initialPosition > 1.0) {
        [ourAudioPlayer seekToTime:CMTimeMakeWithSeconds(initialPosition, NSEC_PER_SEC)];
    }

    isSpotifyCurrentlyPlaying = YES;
    ourAudioPlayer.volume = 1.0f; // Instant full volume, no silent fade-in delay!
    [ourAudioPlayer play];
    updateNowPlayingCenter();
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

            // МГНОВЕННО удаляем любые старые оверлеи текста из окон при смене трека!
            dispatch_async(dispatch_get_main_queue(), ^{
                if (g_activeNowPlayingCardLabel) {
                    UIView *card = g_activeNowPlayingCardLabel.superview;
                    [g_activeNowPlayingCardLabel removeFromSuperview];
                    g_activeNowPlayingCardLabel = nil;
                    if (card) {
                        for (UIView *cur in card.subviews) {
                            if (cur.hidden) { cur.hidden = NO; cur.alpha = 1.0f; }
                        }
                    }
                }
                if (g_activeKaraokeContainer) {
                    UIView *p = g_activeKaraokeContainer.superview;
                    [g_activeKaraokeContainer removeFromSuperview];
                    g_activeKaraokeContainer = nil;
                    if (p) {
                        for (UIView *cur in p.subviews) {
                            if (cur.hidden) { cur.hidden = NO; cur.alpha = 1.0f; }
                        }
                    }
                }

                NSArray *windows = [UIApplication sharedApplication].windows;
                for (UIWindow *win in windows) {
                    if (!win) continue;
                    UIView *ex = [win viewWithTag:KARAOKE_CONTAINER_TAG];
                    if (ex) {
                        if ([ex.superview isKindOfClass:[UIScrollView class]]) {
                            UIScrollView *sv = (UIScrollView *)ex.superview;
                            for (UIView *sub in sv.subviews) {
                                sub.hidden = NO;
                                sub.alpha = 1.0f;
                                sub.userInteractionEnabled = YES;
                            }
                        }
                        [ex removeFromSuperview];
                    }
                    UIView *cardPreview = [win viewWithTag:NOWPLAYING_LYRICS_CARD_TAG];
                    if (cardPreview) {
                        UIView *card = cardPreview.superview;
                        if (card) {
                            NSMutableArray *rq = [NSMutableArray arrayWithObject:card];
                            while (rq.count > 0) {
                                UIView *cur = rq.firstObject;
                                [rq removeObjectAtIndex:0];
                                if (cur.hidden) {
                                    cur.hidden = NO;
                                    cur.alpha = 1.0f;
                                }
                                [rq addObjectsFromArray:cur.subviews];
                            }
                        }
                        [cardPreview removeFromSuperview];
                    }
                }
            });
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

    NSString *trackKey = currentActiveSpotifyTrackURI ?: currentActiveSpotifyTrackTitle;

    // Заменённый трек обнаружен! Если этот трек ещё не играет — ВСЕГДА запускаем воспроизведение!
    if (!ourAudioPlayer || ![trackKey isEqualToString:currentPlayingKey]) {
        isMutingSpotify = YES;
        applyMuteStateToAllUnits();
        isSpotifyCurrentlyPlaying = YES;
        startReplacementAudio(trackKey, repUrl, position);
        return;
    }

    // Если трек уже играет — уважаем ручную паузу/воспроизведение пользователя
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

    if (ourAudioPlayer) {
        if (hasElapsed && ourAudioPlayer) {
            NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
            NSTimeInterval timeSinceForeground = now - g_lastForegroundOrScreenTransitionTimestamp;
            // КРИТИЧЕСКИЙ ФИКС ДЛЯ DYNAMIC ISLAND:
            // Когда пользователь заходит в Спотик через Dynamic Island или экран блокировки,
            // Spotify просыпается из фона и шлёт рассинхронизированный таймкод (~5 сек назад или вперед).
            // Запрещаем перемотку в первые 4.0 сек после выхода из фона!
            if (timeSinceForeground < 4.0) {
                updateNowPlayingCenter();
            } else {
                double ourPos = CMTimeGetSeconds(ourAudioPlayer.currentTime);
                BOOL isOurOwnEcho = (now - g_lastUserManualLyricsSeekTimestamp < 2.5);
                if (!isOurOwnEcho && !g_isPlayerSeeking) {
                    double diff = fabs(position - ourPos);
                    // Перематываем только при реальном значительном ручном сдвиге пользователем (> 0.5s)
                    if (diff > 0.5) {
                        safeSeekPlayerToTime(position);
                    }
                }
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
            performAntiCensorCloudSync();
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

static void performAntiCensorCloudSync(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIViewController *topVC = getKeyAppWindow().rootViewController;
        while (topVC.presentedViewController && !topVC.presentedViewController.isBeingDismissed) {
            topVC = topVC.presentedViewController;
        }
        if (!topVC) return;

        UIAlertController *loadingAlert = [UIAlertController alertControllerWithTitle:@"🌐 AntiCensor Cloud"
                                                                              message:@"Подключение к серверу и загрузка данных с ПК...\n\n(Пожалуйста, подождите)"
                                                                       preferredStyle:UIAlertControllerStyleAlert];

        UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
        spinner.translatesAutoresizingMaskIntoConstraints = NO;
        [spinner startAnimating];
        [loadingAlert.view addSubview:spinner];
        [NSLayoutConstraint activateConstraints:@[
            [spinner.centerXAnchor constraintEqualToAnchor:loadingAlert.view.centerXAnchor],
            [spinner.bottomAnchor constraintEqualToAnchor:loadingAlert.view.bottomAnchor constant:-20.0]
        ]];

        [topVC presentViewController:loadingAlert animated:YES completion:^{
            syncPullFromCloud(^(BOOL success, NSUInteger count) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [spinner stopAnimating];
                    [spinner removeFromSuperview];
                    if (success) {
                        loadingAlert.title = @"🌐 AntiCensor Cloud";
                        loadingAlert.message = [NSString stringWithFormat:@"✓ Синхронизация успешно завершена!\nВсего элементов в базе: %lu\n(Тексты и замены актуализированы)", (unsigned long)count];
                        g_currentKaraokeTrackKey = nil;
                        g_currentKaraokeItems = nil;
                        g_currentKaraokeLabels = nil;
                        g_lastActiveKaraokeIdx = -1;
                        checkAndSyncLyricsOnScreen();
                    } else {
                        loadingAlert.title = @"🌐 Ошибка синхронизации";
                        loadingAlert.message = @"Не удалось подключиться к облачному серверу.\nПроверьте подключение к интернету или попробуйте ещё раз через несколько секунд.";
                    }
                    [loadingAlert addAction:[UIAlertAction actionWithTitle:@"Отлично" style:UIAlertActionStyleDefault handler:nil]];
                });
            });
        }];
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
            performAntiCensorCloudSync();
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
            performAntiCensorCloudSync();
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

        // 5.1 Удалить кастомный текст (если есть) прямо из главного диалога
        UIAlertAction *removeLyricsAction = nil;
        if (existingLyrics.length > 0) {
            removeLyricsAction = [UIAlertAction actionWithTitle:@"🗑️ Сбросить / Удалить текст песни"
                                                          style:UIAlertActionStyleDestructive
                                                        handler:^(UIAlertAction * _Nonnull a) {
                if (uri && uri.length > 5) saveLyricsForTrack(uri, nil);
                if (displayTrack.length > 1) saveLyricsForTrack(displayTrack, nil);
                if (title && title.length > 1) saveLyricsForTrack(title, nil);
                if (artist && title) {
                    saveLyricsForTrack([NSString stringWithFormat:@"%@ - %@", artist, title], nil);
                    saveLyricsForTrack([NSString stringWithFormat:@"%@ — %@", artist, title], nil);
                }
                g_currentKaraokeTrackKey = nil;
                g_currentKaraokeItems = nil;
                g_currentKaraokeLabels = nil;
                g_lastActiveKaraokeIdx = -1;
                checkAndSyncLyricsOnScreen();
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
        if (removeLyricsAction) [sheet addAction:removeLyricsAction];
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

static BOOL isContextMenuActionLabel(NSString *str) {
    if (!str || str.length == 0) return YES;
    NSString *s = [str lowercaseString];
    if ([s containsString:@"очеред"] ||
        [s containsString:@"queue"] ||
        [s containsString:@"плейлист"] ||
        [s containsString:@"playlist"] ||
        [s containsString:@"поделиться"] ||
        [s containsString:@"share"] ||
        [s containsString:@"радио"] ||
        [s containsString:@"radio"] ||
        [s containsString:@"сведения"] ||
        [s containsString:@"credits"] ||
        [s containsString:@"нравится"] ||
        [s containsString:@"like"] ||
        [s containsString:@"любим"] ||
        [s containsString:@"альбом"] ||
        [s containsString:@"album"] ||
        [s containsString:@"исполнител"] ||
        [s containsString:@"artist"] ||
        [s containsString:@"скрыть"] ||
        [s containsString:@"hide"] ||
        [s containsString:@"исключить"] ||
        [s containsString:@"exclude"] ||
        [s containsString:@"джем"] ||
        [s containsString:@"jam"] ||
        [s containsString:@"текст песни"] ||
        [s containsString:@"lyrics"] ||
        [s containsString:@"пожаловаться"] ||
        [s containsString:@"report"] ||
        [s containsString:@"удалить"] ||
        [s containsString:@"remove"] ||
        [s containsString:@"загрузить"] ||
        [s containsString:@"download"] ||
        [s containsString:@"отмена"] ||
        [s containsString:@"cancel"]) {
        return YES;
    }
    return NO;
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
                if (!isContextMenuActionLabel(l.text)) {
                    CGPoint pt = [l convertPoint:CGPointZero toView:container];
                    if (pt.y < 140.0) {
                        [labels addObject:l];
                    }
                }
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

    // Если всё ещё пусто, безопасно берем текущий играющий трек Spotify
    if (!*outTitle && currentActiveSpotifyTrackTitle.length > 0) {
        *outTitle = currentActiveSpotifyTrackTitle;
    }
    if (!*outArtist && currentActiveSpotifyTrackArtist.length > 0) {
        *outArtist = currentActiveSpotifyTrackArtist;
    }
    if (!*outURI && currentActiveSpotifyTrackURI.length > 0) {
        *outURI = currentActiveSpotifyTrackURI;
    }
}

static void anticensor_bannerCloseTapped(UIViewController *callerVC, SEL _cmd, UIButton *sender) {
    UIView *banner = sender.superview;
    while (banner && banner.tag != 778899 && banner.superview) {
        banner = banner.superview;
    }
    if (banner) {
        [UIView animateWithDuration:0.2 animations:^{
            banner.alpha = 0.0;
        } completion:^(BOOL finished) {
            [banner removeFromSuperview];
        }];
    }
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
    NSString *userLyrics = getLyricsForTrack(currentActiveSpotifyTrackURI, currentActiveSpotifyTrackTitle, currentActiveSpotifyTrackArtist);
    BOOL hasUserLyrics = (userLyrics && userLyrics.length > 0);

    NSArray *windows = [UIApplication sharedApplication].windows;

    // 1. Detect if the user is currently on the album screen
    s_isAlbumScreenVisible = NO;
    for (UIWindow *win in windows) {
        if (!win || win.hidden) continue;
        NSMutableArray *queue = [NSMutableArray arrayWithObject:win];
        while (queue.count > 0) {
            UIView *v = queue.firstObject;
            [queue removeObjectAtIndex:0];
            if ([v isKindOfClass:[UILabel class]]) {
                NSString *txt = [((UILabel *)v).text lowercaseString] ?: @"";
                if ([txt containsString:@"coll. of $hit"] || [txt containsString:@"1f1ocxkj43a1qy9qqfnfux"]) {
                    s_isAlbumScreenVisible = YES;
                    break;
                }
            }
            [queue addObjectsFromArray:v.subviews];
        }
        if (s_isAlbumScreenVisible) break;
    }

    // 2. Process all views: karaoke, big play button, ungreying cells, and mini-player updates
    for (UIWindow *win in windows) {
        if (!win) continue;
        NSMutableArray *queue = [NSMutableArray arrayWithObject:win];
        while (queue.count > 0) {
            UIView *v = queue.firstObject;
            [queue removeObjectAtIndex:0];

            if (v.tag == KARAOKE_CONTAINER_TAG) {
                if (!hasUserLyrics || (v != g_activeKaraokeContainer && !v.window)) {
                    [v removeFromSuperview];
                    continue;
                }
                continue;
            }

            // Hook big play/shuffle button on album page
            if (s_isAlbumScreenVisible && [v isKindOfClass:[UIButton class]]) {
                UIButton *btn = (UIButton *)v;
                NSString *acc = [btn.accessibilityLabel lowercaseString] ?: @"";
                if (btn.bounds.size.width >= 35.0 && btn.bounds.size.height >= 35.0 &&
                    ([acc containsString:@"play"] || [acc containsString:@"воспроизведение"] || [acc containsString:@"shuffle"] || [acc containsString:@"перемешать"] || btn.tag == 0xAC777)) {
                    if (btn.tag != 0xAC777) {
                        btn.tag = 0xAC777;
                        [btn addTarget:[AntiCensorCellTapHandler sharedHandler] action:@selector(handleBigPlayButtonTap:) forControlEvents:UIControlEventTouchUpInside];
                    }
                }
            }

            // Un-grey and enable cells
            if ([v isKindOfClass:[UICollectionViewCell class]] || [v isKindOfClass:[UITableViewCell class]]) {
                unGreyAndEnableCell(v);
                UIView *contentView = nil;
                if ([v isKindOfClass:[UITableViewCell class]]) {
                    contentView = ((UITableViewCell *)v).contentView;
                } else if ([v isKindOfClass:[UICollectionViewCell class]]) {
                    contentView = ((UICollectionViewCell *)v).contentView;
                }
                NSMutableArray *cellSubviews = [NSMutableArray arrayWithArray:v.subviews];
                if (contentView && contentView != v) {
                    [cellSubviews addObjectsFromArray:contentView.subviews];
                }
                for (UIView *sub in cellSubviews) {
                    if ([sub isKindOfClass:[UILabel class]] || [sub isKindOfClass:[UITextView class]]) {
                        if (sub.hidden || sub.alpha < 0.05f) {
                            sub.hidden = NO;
                            sub.alpha = 1.0f;
                        }
                    }
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

#pragma mark - Network Hook (Uncensor Unplayable Album Tracks)



static NSURLSessionDataTask *custom_dataTaskWithRequest_completionHandler(id self, SEL _cmd, NSURLRequest *request, void (^completionHandler)(NSData *, NSURLResponse *, NSError *)) {
    if (!completionHandler) {
        if (orig_dataTaskWithRequest_completionHandler) {
            return orig_dataTaskWithRequest_completionHandler(self, _cmd, request, completionHandler);
        }
        return nil;
    }

    NSString *urlStr = request.URL.absoluteString;
    BOOL isPathfinder = [urlStr containsString:@"api-partner.spotify.com"] ||
                        [urlStr containsString:@"pathfinder"] ||
                        [urlStr containsString:@"/query"] ||
                        [urlStr containsString:@"/album"];

    void (^wrappedHandler)(NSData *, NSURLResponse *, NSError *) = ^(NSData *data, NSURLResponse *response, NSError *error) {
        if (isPathfinder && data && data.length > 0 && !error) {
            NSString *jsonStr = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            if (jsonStr && ([jsonStr containsString:@"\"playable\":false"] ||
                            [jsonStr containsString:@"\"is_playable\":false"] ||
                            [jsonStr containsString:@"COUNTRY_RESTRICTED"] ||
                            [jsonStr containsString:@"1f1OCxkJ43A1qy9qqFNfuX"])) {
                NSString *mod = [jsonStr stringByReplacingOccurrencesOfString:@"\"playable\":false" withString:@"\"playable\":true"];
                mod = [mod stringByReplacingOccurrencesOfString:@"\"is_playable\":false" withString:@"\"is_playable\":true"];
                mod = [mod stringByReplacingOccurrencesOfString:@"\"reason\":\"COUNTRY_RESTRICTED\"" withString:@"\"reason\":\"PLAYABLE\""];
                mod = [mod stringByReplacingOccurrencesOfString:@"\"reason\":\"NOT_IN_CATALOG\"" withString:@"\"reason\":\"PLAYABLE\""];
                NSData *modData = [mod dataUsingEncoding:NSUTF8StringEncoding];
                if (modData) {
                    completionHandler(modData, response, error);
                    return;
                }
            }
        }
        completionHandler(data, response, error);
    };

    if (orig_dataTaskWithRequest_completionHandler) {
        return orig_dataTaskWithRequest_completionHandler(self, _cmd, request, wrappedHandler);
    }
    return nil;
}

static void custom_presentViewController(UIViewController *callerVC, SEL _cmd, UIViewController *vcToPresent, BOOL animated, void (^completion)(void)) {
    if ([vcToPresent isKindOfClass:[UIAlertController class]]) {
        UIAlertController *alert = (UIAlertController *)vcToPresent;
        NSString *alertTitle = (alert.title ?: @"").lowercaseString;
        NSString *alertMsg = (alert.message ?: @"").lowercaseString;
        if ([alertTitle containsString:@"unavailable"] || [alertTitle containsString:@"недоступн"] ||
            [alertMsg containsString:@"unavailable"] || [alertMsg containsString:@"недоступн"] ||
            [alertMsg containsString:@"region"] || [alertMsg containsString:@"регион"] ||
            [alertTitle containsString:@"not available"] || [alertMsg containsString:@"not available"]) {
            NSLog(@"[AntiCensor] Suppressed unavailable track alert: %@ (%@)", alert.title, alert.message);
            if (completion) completion();
            return;
        }
    }

    g_lastForegroundOrScreenTransitionTimestamp = [NSDate timeIntervalSinceReferenceDate];
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

    NSString *clsName = NSStringFromClass([vcToPresent class]);
    if ([clsName containsString:@"Lyric"] || [clsName containsString:@"lyric"]) {
        NSString *userLyrics = getLyricsForTrack(currentActiveSpotifyTrackURI, currentActiveSpotifyTrackTitle, currentActiveSpotifyTrackArtist);
        if (userLyrics && userLyrics.length > 0) {
            NSMutableArray *queue = [NSMutableArray arrayWithObject:vcToPresent.view];
            while (queue.count > 0) {
                UIView *v = queue.firstObject;
                [queue removeObjectAtIndex:0];
                if ([v isKindOfClass:[UIScrollView class]] && v.tag != KARAOKE_CONTAINER_TAG) {
                    hideOriginalLyricsViews(v);
                }
                [queue addObjectsFromArray:v.subviews];
            }
            hideUnsyncedLyricsIndicator(vcToPresent.view);
            ensureHeaderAndChevronVisible(vcToPresent);
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            checkAndSyncLyricsOnScreen();
        });
    }
}

// UIMenu hook убран в v4.9 — кнопка AntiCensor добавляется нативной строкой через addAntiCensorRowToContextMenu

#pragma mark - Floating Badge (REMOVED in v6.0)

static void setupFloatingBadge(void) {
    // В v6.0 плавающая пилюля полностью и навсегда удалена
}

#pragma mark - Dynamic Injection Constructor


static void preResolveAllOverridesInBackground(void) {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
        NSDictionary *all = loadAllOverrides();
        if (!all || all.count == 0) return;
        for (NSString *k in all) {
            NSString *url = all[k];
            if ([url containsString:@"soundcloud.com"]) {
                resolveSoundCloudUrl(url, nil);
            }
        }
    });
}

static void cleanupPoisonedLyricsDatabase(void) {
    // Purge ghost lyrics once on upgrade to v4.1
    BOOL alreadyPurged = [[NSUserDefaults standardUserDefaults] boolForKey:@"AntiCensor_v4_1_PurgedGhostLyrics"];
    if (!alreadyPurged) {
        NSLog(@"[AntiCensor] Purging all ghost lyrics from local storage and user defaults...");
        persistLyrics(@{});
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:DEFAULTS_LYRICS_KEY];
        NSString *path = getLyricsFilePath();
        [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"AntiCensor_v4_1_PurgedGhostLyrics"];
        [[NSUserDefaults standardUserDefaults] synchronize];
        return;
    }
}

__attribute__((constructor)) static void initAntiCensor(void) {
    // Автопереход на следующий трек альбома при завершении текущего
    [[NSNotificationCenter defaultCenter] addObserverForName:AVPlayerItemDidPlayToEndTimeNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification * _Nonnull note) {
        if (ourAudioPlayer && ourAudioPlayer.currentItem == note.object) {
            NSLog(@"[AntiCensor] Replaced track ended, checking next album track...");
            if (currentPlayingUrl) {
                NSUInteger idx = NSNotFound;
                for (NSUInteger i = 0; i < 12; i++) {
                    if ([kAlbumUrls[i] isEqualToString:currentPlayingUrl]) {
                        idx = i;
                        break;
                    }
                }
                if (idx != NSNotFound && idx < 11) {
                    NSString *nextUrl = kAlbumUrls[idx + 1];
                    NSString *nextTitle = kAlbumTitles[idx + 1];
                    NSString *nextURI = kAlbumURIs[idx + 1];
                    NSLog(@"[AntiCensor] Auto-advancing to next album track: %@ (%@)", nextTitle, nextUrl);
                    currentActiveSpotifyTrackTitle = nextTitle;
                    currentActiveSpotifyTrackArtist = @"m1raOnTheBlock";
                    currentActiveSpotifyTrackURI = nextURI;
                    startReplacementAudio(nextTitle, nextUrl, 0.0);
                    cleanupRogueBanners();
                    if (g_activeNowPlayingVC) [g_activeNowPlayingVC updateWithTrackIndex:(int)(idx + 1)];
                }
            }
        }
    }];

    cleanupPoisonedLyricsDatabase();
    preResolveAllOverridesInBackground();
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

    // Защита от отката на ~5 сек при выходе из фона или сворачивании
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationWillEnterForegroundNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification * _Nonnull note) {
        g_lastForegroundOrScreenTransitionTimestamp = [NSDate timeIntervalSinceReferenceDate];
        if (ourAudioPlayer && isSpotifyCurrentlyPlaying) {
            if (ourAudioPlayer.timeControlStatus != AVPlayerTimeControlStatusPlaying) {
                [ourAudioPlayer play];
            }
            updateNowPlayingCenter();
        }
    }];

    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification * _Nonnull note) {
        g_lastForegroundOrScreenTransitionTimestamp = [NSDate timeIntervalSinceReferenceDate];
        if (ourAudioPlayer && isSpotifyCurrentlyPlaying) {
            if (ourAudioPlayer.timeControlStatus != AVPlayerTimeControlStatusPlaying) {
                [ourAudioPlayer play];
            }
            updateNowPlayingCenter();
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

    // 1.5. Хуки UITableViewCell и UICollectionViewCell для разблокировки и воспроизведения серых треков
    Class tblCellCls = [UITableViewCell class];
    if (tblCellCls) {
        Method mL = class_getInstanceMethod(tblCellCls, @selector(layoutSubviews));
        if (mL) {
            orig_UITableViewCell_layoutSubviews = (void (*)(id, SEL))method_getImplementation(mL);
            method_setImplementation(mL, (IMP)custom_UITableViewCell_layoutSubviews);
            NSLog(@"[AntiCensor] Successfully swizzled UITableViewCell layoutSubviews");
        }
    }
    Class colCellCls = [UICollectionViewCell class];
    if (colCellCls) {
        Method mL = class_getInstanceMethod(colCellCls, @selector(layoutSubviews));
        if (mL) {
            orig_UICollectionViewCell_layoutSubviews = (void (*)(id, SEL))method_getImplementation(mL);
            method_setImplementation(mL, (IMP)custom_UICollectionViewCell_layoutSubviews);
            NSLog(@"[AntiCensor] Successfully swizzled UICollectionViewCell layoutSubviews");
        }
    }

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

    // 3. UIMenu hook убран в v4.9 — кнопка AntiCensor добавляется нативной строкой

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
        class_addMethod(winClass, @selector(anticensor_drawerButtonTapped:), (IMP)anticensor_drawerButtonTapped, "v@:@");
    }

    // 4.5. MPRemoteCommandCenter: перемотка (scrubbing), play/pause и навигация для Lock Screen, Dynamic Island и Control Center
    MPRemoteCommandCenter *commandCenter = [MPRemoteCommandCenter sharedCommandCenter];
    [commandCenter.changePlaybackPositionCommand setEnabled:YES];
    // Отключаем кнопки 15-секундного пропуска в Dynamic Island, чтобы не было случайных прыжков
    [commandCenter.skipForwardCommand setEnabled:NO];
    [commandCenter.skipBackwardCommand setEnabled:NO];
    [commandCenter.seekForwardCommand setEnabled:NO];
    [commandCenter.seekBackwardCommand setEnabled:NO];
    [commandCenter.changePlaybackPositionCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent * _Nonnull event) {
        if (ourAudioPlayer && [event isKindOfClass:[MPChangePlaybackPositionCommandEvent class]]) {
            MPChangePlaybackPositionCommandEvent *posEvt = (MPChangePlaybackPositionCommandEvent *)event;
            safeSeekPlayerToTime(posEvt.positionTime);
            updateNowPlayingCenter();
            return MPRemoteCommandHandlerStatusSuccess;
        }
        return MPRemoteCommandHandlerStatusCommandFailed;
    }];

    [commandCenter.playCommand setEnabled:YES];
    [commandCenter.playCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent * _Nonnull event) {
        if (ourAudioPlayer) {
            [ourAudioPlayer play];
            isSpotifyCurrentlyPlaying = YES;
            updateNowPlayingCenter();
            return MPRemoteCommandHandlerStatusSuccess;
        }
        return MPRemoteCommandHandlerStatusCommandFailed;
    }];

    [commandCenter.pauseCommand setEnabled:YES];
    [commandCenter.pauseCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent * _Nonnull event) {
        if (ourAudioPlayer) {
            [ourAudioPlayer pause];
            isSpotifyCurrentlyPlaying = NO;
            updateNowPlayingCenter();
            return MPRemoteCommandHandlerStatusSuccess;
        }
        return MPRemoteCommandHandlerStatusCommandFailed;
    }];

    [commandCenter.togglePlayPauseCommand setEnabled:YES];
    [commandCenter.togglePlayPauseCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent * _Nonnull event) {
        if (ourAudioPlayer) {
            if (ourAudioPlayer.timeControlStatus == AVPlayerTimeControlStatusPlaying) {
                [ourAudioPlayer pause];
                isSpotifyCurrentlyPlaying = NO;
            } else {
                [ourAudioPlayer play];
                isSpotifyCurrentlyPlaying = YES;
            }
            updateNowPlayingCenter();
            return MPRemoteCommandHandlerStatusSuccess;
        }
        return MPRemoteCommandHandlerStatusCommandFailed;
    }];

    [commandCenter.nextTrackCommand setEnabled:YES];
    [commandCenter.nextTrackCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent * _Nonnull event) {
        if (!ourAudioPlayer || !isCurrentTrackFromAlbum(currentActiveSpotifyTrackURI, currentActiveSpotifyTrackTitle, currentActiveSpotifyTrackArtist, currentPlayingUrl)) {
            return MPRemoteCommandHandlerStatusCommandFailed;
        }
        if (currentPlayingUrl) {
            NSUInteger idx = NSNotFound;
            for (NSUInteger i = 0; i < 12; i++) {
                if ([kAlbumUrls[i] isEqualToString:currentPlayingUrl]) {
                    idx = i;
                    break;
                }
            }
            if (idx != NSNotFound && idx < 11) {
                NSString *nextUrl = kAlbumUrls[idx + 1];
                NSString *nextTitle = kAlbumTitles[idx + 1];
                NSString *nextURI = kAlbumURIs[idx + 1];
                currentActiveSpotifyTrackTitle = nextTitle;
                currentActiveSpotifyTrackArtist = @"m1raOnTheBlock";
                currentActiveSpotifyTrackURI = nextURI;
                startReplacementAudio(nextTitle, nextUrl, 0.0);
                cleanupRogueBanners();
                if (g_activeNowPlayingVC) [g_activeNowPlayingVC updateWithTrackIndex:(int)(idx + 1)];
            }
        }
        return MPRemoteCommandHandlerStatusSuccess;
    }];

    [commandCenter.previousTrackCommand setEnabled:YES];
    [commandCenter.previousTrackCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent * _Nonnull event) {
        if (!ourAudioPlayer || !isCurrentTrackFromAlbum(currentActiveSpotifyTrackURI, currentActiveSpotifyTrackTitle, currentActiveSpotifyTrackArtist, currentPlayingUrl)) {
            return MPRemoteCommandHandlerStatusCommandFailed;
        }
        if (ourAudioPlayer && CMTimeGetSeconds(ourAudioPlayer.currentTime) > 3.0) {
            safeSeekPlayerToTime(0.0);
            updateNowPlayingCenter();
            return MPRemoteCommandHandlerStatusSuccess;
        }
        if (currentPlayingUrl) {
            NSUInteger idx = NSNotFound;
            for (NSUInteger i = 0; i < 12; i++) {
                if ([kAlbumUrls[i] isEqualToString:currentPlayingUrl]) {
                    idx = i;
                    break;
                }
            }
            if (idx != NSNotFound && idx > 0) {
                NSString *prevUrl = kAlbumUrls[idx - 1];
                NSString *prevTitle = kAlbumTitles[idx - 1];
                NSString *prevURI = kAlbumURIs[idx - 1];
                currentActiveSpotifyTrackTitle = prevTitle;
                currentActiveSpotifyTrackArtist = @"m1raOnTheBlock";
                currentActiveSpotifyTrackURI = prevURI;
                startReplacementAudio(prevTitle, prevUrl, 0.0);
                cleanupRogueBanners();
                if (g_activeNowPlayingVC) [g_activeNowPlayingVC updateWithTrackIndex:(int)(idx - 1)];
            } else if (ourAudioPlayer) {
                safeSeekPlayerToTime(0.0);
                updateNowPlayingCenter();
            }
        }
        return MPRemoteCommandHandlerStatusSuccess;
    }];

        // 5. Первоначальный Cloud Sync с ПК при старте
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{

    // Hook NSURLSession for GraphQL Uncensoring
    Class sessionClass = objc_getClass("__NSURLSessionLocal") ?: [NSURLSession class];
    if (sessionClass) {
        Method mTask = class_getInstanceMethod(sessionClass, @selector(dataTaskWithRequest:completionHandler:));
        if (mTask) {
            orig_dataTaskWithRequest_completionHandler = (void *)method_getImplementation(mTask);
            method_setImplementation(mTask, (IMP)custom_dataTaskWithRequest_completionHandler);
            NSLog(@"[AntiCensor] Successfully hooked dataTaskWithRequest:completionHandler: on %@", NSStringFromClass(sessionClass));
        }
    }
    Class baseSessionClass = [NSURLSession class];
    if (baseSessionClass && baseSessionClass != sessionClass) {
        Method mBase = class_getInstanceMethod(baseSessionClass, @selector(dataTaskWithRequest:completionHandler:));
        if (mBase && !orig_dataTaskWithRequest_completionHandler) {
            orig_dataTaskWithRequest_completionHandler = (void *)method_getImplementation(mBase);
            method_setImplementation(mBase, (IMP)custom_dataTaskWithRequest_completionHandler);
        }
    }

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
