// ODAppDelegate.m
#import "ODAppDelegate.h"
#import "ODReceiverViewController.h"

@implementation ODAppDelegate

- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    (void)application; (void)launchOptions;
    self.window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    self.window.rootViewController = [[ODReceiverViewController alloc] init];
    [self.window makeKeyAndVisible];
    // A second display must never sleep mid-session.
    [UIApplication sharedApplication].idleTimerDisabled = YES;
    return YES;
}

@end
