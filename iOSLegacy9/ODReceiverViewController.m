// ODReceiverViewController.m — video layer, status + fps overlay, input.
#import "ODReceiverViewController.h"
#import "ODSession.h"
#import "ODDecoder.h"
#import <AVFoundation/AVFoundation.h>

@interface ODLegacySink : NSObject <ODDisplaySink>
@property (nonatomic, readonly) AVSampleBufferDisplayLayer *layer;
- (instancetype)initWithLayer:(AVSampleBufferDisplayLayer *)layer;
@end

@implementation ODLegacySink {
    AVSampleBufferDisplayLayer *_layer;
}
- (instancetype)initWithLayer:(AVSampleBufferDisplayLayer *)layer {
    if ((self = [super init])) _layer = layer;
    return self;
}
- (AVSampleBufferDisplayLayer *)layer { return _layer; }
- (void)enqueueSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    [_layer enqueueSampleBuffer:sampleBuffer];
}
@end

@interface ODReceiverViewController () <ODSessionDelegate>
@end

@implementation ODReceiverViewController {
    ODSession *_session;
    ODDecoder *_decoder;
    ODLegacySink *_sink;
    AVSampleBufferDisplayLayer *_videoLayer;
    UILabel *_statusLabel;
    UILabel *_overlayLabel;
    NSString *_transport;
    NSString *_senderInfo;
    NSInteger _videoWidth;
    NSInteger _videoHeight;
    NSUInteger _framesThisSecond;
    NSTimer *_overlayTimer;
    NSTimer *_statsTimer;
    UITouch *_trackedTouch;
    BOOL _landscape;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor blackColor];
    self.view.multipleTouchEnabled = YES;
    UIInterfaceOrientation orientation =
        [UIApplication sharedApplication].statusBarOrientation;
    // Default landscape: the iPad 2 panel is 1024x768, and rotation
    // re-hellos with swapped dimensions anyway.
    _landscape = !UIInterfaceOrientationIsPortrait(orientation);
    _videoWidth = 1024;
    _videoHeight = 768;

    _videoLayer = [[AVSampleBufferDisplayLayer alloc] init];
    _videoLayer.videoGravity = AVLayerVideoGravityResizeAspect;
    _videoLayer.backgroundColor =
        [UIColor blackColor].CGColor;
    [self.view.layer addSublayer:_videoLayer];

    _statusLabel = [[UILabel alloc] init];
    _statusLabel.textColor = [UIColor whiteColor];
    _statusLabel.textAlignment = NSTextAlignmentCenter;
    _statusLabel.numberOfLines = 0;
    _statusLabel.text = @"Waiting for sender\u2026\nConnect over Wi-Fi or USB";
    [self.view addSubview:_statusLabel];

    _overlayLabel = [[UILabel alloc] init];
    _overlayLabel.textColor = [UIColor whiteColor];
    _overlayLabel.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.5];
    _overlayLabel.font = [UIFont systemFontOfSize:11];
    _overlayLabel.text = @"idle";
    [_overlayLabel sizeToFit];
    [self.view addSubview:_overlayLabel];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self
                                                                          action:@selector(didPan:)];
    pan.minimumNumberOfTouches = 2;
    pan.maximumNumberOfTouches = 2;
    [self.view addGestureRecognizer:pan];

    _sink = [[ODLegacySink alloc] initWithLayer:_videoLayer];
    __weak typeof(self) weakSelf = self;
    _decoder = [[ODDecoder alloc] initWithSink:_sink];
    _decoder.keyframeRequest = ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        [strongSelf->_session sendKeyframeRequest];
    };
    _decoder.frameDecoded = ^(NSInteger w, NSInteger h) {
        [weakSelf didDecodeFrameWithWidth:w height:h];
    };

    NSString *uuid = [[NSUserDefaults standardUserDefaults]
        stringForKey:@"ODLegacyInstallID"];
    if (!uuid) {
        uuid = [[NSUUID UUID] UUIDString];
        [[NSUserDefaults standardUserDefaults] setObject:uuid
                                                  forKey:@"ODLegacyInstallID"];
        [[NSUserDefaults standardUserDefaults] synchronize];
    }
    NSString *name = [[UIDevice currentDevice] name];
    _session = [[ODSession alloc] initWithDeviceUUID:uuid
                                          deviceName:name
                                            delegate:self];
    [_session start];

    _overlayTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                     target:self
                                                   selector:@selector(updateOverlay)
                                                   userInfo:nil
                                                    repeats:YES];
    _statsTimer = [NSTimer scheduledTimerWithTimeInterval:5.0
                                                   target:self
                                                 selector:@selector(sendStats)
                                                 userInfo:nil
                                                  repeats:YES];
    [self layoutVideo];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self layoutVideo];
}

- (void)layoutVideo {
    CGRect bounds = self.view.bounds;
    _videoLayer.frame = bounds;
    _statusLabel.frame = CGRectMake(20, bounds.size.height / 2 - 40,
                                    bounds.size.width - 40, 80);
    CGSize overlaySize = [_overlayLabel sizeThatFits:CGSizeMake(400, 20)];
    _overlayLabel.frame = CGRectMake(8, 8, overlaySize.width + 12, 20);
    [self.view bringSubviewToFront:_statusLabel];
    [self.view bringSubviewToFront:_overlayLabel];
}

- (BOOL)shouldAutorotate { return YES; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskAll;
}

- (void)viewWillTransitionToSize:(CGSize)size
       withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
    BOOL landscape = size.width >= size.height;
    if (landscape != _landscape) {
        _landscape = landscape;
        [_session setLandscape:landscape];
    }
}

#pragma mark - video rect (letterbox-aware)

- (CGRect)videoRect {
    CGRect bounds = self.view.bounds;
    if (_videoWidth <= 0 || _videoHeight <= 0) return bounds;
    CGFloat videoAspect = (CGFloat)_videoWidth / (CGFloat)_videoHeight;
    CGFloat viewAspect = bounds.size.width / bounds.size.height;
    if (videoAspect > viewAspect) {
        CGFloat h = bounds.size.width / videoAspect;
        return CGRectMake(0, (bounds.size.height - h) / 2,
                          bounds.size.width, h);
    }
    CGFloat w = bounds.size.height * videoAspect;
    return CGRectMake((bounds.size.width - w) / 2, 0, w, bounds.size.height);
}

- (CGPoint)normalizedPoint:(CGPoint)viewPoint {
    CGRect video = [self videoRect];
    CGFloat x = (viewPoint.x - video.origin.x) / video.size.width;
    CGFloat y = (viewPoint.y - video.origin.y) / video.size.height;
    x = MIN(1.0, MAX(0.0, x));
    y = MIN(1.0, MAX(0.0, y));
    return CGPointMake(x, y);
}

#pragma mark - ODSessionDelegate

- (void)sessionDidConnect:(ODSession *)session transport:(NSString *)transport {
    (void)session;
    dispatch_async(dispatch_get_main_queue(), ^{
        self->_transport = transport;
        self->_statusLabel.text = [NSString stringWithFormat:@"Connected (%@)", transport];
        self->_statusLabel.hidden = YES;
        [self updateOverlay];
    });
}

- (void)sessionDidDisconnect:(ODSession *)session {
    (void)session;
    dispatch_async(dispatch_get_main_queue(), ^{
        self->_transport = nil;
        self->_statusLabel.hidden = NO;
        self->_statusLabel.text = @"Waiting for sender\u2026\nConnect over Wi-Fi or USB";
        [self updateOverlay];
    });
}

- (void)session:(ODSession *)session didReceiveVideoFrame:(NSData *)frame {
    (void)session;
    [_decoder decodeAccessUnit:frame]; // decoder sheds load past 2 outstanding
}

- (void)sessionDecoderShouldReset:(ODSession *)session {
    (void)session;
    [_decoder reset];
    [_session sendKeyframeRequest];
}

- (void)session:(ODSession *)session
    didReceiveUpdateRequired:(NSString *)message
                       store:(NSString *)store {
    (void)session; (void)store;
    dispatch_async(dispatch_get_main_queue(), ^{
        self->_statusLabel.hidden = NO;
        self->_statusLabel.text = message;
    });
}

- (void)session:(ODSession *)session didUpdateSenderInfo:(NSString *)info {
    (void)session;
    dispatch_async(dispatch_get_main_queue(), ^{
        self->_senderInfo = info;
        [self updateOverlay];
    });
}

#pragma mark - decode + overlay

- (void)didDecodeFrameWithWidth:(NSInteger)w height:(NSInteger)h {
    _framesThisSecond++;
    if (w != _videoWidth || h != _videoHeight) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_videoWidth = w;
            self->_videoHeight = h;
            [self setNeedsStatusBarAppearanceUpdate];
            [self updateOverlay];
        });
    }
}

- (void)updateOverlay {
    NSString *link = _transport ?: @"idle";
    NSString *stream = [NSString stringWithFormat:@"%ldx%ld",
                        (long)_videoWidth, (long)_videoHeight];
    if (_senderInfo) stream = [stream stringByAppendingFormat:@" %@", _senderInfo];
    _overlayLabel.text = [NSString stringWithFormat:@"%lu fps  %@  %@",
                          (unsigned long)_framesThisSecond,
                          stream, link];
    _framesThisSecond = 0;
    [self layoutVideo];
}

- (void)sendStats {
    if (![_session isConnected]) return;
    [_session sendStats:@{@"transport": _transport ?: @"unknown",
                          @"fps": @(_framesThisSecond)}];
}

#pragma mark - input

- (void)sendTouch:(UITouch *)touch phase:(NSString *)phase {
    CGPoint p = [self normalizedPoint:[touch locationInView:self.view]];
    [_session sendTouchPhase:phase x:p.x y:p.y];
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)event;
    if (!_trackedTouch) {
        _trackedTouch = [touches anyObject];
        [self sendTouch:_trackedTouch phase:@"began"];
    }
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)event;
    if (_trackedTouch && [touches containsObject:_trackedTouch]) {
        [self sendTouch:_trackedTouch phase:@"moved"];
    }
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)event;
    if (_trackedTouch && [touches containsObject:_trackedTouch]) {
        [self sendTouch:_trackedTouch phase:@"ended"];
        _trackedTouch = nil;
    }
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)event;
    if (_trackedTouch && [touches containsObject:_trackedTouch]) {
        [self sendTouch:_trackedTouch phase:@"cancelled"];
        _trackedTouch = nil;
    }
}

// Two-finger pan: scroll in video pixels, natural-scrolling sign
// (content follows the fingers).
- (void)didPan:(UIPanGestureRecognizer *)pan {
    CGRect video = [self videoRect];
    CGFloat pixelsPerPoint = (CGFloat)_videoWidth / video.size.width;
    CGPoint translation = [pan translationInView:self.view];
    [pan setTranslation:CGPointZero inView:self.view];
    CGFloat dx = translation.x * pixelsPerPoint;
    CGFloat dy = translation.y * pixelsPerPoint;
    if (dx != 0 || dy != 0) {
        [_session sendScrollDX:dx dy:dy];
    }
}

@end
