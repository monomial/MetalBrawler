#import "AppDelegate.h"
#import "GameViewController.h"
#import "Audio/AudioEngine.h"

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    // Initialize audio engine at startup to avoid first-hit hitch (T7).
    [[[AudioEngine alloc] init] startupInit];

    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [[GameViewController alloc] init];
    [self.window makeKeyAndVisible];
    return YES;
}

@end
