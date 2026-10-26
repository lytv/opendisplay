// ODHello.h — builds the pv3 hello for the 1024x768 1x iPad 2 panel.
#import <Foundation/Foundation.h>

@interface ODHello : NSObject

+ (NSDictionary *)helloWithUUID:(NSString *)uuid landscape:(BOOL)landscape;

+ (NSInteger)panelWide:(BOOL)landscape;
+ (NSInteger)panelHigh:(BOOL)landscape;

@end
