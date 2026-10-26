// ODHello.m — builds the pv3 hello for the 1024x768 1x iPad 2 panel.
#import "ODHello.h"

@implementation ODHello

+ (NSInteger)panelWide:(BOOL)landscape { return landscape ? 1024 : 768; }
+ (NSInteger)panelHigh:(BOOL)landscape { return landscape ? 768 : 1024; }

+ (NSDictionary *)helloWithUUID:(NSString *)uuid landscape:(BOOL)landscape {
    NSInteger wide = [self panelWide:landscape];
    NSInteger high = [self panelHigh:landscape];
    // 1024*768*30: the A5 decode envelope we can sustain.
    const NSInteger maxPixelsPerSecond = 1024 * 768 * 30;
    NSDictionary *panel = @{
        @"pixelsWide": @(wide),
        @"pixelsHigh": @(high),
        @"scale": @1,
        @"pointsWide": @(wide),
        @"pointsHigh": @(high),
    };
    NSDictionary *h264 = @{
        @"codec": @"h264",
        @"maxWidth": @1024,
        @"maxHeight": @768,
        @"maxFrameRate": @30,
        @"maxPixelsPerSecond": @(maxPixelsPerSecond),
    };
    return @{
        @"type": @"hello",
        @"pixelsWide": @(wide),
        @"pixelsHigh": @(high),
        @"scale": @1,
        @"panel": panel,
        @"device": @"iPad",
        @"id": uuid ?: @"",
        @"pv": @3,
        @"displayMaxFrameRate": @30,
        @"maxEncodeWide": @1024,
        @"maxEncodeHigh": @768,
        @"videoCaps": @[h264],
    };
}

@end
