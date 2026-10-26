// ODSession.m — TCP listener, Bonjour, frame loop, liveness.
#import "ODSession.h"
#import "ODHello.h"
#import "ODWire.h"
#import <sys/socket.h>
#import <netinet/in.h>
#import <netinet/tcp.h>
#import <arpa/inet.h>
#import <unistd.h>
#import <fcntl.h>
#import <errno.h>

static const uint16_t ODPort = 9000;
static const NSTimeInterval ODPingInterval = 2.0;
static const NSTimeInterval ODTimeout = 5.0;
static const uint32_t ODMaxFrame = 16 * 1024 * 1024;

@implementation ODSession {
    NSString *_uuid;
    NSString *_deviceName;
    id<ODSessionDelegate> _delegate; // receiver runs while the app lives
    BOOL _landscape;
    int _listenFD;
    int _connFD;
    NSString *_transport;
    NSInteger _senderPV;
    BOOL _dropVideo; // sender picked a codec we cannot decode
    dispatch_queue_t _queue;    // serial: connection state + all sends
    dispatch_source_t _pingTimer;
    NSTimeInterval _lastRx;
    NSNetService *_bonjour;
}

- (instancetype)initWithDeviceUUID:(NSString *)uuid
                        deviceName:(NSString *)deviceName
                          delegate:(id<ODSessionDelegate>)delegate {
    if ((self = [super init])) {
        _uuid = [uuid copy];
        _deviceName = [deviceName copy] ?: @"iPad";
        _delegate = delegate;
        _landscape = YES;
        _listenFD = -1;
        _connFD = -1;
        _senderPV = 1;
        _queue = dispatch_queue_create("app.opendisplay.legacy9.session",
                                       DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (void)dealloc {
    [self stopTimers];
    if (_bonjour) { [_bonjour stop]; }
    if (_listenFD >= 0) close(_listenFD);
    if (_connFD >= 0) close(_connFD);
}

- (BOOL)isLandscape { return _landscape; }

- (BOOL)isConnected {
    __block BOOL connected = NO;
    dispatch_sync(_queue, ^{ connected = (self->_connFD >= 0); });
    return connected;
}

- (NSString *)transport {
    __block NSString *t = nil;
    dispatch_sync(_queue, ^{ t = self->_transport; });
    return t;
}

- (void)start {
    dispatch_async(_queue, ^{ [self listen]; });
    // NSNetService publishes on this thread's run loop: main thread.
    _bonjour = [[NSNetService alloc] initWithDomain:@""
                                               type:@"_opensidecar._tcp."
                                               name:_deviceName
                                               port:ODPort];
    [_bonjour setTXTRecordData:[NSNetService
        dataFromTXTRecordDictionary:@{@"id": [_uuid dataUsingEncoding:NSUTF8StringEncoding], @"pv": [@"3" dataUsingEncoding:NSUTF8StringEncoding]}]];
    [_bonjour publish];
}

#pragma mark - listen / accept

- (void)listen {
    _listenFD = socket(AF_INET, SOCK_STREAM, 0);
    if (_listenFD < 0) return;
    int one = 1;
    setsockopt(_listenFD, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(ODPort);
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    if (bind(_listenFD, (struct sockaddr *)&addr, sizeof(addr)) != 0 ||
        listen(_listenFD, 1) != 0) {
        close(_listenFD);
        _listenFD = -1;
        return;
    }
    [self startPingTimer];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [self acceptLoop];
    });
}

- (void)acceptLoop {
    for (;;) {
        struct sockaddr_in peer;
        socklen_t peerLen = sizeof(peer);
        int fd = accept(_listenFD, (struct sockaddr *)&peer, &peerLen);
        if (fd < 0) {
            if (_listenFD < 0) return; // listener torn down
            continue;
        }
        int one = 1;
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
        BOOL loopback = (ntohl(peer.sin_addr.s_addr) >> 24) == 127;
        NSString *transport = loopback ? @"USB" : @"Wi-Fi";
        dispatch_async(_queue, ^{ [self adoptConnection:fd transport:transport]; });
    }
}

#pragma mark - connection

- (void)adoptConnection:(int)fd transport:(NSString *)transport {
    // One sender at a time: a newcomer replaces the live connection.
    [self closeConnectionLocked];
    _connFD = fd;
    _transport = transport;
    _senderPV = 1;
    _dropVideo = NO;
    _lastRx = [NSDate timeIntervalSinceReferenceDate];
    [self sendHelloLocked];
    [self sendControlLocked:@{@"type": @"kf"}];
    id<ODSessionDelegate> delegate = _delegate;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [self readLoop:fd];
    });
    // Decoder reset + UI on the delegate's terms; video lockstep below.
    [delegate sessionDecoderShouldReset:self];
    [delegate sessionDidConnect:self transport:transport];
}

- (void)closeConnectionLocked {
    if (_connFD >= 0) {
        shutdown(_connFD, SHUT_RDWR);
        close(_connFD);
        _connFD = -1;
        _transport = nil;
        [_delegate sessionDidDisconnect:self];
    }
}

- (void)closeConnection {
    dispatch_async(_queue, ^{ [self closeConnectionLocked]; });
}

#pragma mark - read

- (ssize_t)readBytes:(int)fd buffer:(uint8_t *)buffer length:(size_t)length {
    size_t got = 0;
    while (got < length) {
        ssize_t n = recv(fd, buffer + got, length - got, 0);
        if (n <= 0) return n == 0 ? 0 : -1;
        got += (size_t)n;
    }
    return (ssize_t)got;
}

- (void)readLoop:(int)fd {
    for (;;) {
        uint8_t header[4];
        if ([self readBytes:fd buffer:header length:4] != 4) break;
        uint32_t length = [ODWire bigEndianLength:header];
        if (length == 0 || length > ODMaxFrame) break; // protocol error
        NSMutableData *payload = [NSMutableData dataWithLength:length];
        if ([self readBytes:fd buffer:(uint8_t *)[payload mutableBytes]
                     length:length] != (ssize_t)length) break;
        __block BOOL mine = NO;
        dispatch_sync(_queue, ^{
            mine = (self->_connFD == fd);
            self->_lastRx = [NSDate timeIntervalSinceReferenceDate];
        });
        if (!mine) break; // replaced while reading; drop the rest
        [self handlePayload:payload];
    }
    dispatch_async(_queue, ^{
        if (self->_connFD == fd) [self closeConnectionLocked];
    });
}

- (void)handlePayload:(NSData *)payload {
    const uint8_t *bytes = (const uint8_t *)[payload bytes];
    NSUInteger length = [payload length];
    if ([ODWire isJSONControlPayload:bytes length:length]) {
        id object = [ODWire JSONObjectWithPayload:payload];
        if ([object isKindOfClass:[NSDictionary class]]) {
            [self handleControl:(NSDictionary *)object];
        }
        return;
    }
    __block BOOL drop = NO;
    dispatch_sync(_queue, ^{ drop = self->_dropVideo; });
    if (!drop) [_delegate session:self didReceiveVideoFrame:payload];
}

- (void)handleControl:(NSDictionary *)message {
    NSString *type = message[@"type"];
    if (![type isKindOfClass:[NSString class]]) return;
    if ([type isEqualToString:@"welcome"]) {
        NSNumber *pv = message[@"pv"];
        __block NSString *info = nil;
        dispatch_async(_queue, ^{
            if ([pv isKindOfClass:[NSNumber class]]) self->_senderPV = [pv integerValue];
            info = [NSString stringWithFormat:@"sender pv%ld", (long)self->_senderPV];
            [self->_delegate session:self didUpdateSenderInfo:info];
        });
    } else if ([type isEqualToString:@"streamConfig"]) {
        NSString *codec = message[@"codec"];
        NSNumber *w = message[@"width"], *h = message[@"height"];
        dispatch_async(_queue, ^{
            // The A5 has no HEVC decoder: refuse anything but H.264.
            self->_dropVideo = ![[codec lowercaseString] isEqualToString:@"h264"];
            NSString *info = [NSString stringWithFormat:@"%@ %@x%@",
                              codec ?: @"h264", w ?: @"?", h ?: @"?"];
            [self->_delegate session:self didUpdateSenderInfo:info];
        });
    } else if ([type isEqualToString:@"pong"]) {
        // Clock-sync plumbing is optional; liveness rides on any bytes.
    } else if ([type isEqualToString:@"ping"]) {
        // Answering the sender's ping is not required; its bytes already
        // feed the watchdog.
    } else if ([type isEqualToString:@"updateRequired"]) {
        NSString *messageText = message[@"message"];
        NSString *store = message[@"store"];
        if (![messageText isKindOfClass:[NSString class]]) messageText = @"Update required";
        if (![store isKindOfClass:[NSString class]]) store = @"";
        [_delegate session:self didReceiveUpdateRequired:messageText store:store];
    }
    // cursor, cursorImg and unknown types are ignored (no cursor rendering).
}

#pragma mark - send

- (void)sendControlLocked:(NSDictionary *)object {
    if (_connFD < 0) return;
    NSData *frame = [ODWire frameWithJSONObject:object];
    if (!frame) return;
    const uint8_t *bytes = (const uint8_t *)[frame bytes];
    size_t left = [frame length];
    int fd = _connFD;
    while (left > 0) {
        ssize_t n = send(fd, bytes + ([frame length] - left), left, 0);
        if (n <= 0) break;
        left -= (size_t)n;
    }
}

- (void)sendHelloLocked {
    [self sendControlLocked:[ODHello helloWithUUID:_uuid landscape:_landscape]];
}

- (void)setLandscape:(BOOL)landscape {
    dispatch_async(_queue, ^{
        self->_landscape = landscape;
        [self sendHelloLocked]; // rotation re-hello on the live connection
    });
}

- (void)sendKeyframeRequest {
    dispatch_async(_queue, ^{ [self sendControlLocked:@{@"type": @"kf"}]; });
}

- (void)sendTouchPhase:(NSString *)phase x:(double)x y:(double)y {
    NSDictionary *message = @{@"type": @"touch", @"phase": phase,
                              @"x": @(x), @"y": @(y)};
    dispatch_async(_queue, ^{ [self sendControlLocked:message]; });
}

- (void)sendScrollDX:(double)dx dy:(double)dy {
    NSDictionary *message = @{@"type": @"scroll", @"dx": @(dx), @"dy": @(dy)};
    dispatch_async(_queue, ^{ [self sendControlLocked:message]; });
}

- (void)sendStats:(NSDictionary *)stats {
    NSMutableDictionary *message = [NSMutableDictionary dictionaryWithDictionary:stats];
    message[@"type"] = @"stats";
    dispatch_async(_queue, ^{ [self sendControlLocked:message]; });
}

- (void)sendPingLocked {
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (_connFD >= 0 && now - _lastRx > ODTimeout) {
        [self closeConnectionLocked]; // dead link: keep listening
        return;
    }
    double millis = [NSDate date].timeIntervalSince1970 * 1000.0;
    [self sendControlLocked:@{@"type": @"ping", @"t": @(millis)}];
}

#pragma mark - timers

- (void)startPingTimer {
    _pingTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _queue);
    dispatch_source_set_timer(_pingTimer,
                              dispatch_time(DISPATCH_TIME_NOW,
                                            (int64_t)(ODPingInterval * NSEC_PER_SEC)),
                              (uint64_t)(ODPingInterval * NSEC_PER_SEC),
                              (uint64_t)(NSEC_PER_SEC / 2));
    dispatch_source_set_event_handler(_pingTimer, ^{ [self sendPingLocked]; });
    dispatch_resume(_pingTimer);
}

- (void)stopTimers {
    if (_pingTimer) {
        dispatch_source_cancel(_pingTimer);
        _pingTimer = NULL;
    }
}

@end
