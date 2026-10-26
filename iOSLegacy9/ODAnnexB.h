// ODAnnexB.h — H.264 Annex B access-unit splitting. Foundation only.
#import <Foundation/Foundation.h>

@interface ODAnnexB : NSObject

// Split one wire frame into NALUs (start codes stripped). Everything
// before the first 4-byte start code is the telemetry prefix: returned
// via outPrefix (nil when absent), never treated as a NALU.
+ (NSArray<NSData *> *)splitAccessUnit:(NSData *)au
                        telemetryPrefix:(NSData **)outPrefix;

// H.264 NALU type: first payload byte & 0x1F.
+ (NSUInteger)naluType:(NSData *)nalu;

// YES when either parameter set differs from the previous one.
+ (BOOL)parameterSetsChangedSPS:(NSArray<NSData *> *)sps
                            PPS:(NSArray<NSData *> *)pps
                         oldSPS:(NSArray<NSData *> *)oldSPS
                         oldPPS:(NSArray<NSData *> *)oldPPS;

@end
