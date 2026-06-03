#import "SceneDelegate.h"
#import "GameViewController.h"

@implementation SceneDelegate

- (void)scene:(UIScene *)scene
    willConnectToSession:(UISceneSession *)session
                 options:(UISceneConnectionOptions *)connectionOptions {
    UIWindowScene *ws = (UIWindowScene *)scene;
    self.window = [[UIWindow alloc] initWithWindowScene:ws];
    self.window.rootViewController = [[GameViewController alloc] init];
    [self.window makeKeyAndVisible];
}

- (void)sceneDidBecomeActive:(UIScene *)scene {
    [(GameViewController *)self.window.rootViewController resumeRendering];
}

- (void)sceneWillResignActive:(UIScene *)scene {
    [(GameViewController *)self.window.rootViewController pauseRendering];
}

@end
