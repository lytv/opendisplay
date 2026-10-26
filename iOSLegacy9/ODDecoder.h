// ODDecoder.h — H.264 Annex B decode into a display sink.
// VideoToolbox + Foundation only: compiles for armv7 and the macOS host test.
#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <VideoToolbox/VideoToolbox.h>

@protocol ODDisplaySink <NSObject>
- (void)enqueueSampleBuffer:(CMSampleBufferRef)sampleBuffer;
@end

@interface ODDecoder : NSObject {
@public
    int32_t _outstanding;
    id<ODDisplaySink> _sink;
    VTDecompressionSessionRef _session;
    CMVideoFormatDescriptionRef _formatDescription;
    CMVideoFormatDescriptionRef _imageFormatDescription;
    NSArray<NSData *> *_sps;
    NSArray<NSData *> *_pps;
    BOOL _needsRebuild;
    NSUInteger _decodedFrames;
    NSUInteger _droppedFrames;
    NSInteger _videoWidth;
    NSInteger _videoHeight;
}

@property (nonatomic, readonly) int32_t outstanding;
@property (nonatomic, readonly) NSInteger videoWidth;
@property (nonatomic, readonly) NSInteger videoHeight;
@property (nonatomic, readonly) NSUInteger decodedFrames;
@property (nonatomic, readonly) NSUInteger droppedFrames;

// Invoked when the sender must produce an IDR: connect, session
// creation, decode failure. May fire on any queue.
@property (nonatomic, copy) void (^keyframeRequest)(void);
// Invoked after each decoded frame with the stream raster.
@property (nonatomic, copy) void (^frameDecoded)(NSInteger width, NSInteger height);

- (instancetype)initWithSink:(id<ODDisplaySink>)sink;

// One wire frame (one access unit, telemetry prefix tolerated).
- (void)decodeAccessUnit:(NSData *)au;

// Tear down the session: called when a new sender replaces the old one.
- (void)reset;

@end
