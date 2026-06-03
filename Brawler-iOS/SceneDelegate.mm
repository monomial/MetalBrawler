#import "SceneDelegate.h"
#import "GameViewController.h"
#import "Audio/AudioEngine.h"

@implementation SceneDelegate

- (void)scene:(UIScene *)scene
    willConnectToSession:(UISceneSession *)session
                 options:(UISceneConnectionOptions *)connectionOptions {
    // Initialize audio engine at startup to avoid first-hit hitch (T7).
    [[[AudioEngine alloc] init] startupInit];

    UIWindowScene *ws = (UIWindowScene *)scene;
    self.window = [[UIWindow alloc] initWithWindowScene:ws];
    self.window.rootViewController = [[GameViewController alloc] init];
    [self.window makeKeyAndVisible];
}

@end
