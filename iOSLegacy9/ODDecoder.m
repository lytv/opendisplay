// ODDecoder.m — H.264 Annex B decode into a display sink.
#import "ODDecoder.h"
#import "ODAnnexB.h"
#import <VideoToolbox/VideoToolbox.h>
#import <libkern/OSAtomic.h>

static void ODFreeBlock(void *refCon, void *doomedMemoryBlock,
                    size_t sizeInBytes) {
    (void)refCon; (void)sizeInBytes;
    free(doomedMemoryBlock);
}

static void ODDecodeCallback(void *refcon,
                             void *sourceFrameRefCon,
                             OSStatus status,
                             VTDecodeInfoFlags infoFlags,
                             CVImageBufferRef imageBuffer,
                             CMTime presentationTimeStamp,
                             CMTime presentationDuration) {
    (void)sourceFrameRefCon; (void)infoFlags;
    (void)presentationTimeStamp; (void)presentationDuration;
    ODDecoder *self = (__bridge ODDecoder *)refcon;
    OSAtomicDecrement32(&self->_outstanding);
    if (status != noErr || imageBuffer == NULL) {
        NSLog(@"ODDecoder: decode callback failed: %d (flags %u)",
              (int)status, (unsigned)infoFlags);
        if (self.keyframeRequest) self.keyframeRequest();
        @synchronized(self) { self->_needsRebuild = YES; }
        return;
    }
    @synchronized(self) { self->_decodedFrames++; }
    CMSampleBufferRef sampleBuffer = NULL;
    CMVideoFormatDescriptionRef format = NULL;
    int64_t frameNumber = 0;
    @synchronized(self) {
        // The wrap needs an IMAGE format description (pixel type + dims),
        // not the compressed H.264 description used to build the session.
        if (!self->_imageFormatDescription && imageBuffer) {
            CMVideoFormatDescriptionCreateForImageBuffer(
                kCFAllocatorDefault, imageBuffer,
                &self->_imageFormatDescription);
        }
        format = self->_imageFormatDescription;
        if (format) CFRetain(format);
        frameNumber = self->_decodedFrames;
    }
    if (format) {
        // The layer presents in enqueue order; stamps only need validity.
        CMTime stamp = CMTimeMake(frameNumber, 30);
        CMSampleTimingInfo timing;
        timing.duration = CMTimeMake(1, 30);
        timing.presentationTimeStamp = stamp;
        timing.decodeTimeStamp = stamp;
        OSStatus st = CMSampleBufferCreateForImageBuffer(
            kCFAllocatorDefault, imageBuffer, true, NULL, NULL,
            format, &timing, &sampleBuffer);
        CFRelease(format);
        if (st == noErr && sampleBuffer) {
            [self->_sink enqueueSampleBuffer:sampleBuffer];
            CFRelease(sampleBuffer);
            NSInteger w = self.videoWidth, h = self.videoHeight;
            if (self.frameDecoded) self.frameDecoded(w, h);
        } else {
            NSError *err = [NSError errorWithDomain:NSOSStatusErrorDomain
                                               code:st userInfo:nil];
            NSLog(@"ODDecoder: sample wrap failed: %d %@", (int)st,
                  [err localizedDescription]);
        }
    }
}

@implementation ODDecoder

- (instancetype)initWithSink:(id<ODDisplaySink>)sink {
    if ((self = [super init])) {
        _sink = sink;
    }
    return self;
}

- (void)dealloc {
    [self reset];
}

- (int32_t)outstanding { return _outstanding; }
- (NSInteger)videoWidth { return _videoWidth; }
- (NSInteger)videoHeight { return _videoHeight; }
- (NSUInteger)decodedFrames { return _decodedFrames; }
- (NSUInteger)droppedFrames { return _droppedFrames; }

- (void)reset {
    // Never wait for in-flight callbacks while holding the lock:
    // callbacks take the same lock, so that deadlocks.
    VTDecompressionSessionRef session = NULL;
    CMVideoFormatDescriptionRef format = NULL;
    CMVideoFormatDescriptionRef imageFormat = NULL;
    @synchronized(self) {
        session = _session;
        _session = NULL;
        format = _formatDescription;
        _formatDescription = NULL;
        imageFormat = _imageFormatDescription;
        _imageFormatDescription = NULL;
        _sps = nil;
        _pps = nil;
        _needsRebuild = NO;
        _videoWidth = 0;
        _videoHeight = 0;
    }
    if (session) {
        VTDecompressionSessionWaitForAsynchronousFrames(session);
        VTDecompressionSessionInvalidate(session);
        CFRelease(session);
    }
    if (format) CFRelease(format);
    if (imageFormat) CFRelease(imageFormat);
    _outstanding = 0;
}

// Build (or rebuild) the session when the parameter sets changed.
- (BOOL)ensureSessionForSPS:(NSArray<NSData *> *)sps PPS:(NSArray<NSData *> *)pps {
    @synchronized(self) {
        if (_session && !_needsRebuild &&
            ![ODAnnexB parameterSetsChangedSPS:sps PPS:pps oldSPS:_sps oldPPS:_pps]) {
            return YES;
        }
    }
    // Tear down outside the lock: waiting for in-flight callbacks while
    // holding it deadlocks (callbacks take the same lock).
    VTDecompressionSessionRef oldSession = NULL;
    CMVideoFormatDescriptionRef oldFormat = NULL;
    CMVideoFormatDescriptionRef oldImageFormat = NULL;
    @synchronized(self) {
        oldSession = _session;
        _session = NULL;
        oldFormat = _formatDescription;
        _formatDescription = NULL;
        oldImageFormat = _imageFormatDescription;
        _imageFormatDescription = NULL;
    }
    if (oldSession) {
        VTDecompressionSessionWaitForAsynchronousFrames(oldSession);
        VTDecompressionSessionInvalidate(oldSession);
        CFRelease(oldSession);
    }
    if (oldFormat) CFRelease(oldFormat);
    if (oldImageFormat) CFRelease(oldImageFormat);
    CMVideoFormatDescriptionRef format = NULL;
    size_t count = [sps count] + [pps count];
        const uint8_t **pointers = malloc(sizeof(uint8_t *) * (count > 0 ? count : 1));
        size_t *sizes = malloc(sizeof(size_t) * (count > 0 ? count : 1));
        size_t i = 0;
        for (NSData *d in sps) { pointers[i] = (const uint8_t *)[d bytes]; sizes[i] = [d length]; i++; }
        for (NSData *d in pps) { pointers[i] = (const uint8_t *)[d bytes]; sizes[i] = [d length]; i++; }
        OSStatus st = CMVideoFormatDescriptionCreateFromH264ParameterSets(
            kCFAllocatorDefault, count, pointers, sizes, 4, &format);
        free(pointers);
        free(sizes);
        if (st != noErr || !format) {
            NSLog(@"ODDecoder: format description failed: %d", (int)st);
            return NO;
        }
        CMVideoDimensions dims = CMVideoFormatDescriptionGetDimensions(format);
        NSDictionary *pixelAttrs = @{
            (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
        };
        VTDecompressionOutputCallbackRecord callback;
        callback.decompressionOutputCallback = ODDecodeCallback;
        callback.decompressionOutputRefCon = (__bridge void *)self;
        VTDecompressionSessionRef session = NULL;
        st = VTDecompressionSessionCreate(kCFAllocatorDefault, format,
                                          NULL, (__bridge CFDictionaryRef)pixelAttrs,
                                          &callback, &session);
        if (st != noErr || !session) {
            NSLog(@"ODDecoder: session create failed: %d", (int)st);
            CFRelease(format);
            return NO;
        }
        @synchronized(self) {
            // A concurrent reset wins: drop what we just built.
            if (_session || _formatDescription) {
                VTDecompressionSessionInvalidate(session);
                CFRelease(session);
                CFRelease(format);
                return NO;
            }
            _formatDescription = format;
            _session = session;
            _videoWidth = dims.width;
            _videoHeight = dims.height;
            _sps = [sps copy];
            _pps = [pps copy];
            _needsRebuild = NO;
        }
    if (self.keyframeRequest) self.keyframeRequest();
    return YES;
}

- (void)decodeAccessUnit:(NSData *)au {
    if (!au || [au length] == 0) return;
    NSData *prefix = nil;
    NSArray<NSData *> *nalus = [ODAnnexB splitAccessUnit:au telemetryPrefix:&prefix];
    (void)prefix; // latency telemetry only; display runs in arrival order.
    NSMutableArray<NSData *> *sps = [NSMutableArray array];
    NSMutableArray<NSData *> *pps = [NSMutableArray array];
    BOOL hasIDR = NO;
    for (NSData *nalu in nalus) {
        switch ([ODAnnexB naluType:nalu]) {
            case 7: [sps addObject:nalu]; break;
            case 8: [pps addObject:nalu]; break;
            case 5: hasIDR = YES; break;
            default: break;
        }
    }
    BOOL haveParams = NO;
    @synchronized(self) { haveParams = (_formatDescription != NULL); }
    if ([sps count] > 0 && [pps count] > 0) {
        if (![self ensureSessionForSPS:sps PPS:pps]) {
            if (self.keyframeRequest) self.keyframeRequest();
            return;
        }
    } else if (!haveParams) {
        // No parameter sets yet: cannot decode, ask for an IDR.
        if (self.keyframeRequest) self.keyframeRequest();
        return;
    }
    // A5 cap: shed non-keyframes past two outstanding decodes.
    if (_outstanding > 2 && !hasIDR) {
        @synchronized(self) { _droppedFrames++; }
        return;
    }
    // Annex B to AVCC: swap each start code for a big-endian NALU length.
    NSMutableData *avcc = [NSMutableData dataWithCapacity:[au length]];
    for (NSData *nalu in nalus) {
        uint32_t len = (uint32_t)[nalu length];
        uint8_t header[4] = {
            (uint8_t)((len >> 24) & 0xFF), (uint8_t)((len >> 16) & 0xFF),
            (uint8_t)((len >> 8) & 0xFF), (uint8_t)(len & 0xFF),
        };
        [avcc appendBytes:header length:4];
        [avcc appendData:nalu];
    }
    VTDecompressionSessionRef session = NULL;
    CMVideoFormatDescriptionRef format = NULL;
    @synchronized(self) {
        session = _session; if (session) CFRetain(session);
        format = _formatDescription; if (format) CFRetain(format);
    }
    if (!session) {
        if (self.keyframeRequest) self.keyframeRequest();
        return;
    }
    CMBlockBufferRef block = NULL;
    // The block buffer takes ownership of this copy and frees it.
    void *copy = malloc([avcc length]);
    if (!copy) { CFRelease(session); return; }
    memcpy(copy, [avcc bytes], [avcc length]);
    CMBlockBufferCustomBlockSource source;
    memset(&source, 0, sizeof(source));
    source.FreeBlock = ODFreeBlock;
    OSStatus st = CMBlockBufferCreateWithMemoryBlock(
        kCFAllocatorDefault, copy, [avcc length],
        kCFAllocatorNull, &source, 0, [avcc length], 0, &block);
    if (st != noErr) { free(copy); CFRelease(session); return; }
    CMSampleBufferRef sample = NULL;
    size_t sampleSize = [avcc length];
    // The block copies nothing: keep avcc alive until decode returns.
    st = CMSampleBufferCreate(kCFAllocatorDefault, block, true, NULL, NULL,
                              format, 1, 0, NULL, 1, &sampleSize, &sample);
    if (format) CFRelease(format);
    if (st != noErr || !sample) { CFRelease(block); CFRelease(session); return; }
    OSAtomicIncrement32(&_outstanding);
    VTDecodeInfoFlags flagsOut = 0;
    st = VTDecompressionSessionDecodeFrame(
        session, sample, kVTDecodeFrame_EnableAsynchronousDecompression,
        NULL, &flagsOut);
    // Retain avcc across the async decode via the block's custom source?
    // The block references avcc bytes without copying, so hold avcc until
    // the callback drains: bridge it through an associated retain.
    if (st != noErr) {
        NSLog(@"ODDecoder: decode submit failed: %d", (int)st);
        OSAtomicDecrement32(&_outstanding);
        if (self.keyframeRequest) self.keyframeRequest();
        @synchronized(self) { _needsRebuild = YES; }
    }
    CFRelease(sample);
    CFRelease(block);
    CFRelease(session);
}

@end
