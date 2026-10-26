// ODWire.h — length-prefix framing + section 4 demux. Foundation only.
#import <Foundation/Foundation.h>

@interface ODWire : NSObject

// 4-byte big-endian length header + payload.
+ (NSData *)frameWithPayload:(NSData *)payload;
// Compact-JSON frame for a control dictionary.
+ (NSData *)frameWithJSONObject:(NSDictionary *)object;
// Parse a control payload; nil when not valid JSON.
+ (id)JSONObjectWithPayload:(NSData *)payload;

// PROTOCOL.md section 4 demux: JSON control iff length < 32768,
// first byte is '{', and no NUL byte appears. Anything else is video.
+ (BOOL)isJSONControlPayload:(const uint8_t *)bytes length:(NSUInteger)length;

+ (uint32_t)bigEndianLength:(const uint8_t *)bytes;

@end
