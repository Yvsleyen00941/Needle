// NeedleBridge: reads what's playing on the Mac and passes it to Needle, one JSON object per line.
//
// Since macOS 15.4 the system's Now Playing service only answers Apple's own processes, so Needle
// loads this library into /usr/bin/perl (an Apple binary) and talks to it over a pipe:
//
//   stdout  {"type":"info", "title":…, "artist":…, "artwork":"<base64>", …}  whenever anything changes
//           {"type":"none"}                                                   when nothing is playing
//           {"type":"error", "reason":…}                                      when the service can't be reached
//   stdin   play | pause | toggle | next | previous | seek <seconds> | refresh, one per line
//
// The artwork travels once per picture; after that only its identifier does. When Needle quits,
// stdin closes and the bridge exits with it. The approach comes from ungive/mediaremote-adapter.

#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <unistd.h>

typedef void (*MRGetInfoFn)(dispatch_queue_t, void (^)(NSDictionary *));
typedef void (*MRGetIsPlayingFn)(dispatch_queue_t, void (^)(BOOL));
typedef void (*MRGetPIDFn)(dispatch_queue_t, void (^)(int));
typedef void (*MRGetClientFn)(dispatch_queue_t, void (^)(id));
typedef NSString *(*MRClientStringFn)(id);
typedef void (*MRRegisterFn)(dispatch_queue_t);
typedef Boolean (*MRSendCommandFn)(int, NSDictionary *);
typedef void (*MRSetElapsedFn)(double);

static MRGetInfoFn getInfo;
static MRGetIsPlayingFn getIsPlaying;
static MRGetPIDFn getPID;
static MRGetClientFn getClient;
static MRClientStringFn clientBundle;
static MRClientStringFn clientParentBundle;
static MRSendCommandFn sendCommand;
static MRSetElapsedFn setElapsed;

static dispatch_queue_t queue;
static NSString *lastLine;
static NSString *sentArtwork;
static BOOL refreshPending;
// Kept for the life of the process.
static dispatch_source_t stdinSource;
static dispatch_source_t refreshTimer;

static void emit(NSDictionary *object) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0 error:nil];
    if (!data) return;
    fwrite(data.bytes, 1, data.length, stdout);
    fputc('\n', stdout);
    fflush(stdout);
}

static id string(NSDictionary *info, NSString *key) {
    id value = info[key];
    return [value isKindOfClass:[NSString class]] && [value length] > 0 ? value : nil;
}

static id number(NSDictionary *info, NSString *key) {
    id value = info[key];
    return [value isKindOfClass:[NSNumber class]] ? value : nil;
}

static void publish(NSDictionary *info, BOOL playing, int pid, NSString *bundle, NSString *parent) {
    if (info.count == 0 || !string(info, @"kMRMediaRemoteNowPlayingInfoTitle")) {
        NSString *line = @"none";
        if (![line isEqual:lastLine]) {
            lastLine = line;
            sentArtwork = nil;
            emit(@{ @"type": @"none" });
        }
        return;
    }
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    out[@"type"] = @"info";
    out[@"playing"] = @(playing);
    if (pid > 0) out[@"pid"] = @(pid);
    if (bundle.length) out[@"bundle"] = bundle;
    if (parent.length) out[@"parentBundle"] = parent;
    NSDictionary<NSString *, NSString *> *strings = @{
        @"title": @"kMRMediaRemoteNowPlayingInfoTitle",
        @"artist": @"kMRMediaRemoteNowPlayingInfoArtist",
        @"album": @"kMRMediaRemoteNowPlayingInfoAlbum",
        @"artworkID": @"kMRMediaRemoteNowPlayingInfoArtworkIdentifier",
        @"artworkMIME": @"kMRMediaRemoteNowPlayingInfoArtworkMIMEType",
        @"mediaType": @"kMRMediaRemoteNowPlayingInfoMediaType",
        @"contentID": @"kMRMediaRemoteNowPlayingInfoContentItemIdentifier",
    };
    for (NSString *key in strings) {
        id value = string(info, strings[key]);
        if (value) out[key] = value;
    }
    NSDictionary<NSString *, NSString *> *numbers = @{
        @"duration": @"kMRMediaRemoteNowPlayingInfoDuration",
        @"elapsed": @"kMRMediaRemoteNowPlayingInfoElapsedTime",
        @"rate": @"kMRMediaRemoteNowPlayingInfoPlaybackRate",
        @"uniqueID": @"kMRMediaRemoteNowPlayingInfoUniqueIdentifier",
        @"live": @"kMRMediaRemoteNowPlayingInfoIsAlwaysLive",
    };
    for (NSString *key in numbers) {
        id value = number(info, numbers[key]);
        if (value) out[key] = value;
    }
    id timestamp = info[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
    if ([timestamp isKindOfClass:[NSDate class]]) out[@"timestamp"] = @([timestamp timeIntervalSince1970]);

    // A picture without an identifier is known by its size, so the same one isn't sent twice.
    NSData *artwork = [info[@"kMRMediaRemoteNowPlayingInfoArtworkData"] isKindOfClass:[NSData class]] ? info[@"kMRMediaRemoteNowPlayingInfoArtworkData"] : nil;
    if (artwork.length > 0 && !out[@"artworkID"]) out[@"artworkID"] = [NSString stringWithFormat:@"data-%lu-%lu", (unsigned long)artwork.length, (unsigned long)[artwork hash]];
    out[@"hasArtwork"] = @(artwork.length > 0);

    NSData *data = [NSJSONSerialization dataWithJSONObject:out options:NSJSONWritingSortedKeys error:nil];
    NSString *line = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
    BOOL newArtwork = artwork.length > 0 && ![out[@"artworkID"] isEqual:sentArtwork];
    if ([line isEqual:lastLine] && !newArtwork) return;
    lastLine = line;
    if (newArtwork) {
        out[@"artwork"] = [artwork base64EncodedStringWithOptions:0];
        sentArtwork = out[@"artworkID"];
    }
    emit(out);
}

static void refresh(void) {
    getInfo(queue, ^(NSDictionary *info) {
        getIsPlaying(queue, ^(BOOL playing) {
            getPID(queue, ^(int pid) {
                if (!getClient) {
                    publish(info, playing, pid, nil, nil);
                    return;
                }
                getClient(queue, ^(id client) {
                    NSString *bundle = client && clientBundle ? clientBundle(client) : nil;
                    NSString *parent = client && clientParentBundle ? clientParentBundle(client) : nil;
                    publish(info, playing, pid, bundle, parent);
                });
            });
        });
    });
}

/// Changes arrive in bursts (a new track sends four or five); answer the burst once.
static void scheduleRefresh(void) {
    dispatch_async(queue, ^{
        if (refreshPending) return;
        refreshPending = YES;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_MSEC), queue, ^{
            refreshPending = NO;
            refresh();
        });
    });
}

static void perform(NSString *command) {
    NSArray<NSString *> *words = [command componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    NSString *verb = words.firstObject.lowercaseString;
    NSDictionary<NSString *, NSNumber *> *commands = @{ @"play": @0, @"pause": @1, @"toggle": @2, @"next": @4, @"previous": @5 };
    if (commands[verb] && sendCommand) {
        sendCommand(commands[verb].intValue, nil);
    } else if ([verb isEqual:@"seek"] && words.count > 1 && setElapsed) {
        setElapsed(MAX(0, words[1].doubleValue));
    } else if ([verb isEqual:@"refresh"]) {
        lastLine = nil;
        sentArtwork = nil;
    }
    scheduleRefresh();
}

static void readCommands(void) {
    static NSMutableData *buffer;
    buffer = [NSMutableData data];
    dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, STDIN_FILENO, 0, queue);
    dispatch_source_set_event_handler(source, ^{
        char chunk[512];
        ssize_t count = read(STDIN_FILENO, chunk, sizeof chunk);
        // Needle has gone: so does the bridge.
        if (count <= 0) exit(0);
        [buffer appendBytes:chunk length:(NSUInteger)count];
        while (true) {
            NSRange newline = [buffer rangeOfData:[NSData dataWithBytes:"\n" length:1] options:0 range:NSMakeRange(0, buffer.length)];
            if (newline.location == NSNotFound) break;
            NSData *lineData = [buffer subdataWithRange:NSMakeRange(0, newline.location)];
            [buffer replaceBytesInRange:NSMakeRange(0, newline.location + 1) withBytes:NULL length:0];
            NSString *line = [[NSString alloc] initWithData:lineData encoding:NSUTF8StringEncoding];
            NSString *trimmed = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            if (trimmed.length) perform(trimmed);
        }
    });
    dispatch_resume(source);
    stdinSource = source;
}

void needle_bridge_run(void) {
    @autoreleasepool {
        setvbuf(stdout, NULL, _IOFBF, 1 << 16);
        void *handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
        if (!handle) {
            emit(@{ @"type": @"error", @"reason": @"MediaRemote is missing" });
            exit(2);
        }
        getInfo = (MRGetInfoFn)dlsym(handle, "MRMediaRemoteGetNowPlayingInfo");
        getIsPlaying = (MRGetIsPlayingFn)dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
        getPID = (MRGetPIDFn)dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationPID");
        getClient = (MRGetClientFn)dlsym(handle, "MRMediaRemoteGetNowPlayingClient");
        clientBundle = (MRClientStringFn)dlsym(handle, "MRNowPlayingClientGetBundleIdentifier");
        clientParentBundle = (MRClientStringFn)dlsym(handle, "MRNowPlayingClientGetParentAppBundleIdentifier");
        sendCommand = (MRSendCommandFn)dlsym(handle, "MRMediaRemoteSendCommand");
        setElapsed = (MRSetElapsedFn)dlsym(handle, "MRMediaRemoteSetElapsedTime");
        MRRegisterFn registerForNotifications = (MRRegisterFn)dlsym(handle, "MRMediaRemoteRegisterForNowPlayingNotifications");
        if (!getInfo || !getIsPlaying || !getPID || !registerForNotifications) {
            emit(@{ @"type": @"error", @"reason": @"MediaRemote has changed" });
            exit(3);
        }
        queue = dispatch_queue_create("me.yorben.needle.bridge", DISPATCH_QUEUE_SERIAL);
        registerForNotifications(queue);
        NSArray *names = @[
            @"kMRMediaRemoteNowPlayingInfoDidChangeNotification",
            @"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
            @"kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
            @"kMRMediaRemoteNowPlayingApplicationClientStateDidChange",
        ];
        for (NSString *name in names) {
            [NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:nil usingBlock:^(NSNotification *note) { scheduleRefresh(); }];
        }
        readCommands();
        // A safety net for players that change without saying so.
        dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
        dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC), 4 * NSEC_PER_SEC, NSEC_PER_SEC);
        dispatch_source_set_event_handler(timer, ^{ refresh(); });
        dispatch_resume(timer);
        refreshTimer = timer;
        refresh();
    }
    dispatch_main();
}
