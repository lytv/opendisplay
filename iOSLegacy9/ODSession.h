// ODSession.h — TCP listener, Bonjour, frame loop, liveness.
// BSD sockets + Foundation only: no UIKit, no Network.framework.
#import <Foundation/Foundation.h>

@class ODSession;

@protocol ODSessionDelegate <NSObject>
- (void)sessionDidConnect:(ODSession *)session transport:(NSString *)transport;
- (void)sessionDidDisconnect:(ODSession *)session;
// Called on the connection read thread; must not block.
- (void)session:(ODSession *)session didReceiveVideoFrame:(NSData *)frame;
- (void)sessionDecoderShouldReset:(ODSession *)session;
- (void)session:(ODSession *)session didReceiveUpdateRequired:(NSString *)message
          store:(NSString *)store;
- (void)session:(ODSession *)session didUpdateSenderInfo:(NSString *)info;
@end

@interface ODSession : NSObject

- (instancetype)initWithDeviceUUID:(NSString *)uuid
                        deviceName:(NSString *)deviceName
                          delegate:(id<ODSessionDelegate>)delegate;

- (void)start; // listen on :9000, publish Bonjour. Call on the main thread.

// Rotation: swap announced dimensions and re-send hello when connected.
- (void)setLandscape:(BOOL)landscape;
- (BOOL)isLandscape;

- (void)sendKeyframeRequest;
- (void)sendTouchPhase:(NSString *)phase x:(double)x y:(double)y;
- (void)sendScrollDX:(double)dx dy:(double)dy;
- (void)sendStats:(NSDictionary *)stats;

- (BOOL)isConnected;
- (NSString *)transport; // @"USB", @"Wi-Fi", or nil when disconnected.

@end
