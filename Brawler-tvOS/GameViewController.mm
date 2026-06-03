#import "GameViewController.h"
#import <MetalKit/MetalKit.h>
#import <GameController/GameController.h>
#import "BrawlerGameDelegate.h"
#include "Platform/InputState.h"
#include "Platform/SiriRemoteInput.h"

@implementation GameViewController {
    MTKView             *_mtkView;
    BrawlerGameDelegate *_delegate;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    _mtkView = [[MTKView alloc] initWithFrame:self.view.bounds device:device];
    _mtkView.autoresizingMask        = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _mtkView.colorPixelFormat        = MTLPixelFormatBGRA8Unorm;
    _mtkView.depthStencilPixelFormat = MTLPixelFormatDepth32Float;
    [self.view addSubview:_mtkView];

    _delegate = [[BrawlerGameDelegate alloc] initWithDevice:device
                                                pixelFormat:_mtkView.colorPixelFormat];
    [_delegate mtkView:_mtkView drawableSizeWillChange:_mtkView.drawableSize];
    _mtkView.delegate = _delegate;

    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(_controllerConnected:)
               name:GCControllerDidConnectNotification
             object:nil];
    [GCController startWirelessControllerDiscoveryWithCompletionHandler:nil];
}

- (void)pauseRendering  { [_delegate resetInput]; _mtkView.paused = YES; }
- (void)resumeRendering { _mtkView.paused = NO; }

- (void)_controllerConnected:(NSNotification *)note {
    GCController *ctrl = note.object;
    if (!ctrl) return;

    // Extended gamepad first — PS4/Xbox/Switch Pro all report non-nil microGamepad
    // too (it's a subset profile), so checking micro first incorrectly routes them
    // through SiriRemote_processSwipeDelta. Prefer extendedGamepad for full analog.
    GCExtendedGamepad *ext = ctrl.extendedGamepad;
    if (ext) {
        __weak GameViewController *weakSelf = self;
        ext.leftThumbstick.valueChangedHandler = ^(GCControllerDirectionPad *pad, float x, float y) {
            GameViewController *vc = weakSelf;
            if (!vc) return;
            InputState s = [vc->_delegate currentInputState];
            s.moveX = x; s.moveY = y;
            [vc->_delegate setInputState:s];
        };
        ext.buttonA.valueChangedHandler = ^(GCControllerButtonInput *btn, float val, BOOL pressed) {
            GameViewController *vc = weakSelf;
            if (!vc) return;
            InputState s = [vc->_delegate currentInputState];
            s.attack = pressed;
            [vc->_delegate setInputState:s];
        };
        return;
    }

    // Siri Remote only (micro-gamepad, no extended profile) — swipe delta input.
    GCMicroGamepad *micro = ctrl.microGamepad;
    if (micro) {
        micro.reportsAbsoluteDpadValues = NO;
        __weak GameViewController *weakSelf = self;
        micro.dpad.valueChangedHandler = ^(GCControllerDirectionPad *dpad, float x, float y) {
            GameViewController *vc = weakSelf;
            if (!vc) return;
            [vc->_delegate setInputState:SiriRemote_processSwipeDelta(x, y)];
        };
        micro.buttonA.valueChangedHandler = ^(GCControllerButtonInput *btn, float val, BOOL pressed) {
            GameViewController *vc = weakSelf;
            if (!vc) return;
            InputState s = [vc->_delegate currentInputState];
            s.attack = pressed;
            [vc->_delegate setInputState:s];
        };
    }
}

@end
