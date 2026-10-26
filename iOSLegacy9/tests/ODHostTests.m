// ODHostTests.m — macOS host tests for the UIKit-free receiver core.
// Covers framing, demux, hello JSON, Annex B splitting, SPS/PPS capture
// and a VideoToolbox decode smoke test (needs an H.264 sample path argv).
#import <Foundation/Foundation.h>
#import "ODWire.h"
#import "ODHello.h"
#import "ODAnnexB.h"
#import "ODDecoder.h"

static int failures = 0;
#define CHECK(cond, ...) do { \
    if (cond) { printf("PASS %s\n", #cond); } \
    else { printf("FAIL %s:%d %s ", __FILE__, __LINE__, #cond); \
           printf(__VA_ARGS__); printf("\n"); failures++; } \
} while (0)

@interface ODNullSink : NSObject <ODDisplaySink>
@property (nonatomic) NSUInteger enqueued;
@end
@implementation ODNullSink
- (void)enqueueSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    (void)sampleBuffer;
    @synchronized(self) { _enqueued++; }
}
@end

static void testFraming(void) {
    NSData *payload = [@"{\"type\":\"ping\",\"t\":1}" dataUsingEncoding:NSUTF8StringEncoding];
    NSData *frame = [ODWire frameWithPayload:payload];
    CHECK([frame length] == 4 + [payload length], "frame length");
    const uint8_t *bytes = (const uint8_t *)[frame bytes];
    CHECK([ODWire bigEndianLength:bytes] == [payload length], "BE length");
    CHECK(memcmp(bytes + 4, [payload bytes], [payload length]) == 0, "payload bytes");
    NSData *dictFrame = [ODWire frameWithJSONObject:@{@"type": @"kf"}];
    id back = [ODWire JSONObjectWithPayload:
        [dictFrame subdataWithRange:NSMakeRange(4, [dictFrame length] - 4)]];
    CHECK([back isKindOfClass:[NSDictionary class]] &&
          [[back objectForKey:@"type"] isEqualToString:@"kf"], "JSON round-trip");
}

static void testDemux(void) {
    NSData *json = [@"{\"type\":\"pong\",\"t\":1,\"mt\":2}" dataUsingEncoding:NSUTF8StringEncoding];
    CHECK([ODWire isJSONControlPayload:[json bytes] length:[json length]], "small JSON is control");
    // Video: start codes guarantee NUL bytes.
    uint8_t video[] = {0x00, 0x00, 0x00, 0x01, 0x67, 0x42, 0x00, 0x1e};
    CHECK(![ODWire isJSONControlPayload:video length:sizeof(video)], "Annex B is video");
    // Telemetry-prefixed video starts with '{' but carries NULs: still video.
    NSMutableData *prefixed = [NSMutableData data];
    [prefixed appendData:[@"{\"cap\":1,\"snd\":2}" dataUsingEncoding:NSUTF8StringEncoding]];
    [prefixed appendBytes:video length:sizeof(video)];
    CHECK(![ODWire isJSONControlPayload:[prefixed bytes] length:[prefixed length]],
          "telemetry prefix + NUL is video");
    // Oversize JSON-looking payload routes to video (sender MUST NOT emit it).
    NSMutableData *big = [NSMutableData dataWithLength:32768];
    memset((void *)[big mutableBytes], 'a', 32768);
    ((uint8_t *)[big mutableBytes])[0] = '{';
    CHECK(![ODWire isJSONControlPayload:[big bytes] length:[big length]], "32768B is video");
    // Non-JSON first byte.
    NSData *binary = [NSData dataWithBytes:(uint8_t[]){0x05, 0x01, 0x02} length:3];
    CHECK(![ODWire isJSONControlPayload:[binary bytes] length:3], "binary is video");
}

static void testHello(void) {
    NSDictionary *land = [ODHello helloWithUUID:@"TEST-UUID" landscape:YES];
    CHECK([[land objectForKey:@"type"] isEqualToString:@"hello"], "hello type");
    CHECK([[land objectForKey:@"pixelsWide"] isEqual:@1024] &&
          [[land objectForKey:@"pixelsHigh"] isEqual:@768], "landscape dims");
    CHECK([[land objectForKey:@"scale"] isEqual:@1], "scale 1");
    CHECK([[land objectForKey:@"device"] isEqualToString:@"iPad"], "device iPad");
    CHECK([[land objectForKey:@"id"] isEqualToString:@"TEST-UUID"], "uuid");
    CHECK([[land objectForKey:@"pv"] isEqual:@3], "pv 3");
    CHECK([[land objectForKey:@"displayMaxFrameRate"] isEqual:@30], "30fps");
    CHECK([[land objectForKey:@"maxEncodeWide"] isEqual:@1024] &&
          [[land objectForKey:@"maxEncodeHigh"] isEqual:@768], "encode ceiling");
    NSDictionary *panel = [land objectForKey:@"panel"];
    CHECK([[panel objectForKey:@"pixelsWide"] isEqual:@1024] &&
          [[panel objectForKey:@"pointsHigh"] isEqual:@768] &&
          [[panel objectForKey:@"scale"] isEqual:@1], "panel");
    NSArray *caps = [land objectForKey:@"videoCaps"];
    CHECK([caps count] == 1, "one videoCap");
    NSDictionary *h264 = [caps objectAtIndex:0];
    CHECK([[h264 objectForKey:@"codec"] isEqualToString:@"h264"] &&
          [[h264 objectForKey:@"maxWidth"] isEqual:@1024] &&
          [[h264 objectForKey:@"maxHeight"] isEqual:@768] &&
          [[h264 objectForKey:@"maxFrameRate"] isEqual:@30] &&
          [[h264 objectForKey:@"maxPixelsPerSecond"] isEqual:@(1024 * 768 * 30)],
          "h264 cap 23592960");
    // Must survive the wire as one JSON control frame.
    NSData *frame = [ODWire frameWithJSONObject:land];
    NSUInteger len = [ODWire bigEndianLength:(const uint8_t *)[frame bytes]];
    CHECK([ODWire isJSONControlPayload:(const uint8_t *)[frame bytes] + 4 length:len],
          "hello frames as control");
    NSDictionary *port = [ODHello helloWithUUID:@"TEST-UUID" landscape:NO];
    CHECK([[port objectForKey:@"pixelsWide"] isEqual:@768] &&
          [[port objectForKey:@"pixelsHigh"] isEqual:@1024], "portrait swaps");
    NSDictionary *portPanel = [port objectForKey:@"panel"];
    CHECK([[portPanel objectForKey:@"pixelsWide"] isEqual:@768] &&
          [[portPanel objectForKey:@"pixelsHigh"] isEqual:@1024], "panel swaps");
}

static NSData *fakeNALU(NSUInteger type, NSUInteger length, uint8_t fill) {
    NSMutableData *d = [NSMutableData dataWithLength:length];
    uint8_t *b = (uint8_t *)[d mutableBytes];
    memset(b, fill, length);
    b[0] = (uint8_t)(0x60 | (type & 0x1F)); // forbidden_zero + nal_ref_idc + type
    return d;
}

static void testAnnexB(void) {
    static const uint8_t sc[4] = {0, 0, 0, 1};
    NSMutableData *au = [NSMutableData data];
    [au appendData:[@"{\"cap\":10,\"snd\":20}" dataUsingEncoding:NSUTF8StringEncoding]];
    [au appendBytes:sc length:4]; [au appendData:fakeNALU(7, 12, 0x11)]; // SPS
    [au appendBytes:sc length:4]; [au appendData:fakeNALU(8, 6, 0x22)];  // PPS
    [au appendBytes:sc length:4]; [au appendData:fakeNALU(5, 40, 0x33)]; // IDR
    [au appendBytes:sc length:4]; [au appendData:fakeNALU(1, 30, 0x44)]; // P-slice
    NSData *prefix = nil;
    NSArray<NSData *> *nalus = [ODAnnexB splitAccessUnit:au telemetryPrefix:&prefix];
    NSData *expectedPrefix = [@"{\"cap\":10,\"snd\":20}" dataUsingEncoding:NSUTF8StringEncoding];
    CHECK([nalus count] == 4, "four NALUs, got %lu", (unsigned long)[nalus count]);
    CHECK([prefix isEqualToData:expectedPrefix], "telemetry prefix captured");
    CHECK([ODAnnexB naluType:[nalus objectAtIndex:0]] == 7, "SPS first");
    CHECK([ODAnnexB naluType:[nalus objectAtIndex:1]] == 8, "PPS second");
    CHECK([ODAnnexB naluType:[nalus objectAtIndex:2]] == 5, "IDR third");
    CHECK([ODAnnexB naluType:[nalus objectAtIndex:3]] == 1, "slice fourth");
    NSArray *sps = @[[nalus objectAtIndex:0]];
    NSArray *pps = @[[nalus objectAtIndex:1]];
    CHECK(![ODAnnexB parameterSetsChangedSPS:sps PPS:pps oldSPS:sps oldPPS:pps],
          "same params no change");
    CHECK([ODAnnexB parameterSetsChangedSPS:sps PPS:pps oldSPS:nil oldPPS:nil],
          "first params are a change");
    NSArray *sps2 = @[fakeNALU(7, 12, 0x55)];
    CHECK([ODAnnexB parameterSetsChangedSPS:sps2 PPS:pps oldSPS:sps oldPPS:pps],
          "new SPS is a change");
    // No start codes at all: no NALUs, no crash.
    NSData *junk = [@"hello" dataUsingEncoding:NSUTF8StringEncoding];
    CHECK([[ODAnnexB splitAccessUnit:junk telemetryPrefix:NULL] count] == 0,
          "no start codes, no NALUs");
}

// Test-only normalizer: ffmpeg emits 3-byte start codes for SEI/slices,
// but the wire sender always uses 4-byte codes (PROTOCOL.md 5.1), which is
// all ODAnnexB splits on. Rewrite every code as 4 bytes before feeding.
static NSData *normalizeStartCodes(NSData *file) {
    const uint8_t *b = (const uint8_t *)[file bytes];
    NSUInteger n = [file length];
    NSMutableArray<NSArray *> *codes = [NSMutableArray array]; // @(offset), @(length)
    NSUInteger i = 0;
    while (i + 3 <= n) {
        if (i + 4 <= n && b[i] == 0 && b[i + 1] == 0 && b[i + 2] == 0 && b[i + 3] == 1) {
            [codes addObject:@[@(i), @(4)]];
            i += 4;
        } else if (b[i] == 0 && b[i + 1] == 0 && b[i + 2] == 1) {
            [codes addObject:@[@(i), @(3)]];
            i += 3;
        } else {
            i++;
        }
    }
    static const uint8_t sc[4] = {0, 0, 0, 1};
    NSMutableData *out = [NSMutableData data];
    for (NSUInteger k = 0; k < [codes count]; k++) {
        NSUInteger start = [[codes[k] objectAtIndex:0] unsignedIntegerValue]
                         + [[codes[k] objectAtIndex:1] unsignedIntegerValue];
        NSUInteger end = (k + 1 < [codes count])
            ? [[codes[k + 1] objectAtIndex:0] unsignedIntegerValue] : n;
        if (end > start) {
            [out appendBytes:sc length:4];
            [out appendBytes:b + start length:end - start];
        }
    }
    return out;
}

// Test-only Exp-Golomb reader over RBSP (emulation bytes pre-stripped).
typedef struct { const uint8_t *p; const uint8_t *end; int cur; int bits; } ODBitReader;
static int odReadBit(ODBitReader *r) {
    if (r->bits == 0) {
        if (r->p >= r->end) return 0;
        r->cur = *r->p++;
        r->bits = 8;
    }
    r->bits--;
    return (r->cur >> r->bits) & 1;
}
static NSUInteger odReadUE(ODBitReader *r) {
    int leadingZeros = 0;
    while (odReadBit(r) == 0 && leadingZeros < 32) leadingZeros++;
    NSUInteger info = 0;
    for (int i = 0; i < leadingZeros; i++) info = (info << 1) | (NSUInteger)odReadBit(r);
    return ((NSUInteger)1 << leadingZeros) - 1 + info;
}
// first_mb_in_slice: first syntax element of every H.264 slice header.
// Zero means a new picture starts (multi-slice frames share one AU).
static BOOL odStartsNewPicture(NSData *nalu) {
    if ([nalu length] < 2) return NO;
    const uint8_t *b = (const uint8_t *)[nalu bytes];
    NSUInteger n = [nalu length];
    NSMutableData *rbsp = [NSMutableData dataWithCapacity:n];
    for (NSUInteger i = 0; i < n; i++) {
        if (i + 2 < n && b[i] == 0 && b[i + 1] == 0 && b[i + 2] == 3) {
            [rbsp appendBytes:b + i length:2];
            i += 2;
        } else {
            [rbsp appendBytes:b + i length:1];
        }
    }
    const uint8_t *rb = (const uint8_t *)[rbsp bytes];
    ODBitReader r = { rb + 1, rb + [rbsp length], 0, 0 };
    return odReadUE(&r) == 0;
}

// Split a raw .h264 Annex B file into access units (one picture each).
// A VCL NALU joins the current AU only when it holds no picture yet;
// parameter sets and SEI join the picture they precede.
static NSArray<NSData *> *accessUnitsFromFile(NSData *file) {
    NSData *prefix = nil;
    NSArray<NSData *> *nalus = [ODAnnexB splitAccessUnit:file telemetryPrefix:&prefix];
    NSMutableArray<NSData *> *aus = [NSMutableArray array];
    NSMutableData *current = nil;
    BOOL currentHasVCL = NO;
    static const uint8_t sc[4] = {0, 0, 0, 1};
    for (NSData *nalu in nalus) {
        NSUInteger type = [ODAnnexB naluType:nalu];
        BOOL isVCL = (type >= 1 && type <= 5);
        if (!current) {
            current = [NSMutableData data];
            currentHasVCL = NO;
        } else if (currentHasVCL && (!isVCL || odStartsNewPicture(nalu))) {
            // A new picture starts, or non-VCL data for the next one.
            if ([current length] > 0) [aus addObject:current];
            current = [NSMutableData data];
            currentHasVCL = NO;
        }
        [current appendBytes:sc length:4];
        [current appendData:nalu];
        if (isVCL) currentHasVCL = YES;
    }
    if (current && [current length] > 0) [aus addObject:current];
    return aus;
}

static void testDecodeSmoke(NSString *samplePath) {
    NSData *file = [NSData dataWithContentsOfFile:samplePath];
    CHECK(file && [file length] > 0, "sample loads");
    if (!file) return;
    NSArray<NSData *> *aus = accessUnitsFromFile(normalizeStartCodes(file));
    CHECK([aus count] > 0, "sample splits into AUs");
    ODNullSink *sink = [[ODNullSink alloc] init];
    ODDecoder *decoder = [[ODDecoder alloc] initWithSink:sink];
    __block NSUInteger kfRequests = 0;
    __block NSInteger lastW = 0, lastH = 0;
    decoder.keyframeRequest = ^{ kfRequests++; };
    decoder.frameDecoded = ^(NSInteger w, NSInteger h) { lastW = w; lastH = h; };
    for (NSData *au in aus) [decoder decodeAccessUnit:au];
    // Async decode: wait for the callbacks to drain.
    for (int i = 0; i < 200 && decoder.decodedFrames == 0; i++) {
        [NSThread sleepForTimeInterval:0.05];
    }
    CHECK(decoder.decodedFrames > 0, "decoded %lu frames",
          (unsigned long)decoder.decodedFrames);
    CHECK(sink.enqueued > 0, "sink enqueued %lu buffers",
          (unsigned long)sink.enqueued);
    CHECK(lastW == 320 && lastH == 180, "raster 320x180, got %ldx%ld",
          (long)lastW, (long)lastH);
    printf("INFO kfRequests=%lu dropped=%lu dims=%ldx%ld\n",
           (unsigned long)kfRequests, (unsigned long)decoder.droppedFrames,
           (long)decoder.videoWidth, (long)decoder.videoHeight);
    [decoder reset];
}

#import "ODSession.h"
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <unistd.h>

@interface ODLoopbackDelegate : NSObject <ODSessionDelegate>
@property (nonatomic) NSUInteger videoFrames;
@property (nonatomic) NSUInteger connects;
@property (nonatomic) NSUInteger disconnects;
@property (nonatomic) NSUInteger resets;
@property (nonatomic, copy) NSString *updateMessage;
@end
@implementation ODLoopbackDelegate
- (void)sessionDidConnect:(ODSession *)s transport:(NSString *)t {
    (void)s; (void)t;
    @synchronized(self) { _connects++; }
}
- (void)sessionDidDisconnect:(ODSession *)s {
    (void)s;
    @synchronized(self) { _disconnects++; }
}
- (void)session:(ODSession *)s didReceiveVideoFrame:(NSData *)f {
    (void)s; (void)f;
    @synchronized(self) { _videoFrames++; }
}
- (void)sessionDecoderShouldReset:(ODSession *)s {
    (void)s;
    @synchronized(self) { _resets++; }
}
- (void)session:(ODSession *)s didReceiveUpdateRequired:(NSString *)m store:(NSString *)st {
    (void)s; (void)st;
    @synchronized(self) { self.updateMessage = m; }
}
- (void)session:(ODSession *)s didUpdateSenderInfo:(NSString *)info {
    (void)s; (void)info;
}
@end

static int odDial(void) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(9000);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        close(fd);
        return -1;
    }
    struct timeval tv = {1, 0};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    return fd;
}

static ssize_t odReadFull(int fd, uint8_t *buffer, size_t length, BOOL *timedOut) {
    size_t got = 0;
    while (got < length) {
        ssize_t n = recv(fd, buffer + got, length - got, 0);
        if (n > 0) { got += (size_t)n; continue; }
        if (n == 0) return 0; // EOF
        if (errno == EAGAIN || errno == EWOULDBLOCK) {
            if (timedOut) *timedOut = YES;
            return -1;
        }
        return -1;
    }
    return (ssize_t)got;
}

// Next non-ping control message; video frames fail the read.
static NSDictionary *odReadControl(int fd, NSTimeInterval deadline, NSString **eof) {
    for (;;) {
        if ([NSDate timeIntervalSinceReferenceDate] > deadline) return nil;
        uint8_t header[4];
        BOOL timedOut = NO;
        ssize_t n = odReadFull(fd, header, 4, &timedOut);
        if (n == 0) { if (eof) *eof = @"eof"; return nil; }
        if (n != 4) continue;
        uint32_t length = [ODWire bigEndianLength:header];
        if (length == 0 || length > 16 * 1024 * 1024) return nil;
        NSMutableData *payload = [NSMutableData dataWithLength:length];
        n = odReadFull(fd, (uint8_t *)[payload mutableBytes], length, NULL);
        if (n != (ssize_t)length) {
            if (n == 0 && eof) *eof = @"eof";
            return nil;
        }
        if (![ODWire isJSONControlPayload:[payload bytes] length:length]) return nil;
        id object = [ODWire JSONObjectWithPayload:payload];
        if (![object isKindOfClass:[NSDictionary class]]) continue;
        if ([[object objectForKey:@"type"] isEqualToString:@"ping"]) continue;
        return object;
    }
}

static void odSendControl(int fd, NSDictionary *object) {
    NSData *frame = [ODWire frameWithJSONObject:object];
    const uint8_t *bytes = (const uint8_t *)[frame bytes];
    size_t left = [frame length];
    while (left > 0) {
        ssize_t n = send(fd, bytes + ([frame length] - left), left, 0);
        if (n <= 0) break;
        left -= (size_t)n;
    }
}

static void testSession(NSString *samplePath) {
    // Skip when something already owns :9000 on this Mac.
    int probe = odDial();
    if (probe >= 0) {
        close(probe);
        printf("SKIP session loopback: TCP :9000 already in use\n");
        return;
    }
    ODLoopbackDelegate *delegate = [[ODLoopbackDelegate alloc] init];
    ODSession *session = [[ODSession alloc] initWithDeviceUUID:@"TEST-ID"
                                                      deviceName:@"TestPad"
                                                        delegate:delegate];
    [session start];
    int fd = -1;
    for (int i = 0; i < 50 && fd < 0; i++) {
        fd = odDial();
        if (fd < 0) [NSThread sleepForTimeInterval:0.1];
    }
    CHECK(fd >= 0, "listener accepts on :9000");
    if (fd < 0) return;
    NSTimeInterval deadline = [NSDate timeIntervalSinceReferenceDate] + 5;
    NSDictionary *hello = odReadControl(fd, deadline, NULL);
    CHECK([[hello objectForKey:@"type"] isEqualToString:@"hello"], "hello first");
    CHECK([[hello objectForKey:@"id"] isEqualToString:@"TEST-ID"] &&
          [[hello objectForKey:@"pv"] isEqual:@3] &&
          [[hello objectForKey:@"pixelsWide"] isEqual:@1024], "hello identity");
    NSDictionary *kf = odReadControl(fd, deadline, NULL);
    CHECK([[kf objectForKey:@"type"] isEqualToString:@"kf"], "kf on connect");
    // Sender ping needs no answer but must not disturb the session.
    odSendControl(fd, @{@"type": @"ping"});
    odSendControl(fd, @{@"type": @"welcome", @"pv": @3, @"min": @1});
    odSendControl(fd, @{@"type": @"streamConfig", @"codec": @"h264",
                         @"width": @320, @"height": @180,
                         @"framesPerSecond": @30});
    // One real access unit must reach the video delegate.
    if (samplePath) {
        NSData *file = [NSData dataWithContentsOfFile:samplePath];
        NSArray<NSData *> *aus = accessUnitsFromFile(normalizeStartCodes(file));
        if ([aus count] > 0) {
            NSData *au = [aus objectAtIndex:0];
            const uint8_t *bytes = (const uint8_t *)[au bytes];
            size_t left = [au length];
            uint8_t header[4] = { (uint8_t)(left >> 24), (uint8_t)(left >> 16),
                                  (uint8_t)(left >> 8), (uint8_t)left };
            send(fd, header, 4, 0);
            while (left > 0) {
                ssize_t n = send(fd, bytes + ([au length] - left), left, 0);
                if (n <= 0) break;
                left -= (size_t)n;
            }
        }
    }
    BOOL gotVideo = NO;
    for (int i = 0; i < 50; i++) {
        @synchronized(delegate) { gotVideo = delegate.videoFrames > 0; }
        if (gotVideo) break;
        [NSThread sleepForTimeInterval:0.1];
    }
    CHECK(gotVideo, "video frame reaches delegate");
    // The session pings every ~2s on its own.
    NSDictionary *ping = nil;
    deadline = [NSDate timeIntervalSinceReferenceDate] + 5;
    while (!ping && [NSDate timeIntervalSinceReferenceDate] < deadline) {
        uint8_t header[4];
        ssize_t hn = odReadFull(fd, header, 4, NULL);
        if (hn != 4) continue; // timeout: keep waiting to the deadline
        uint32_t length = [ODWire bigEndianLength:header];
        if (length == 0 || length > 1024 * 1024) break;
        NSMutableData *payload = [NSMutableData dataWithLength:length];
        if (odReadFull(fd, (uint8_t *)[payload mutableBytes], length, NULL)
            != (ssize_t)length) break;
        id object = [ODWire JSONObjectWithPayload:payload];
        if ([object isKindOfClass:[NSDictionary class]] &&
            [[[object objectForKey:@"type"] description] isEqualToString:@"ping"]) {
            ping = object;
        }
    }
    CHECK(ping != nil, "session ping arrives");
    // Input: touch + scroll frames on the wire.
    [session sendTouchPhase:@"began" x:0.25 y:0.5];
    NSDictionary *touch = odReadControl(fd,
        [NSDate timeIntervalSinceReferenceDate] + 5, NULL);
    CHECK([[touch objectForKey:@"type"] isEqualToString:@"touch"] &&
          [[touch objectForKey:@"phase"] isEqualToString:@"began"] &&
          fabs([[touch objectForKey:@"x"] doubleValue] - 0.25) < 0.0001 &&
          fabs([[touch objectForKey:@"y"] doubleValue] - 0.5) < 0.0001,
          "touch frame");
    [session sendScrollDX:10 dy:-20];
    NSDictionary *scroll = odReadControl(fd,
        [NSDate timeIntervalSinceReferenceDate] + 5, NULL);
    CHECK([[scroll objectForKey:@"type"] isEqualToString:@"scroll"] &&
          [[scroll objectForKey:@"dx"] isEqual:@10] &&
          [[scroll objectForKey:@"dy"] isEqual:@-20], "scroll frame");
    // updateRequired surfaces to the delegate.
    odSendControl(fd, @{@"type": @"updateRequired", @"target": @"ios",
                         @"store": @"https://example.com",
                         @"message": @"time to update"});
    BOOL gotUpdate = NO;
    for (int i = 0; i < 50; i++) {
        @synchronized(delegate) {
            gotUpdate = [delegate.updateMessage isEqualToString:@"time to update"];
        }
        if (gotUpdate) break;
        [NSThread sleepForTimeInterval:0.1];
    }
    CHECK(gotUpdate, "updateRequired surfaces");
    // Drop the client: the listener must survive for the next sender.
    close(fd);
    [NSThread sleepForTimeInterval:0.5];
    int fd2 = odDial();
    CHECK(fd2 >= 0, "listener survives disconnect");
    if (fd2 >= 0) {
        NSDictionary *hello2 = odReadControl(fd2,
            [NSDate timeIntervalSinceReferenceDate] + 5, NULL);
        CHECK([[hello2 objectForKey:@"type"] isEqualToString:@"hello"],
              "second client greeted");
        // Drain the connect-time kf; what follows must be silence.
        (void)odReadControl(fd2, [NSDate timeIntervalSinceReferenceDate] + 5, NULL);
        // Silence: the session must close after ~5s with no bytes.
        NSString *eof = nil;
        odReadControl(fd2, [NSDate timeIntervalSinceReferenceDate] + 9, &eof);
        CHECK([eof isEqualToString:@"eof"], "idle session closed");
        close(fd2);
    }
}

int main(int argc, const char *argv[]) {
    setbuf(stdout, NULL);
    @autoreleasepool {
        printf("--- framing ---\n");
        testFraming();
        printf("--- demux ---\n");
        testDemux();
        printf("--- hello ---\n");
        testHello();
        printf("--- annexb ---\n");
        testAnnexB();
        if (argc > 1) {
            printf("--- decode smoke (%s) ---\n", argv[1]);
            testDecodeSmoke([NSString stringWithUTF8String:argv[1]]);
        } else {
            printf("SKIP decode smoke: no H.264 sample produced\n");
        }
        printf("--- session loopback ---\n");
        testSession(argc > 1 ? [NSString stringWithUTF8String:argv[1]] : nil);
        if (failures == 0) { printf("ALL HOST TESTS PASSED\n"); return 0; }
        printf("%d FAILURES\n", failures);
        return 1;
    }
}
