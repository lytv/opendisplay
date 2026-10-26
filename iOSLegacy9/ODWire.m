// ODWire.m — length-prefix framing + section 4 demux. Foundation only.
#import "ODWire.h"

@implementation ODWire

+ (NSData *)frameWithPayload:(NSData *)payload {
    uint32_t len = (uint32_t)[payload length];
    uint8_t header[4];
    header[0] = (uint8_t)((len >> 24) & 0xFF);
    header[1] = (uint8_t)((len >> 16) & 0xFF);
    header[2] = (uint8_t)((len >> 8) & 0xFF);
    header[3] = (uint8_t)(len & 0xFF);
    NSMutableData *frame = [NSMutableData dataWithCapacity:4 + [payload length]];
    [frame appendBytes:header length:4];
    [frame appendData:payload];
    return frame;
}

+ (NSData *)frameWithJSONObject:(NSDictionary *)object {
    NSData *payload = [NSJSONSerialization dataWithJSONObject:object
                                                      options:0
                                                        error:NULL];
    if (!payload) return nil;
    return [self frameWithPayload:payload];
}

+ (id)JSONObjectWithPayload:(NSData *)payload {
    if (!payload || [payload length] == 0) return nil;
    return [NSJSONSerialization JSONObjectWithData:payload options:0 error:NULL];
}

+ (BOOL)isJSONControlPayload:(const uint8_t *)bytes length:(NSUInteger)length {
    if (length == 0 || length >= 32768) return NO;
    if (bytes[0] != '{') return NO;
    for (NSUInteger i = 0; i < length; i++) {
        if (bytes[i] == 0x00) return NO;
    }
    return YES;
}

+ (uint32_t)bigEndianLength:(const uint8_t *)bytes {
    return ((uint32_t)bytes[0] << 24) | ((uint32_t)bytes[1] << 16) |
           ((uint32_t)bytes[2] << 8) | (uint32_t)bytes[3];
}

@end
