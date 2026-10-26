// ODAnnexB.m — H.264 Annex B access-unit splitting. Foundation only.
#import "ODAnnexB.h"

@implementation ODAnnexB

+ (NSArray<NSData *> *)splitAccessUnit:(NSData *)au
                       telemetryPrefix:(NSData **)outPrefix {
    NSMutableArray<NSData *> *nalus = [NSMutableArray array];
    if (outPrefix) *outPrefix = nil;
    const uint8_t *bytes = (const uint8_t *)[au bytes];
    NSUInteger length = [au length];
    if (length < 4) return nalus;
    // Offsets of every 4-byte start code.
    NSMutableArray<NSNumber *> *marks = [NSMutableArray array];
    for (NSUInteger i = 0; i + 4 <= length; i++) {
        if (bytes[i] == 0 && bytes[i + 1] == 0 &&
            bytes[i + 2] == 0 && bytes[i + 3] == 1) {
            [marks addObject:@(i)];
        }
    }
    if ([marks count] == 0) return nalus;
    NSUInteger first = [[marks objectAtIndex:0] unsignedIntegerValue];
    if (first > 0 && outPrefix) {
        *outPrefix = [au subdataWithRange:NSMakeRange(0, first)];
    }
    for (NSUInteger m = 0; m < [marks count]; m++) {
        NSUInteger start = [[marks objectAtIndex:m] unsignedIntegerValue] + 4;
        NSUInteger end = (m + 1 < [marks count])
            ? [[marks objectAtIndex:m + 1] unsignedIntegerValue]
            : length;
        // Skip trailing emulation-pattern overlaps: a start code scan can
        // end a NALU with stray zero padding; keep it simple and keep bytes.
        if (end > start) {
            [nalus addObject:[au subdataWithRange:NSMakeRange(start, end - start)]];
        }
    }
    return nalus;
}

+ (NSUInteger)naluType:(NSData *)nalu {
    if ([nalu length] == 0) return 0;
    const uint8_t *bytes = (const uint8_t *)[nalu bytes];
    return bytes[0] & 0x1F;
}

+ (BOOL)parameterSetsChangedSPS:(NSArray<NSData *> *)sps
                            PPS:(NSArray<NSData *> *)pps
                         oldSPS:(NSArray<NSData *> *)oldSPS
                         oldPPS:(NSArray<NSData *> *)oldPPS {
    return ![sps isEqualToArray:oldSPS] || ![pps isEqualToArray:oldPPS];
}

@end
