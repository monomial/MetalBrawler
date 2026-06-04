#import "GameViewController.h"
#import <MetalKit/MetalKit.h>
#import <GameController/GameController.h>
#import "BrawlerGameDelegate.h"
#include "Platform/InputState.h"
#include "Platform/SiriRemoteInput.h"

// Maps up to 4 GCControllers to player slots (index = player 0–3, value = controller or nil).
static const int kMaxPlayers = 4;

@implementation GameViewController {
    MTKView             *_mtkView;
    BrawlerGameDelegate *_delegate;
    GCController        *_assignedControllers[kMaxPlayers];
    UILabel             *_overlayLabel;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    memset(_assignedControllers, 0, sizeof(_assignedControllers));

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

    // Phase overlay label — centered, hidden during normal play.
    _overlayLabel = [[UILabel alloc] initWithFrame:self.view.bounds];
    _overlayLabel.numberOfLines       = 0;
    _overlayLabel.textAlignment       = NSTextAlignmentCenter;
    _overlayLabel.textColor           = [UIColor whiteColor];
    _overlayLabel.font                = [UIFont boldSystemFontOfSize:72];
    _overlayLabel.backgroundColor     = [UIColor colorWithWhite:0 alpha:0.72];
    _overlayLabel.hidden              = YES;
    _overlayLabel.autoresizingMask    = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:_overlayLabel];

    __weak GameViewController *weakSelf = self;
    _delegate.onPhaseChanged = ^(BrawlerGamePhase phase, int room, int lives) {
        GameViewController *vc = weakSelf;
        if (!vc) return;
        [vc _updateOverlayForPhase:phase room:room lives:lives];
    };

    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(_controllerConnected:)
               name:GCControllerDidConnectNotification
             object:nil];
    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(_controllerDisconnected:)
               name:GCControllerDidDisconnectNotification
             object:nil];
    [GCController startWirelessControllerDiscoveryWithCompletionHandler:nil];
}

- (void)pauseRendering  { [_delegate resetInput]; _mtkView.paused = YES; }
- (void)resumeRendering { _mtkView.paused = NO; }

- (void)_updateOverlayForPhase:(BrawlerGamePhase)phase room:(int)room lives:(int)lives {
    switch (phase) {
        case BrawlerGamePhasePlaying:
            _overlayLabel.hidden = YES;
            break;
        case BrawlerGamePhaseRoomClear:
            _overlayLabel.text   = [NSString stringWithFormat:@"Room %d Clear!", room];
            _overlayLabel.hidden = NO;
            break;
        case BrawlerGamePhaseWin:
            _overlayLabel.text   = @"YOU WIN!\nAll rooms cleared!";
            _overlayLabel.hidden = NO;
            break;
        case BrawlerGamePhaseLose:
            _overlayLabel.text   = @"GAME OVER";
            _overlayLabel.hidden = NO;
            break;
    }
}

// ---------------------------------------------------------------------------
// Assigns incoming controller to the next free player slot.
// ---------------------------------------------------------------------------
- (void)_controllerConnected:(NSNotification *)note {
    GCController *ctrl = note.object;
    if (!ctrl) return;

    // Find first free slot.
    int slot = -1;
    for (int i = 0; i < kMaxPlayers; ++i) {
        if (!_assignedControllers[i]) { slot = i; break; }
    }
    if (slot < 0) return; // all slots full

    _assignedControllers[slot] = ctrl;
    [self _wireController:ctrl toSlot:slot];
}

- (void)_controllerDisconnected:(NSNotification *)note {
    GCController *ctrl = note.object;
    for (int i = 0; i < kMaxPlayers; ++i) {
        if (_assignedControllers[i] == ctrl) {
            _assignedControllers[i] = nil;
            // Zero that player's input so they don't keep moving.
            [_delegate setInputState:{} forPlayer:i];
            break;
        }
    }
}

- (void)_wireController:(GCController *)ctrl toSlot:(int)slot {
    // Extended gamepad first (PS4/Xbox/Switch Pro — all report non-nil microGamepad too).
    GCExtendedGamepad *ext = ctrl.extendedGamepad;
    if (ext) {
        __weak GameViewController *weakSelf = self;
        ext.leftThumbstick.valueChangedHandler = ^(GCControllerDirectionPad *pad, float x, float y) {
            GameViewController *vc = weakSelf;
            if (!vc) return;
            InputState s = [vc->_delegate currentInputStateForPlayer:slot];
            s.moveX = x; s.moveY = y;
            [vc->_delegate setInputState:s forPlayer:slot];
        };
        ext.buttonA.valueChangedHandler = ^(GCControllerButtonInput *btn, float val, BOOL pressed) {
            GameViewController *vc = weakSelf;
            if (!vc) return;
            InputState s = [vc->_delegate currentInputStateForPlayer:slot];
            s.attack = pressed;
            [vc->_delegate setInputState:s forPlayer:slot];
        };
        return;
    }

    // Siri Remote only (micro-gamepad, no extended profile).
    GCMicroGamepad *micro = ctrl.microGamepad;
    if (micro) {
        micro.reportsAbsoluteDpadValues = NO;
        __weak GameViewController *weakSelf = self;
        micro.dpad.valueChangedHandler = ^(GCControllerDirectionPad *dpad, float x, float y) {
            GameViewController *vc = weakSelf;
            if (!vc) return;
            [vc->_delegate setInputState:SiriRemote_processSwipeDelta(x, y) forPlayer:slot];
        };
        micro.buttonA.valueChangedHandler = ^(GCControllerButtonInput *btn, float val, BOOL pressed) {
            GameViewController *vc = weakSelf;
            if (!vc) return;
            InputState s = [vc->_delegate currentInputStateForPlayer:slot];
            s.attack = pressed;
            [vc->_delegate setInputState:s forPlayer:slot];
        };
    }
}

@end
