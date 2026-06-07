#import "GameViewController.h"
#import <MetalKit/MetalKit.h>
#import <GameController/GameController.h>
#import "BrawlerGameDelegate.h"
#import "BrawlerStrings.h"
#include "Platform/InputState.h"

// Maps up to 4 GCControllers to player slots (index = player 0–3, value = controller or nil).
static const int kMaxPlayers = 4;

@implementation GameViewController {
    MTKView             *_mtkView;
    BrawlerGameDelegate *_delegate;
    GCController        *_assignedControllers[kMaxPlayers];
    UILabel             *_overlayLabel;
    UILabel             *_subtitleLabel;  // "Connect a gamepad" or pause hint
    UIView              *_damageFlashView;
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

    // Primary overlay — title / phase messages, centered.
    _overlayLabel = [[UILabel alloc] initWithFrame:self.view.bounds];
    _overlayLabel.numberOfLines       = 0;
    _overlayLabel.textAlignment       = NSTextAlignmentCenter;
    _overlayLabel.textColor           = [UIColor whiteColor];
    _overlayLabel.font                = [UIFont boldSystemFontOfSize:72];
    _overlayLabel.backgroundColor     = [UIColor colorWithWhite:0 alpha:0.72];
    _overlayLabel.hidden              = YES;
    _overlayLabel.autoresizingMask    = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:_overlayLabel];

    // Subtitle label — controller prompt / pause hint, bottom-center.
    CGRect bounds = self.view.bounds;
    _subtitleLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, bounds.size.height - 120,
                                                               bounds.size.width, 80)];
    _subtitleLabel.numberOfLines   = 1;
    _subtitleLabel.textAlignment   = NSTextAlignmentCenter;
    _subtitleLabel.textColor       = [UIColor colorWithWhite:1 alpha:0.75];
    _subtitleLabel.font            = [UIFont systemFontOfSize:36];
    _subtitleLabel.backgroundColor = [UIColor clearColor];
    _subtitleLabel.hidden          = YES;
    _subtitleLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
    [self.view addSubview:_subtitleLabel];

    // Red edge flash when the player takes a hit.
    _damageFlashView = [[UIView alloc] initWithFrame:self.view.bounds];
    _damageFlashView.backgroundColor = [UIColor colorWithRed:1 green:0 blue:0 alpha:0.42];
    _damageFlashView.userInteractionEnabled = NO;
    _damageFlashView.alpha = 0;
    _damageFlashView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:_damageFlashView];

    __weak GameViewController *weakSelf = self;

    _delegate.onPlayerDamaged = ^{
        GameViewController *vc = weakSelf;
        if (!vc) return;
        vc->_damageFlashView.alpha = 1.f;
        [UIView animateWithDuration:0.35 delay:0
                            options:UIViewAnimationOptionCurveEaseOut
                         animations:^{ vc->_damageFlashView.alpha = 0; }
                         completion:nil];
    };

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

    // Show title screen immediately.
    [self _updateOverlayForPhase:BrawlerGamePhaseTitle room:1 lives:3];
}

- (void)pauseRendering  { [_delegate resetInput]; _mtkView.paused = YES; }
- (void)resumeRendering { _mtkView.paused = NO; }

- (void)releaseGPUResources {
    _mtkView.paused = YES;
    _mtkView.delegate = nil;
    _delegate = nil;
}

// Returns YES if at least one extended gamepad is connected.
- (BOOL)_hasGamepad {
    for (GCController *ctrl in [GCController controllers])
        if (ctrl.extendedGamepad) return YES;
    return NO;
}

- (void)_updateOverlayForPhase:(BrawlerGamePhase)phase room:(int)room lives:(int)lives {
    switch (phase) {
        case BrawlerGamePhaseTitle:
            _overlayLabel.text   = kBrawlerStringTitle;
            _overlayLabel.hidden = NO;
            _subtitleLabel.text  = [self _hasGamepad]
                                   ? @"Press A to start"
                                   : kBrawlerStringNoController;
            _subtitleLabel.hidden = NO;
            break;
        case BrawlerGamePhasePlayerSelect:
            _overlayLabel.text    = @"SELECT PLAYERS\n[A]  1 Player\n[B]  2 Players";
            _overlayLabel.hidden  = NO;
            _subtitleLabel.hidden = YES;
            break;
        case BrawlerGamePhasePlaying:
            _overlayLabel.hidden  = YES;
            _subtitleLabel.hidden = YES;
            break;
        case BrawlerGamePhaseRoomClear:
            _overlayLabel.text   = [NSString stringWithFormat:kBrawlerStringRoomClearFmt, room];
            _overlayLabel.hidden = NO;
            _subtitleLabel.hidden = YES;
            break;
        case BrawlerGamePhaseWin:
            _overlayLabel.text   = kBrawlerStringWin;
            _overlayLabel.hidden = NO;
            _subtitleLabel.hidden = YES;
            break;
        case BrawlerGamePhaseLose:
            _overlayLabel.text   = kBrawlerStringGameOver;
            _overlayLabel.hidden = NO;
            _subtitleLabel.hidden = YES;
            break;
        case BrawlerGamePhasePaused:
            _overlayLabel.text   = kBrawlerStringPaused;
            _overlayLabel.hidden = NO;
            _subtitleLabel.text  = kBrawlerStringPausedResume;
            _subtitleLabel.hidden = NO;
            break;
    }
}

// ---------------------------------------------------------------------------
// Controller management
// ---------------------------------------------------------------------------

- (void)_controllerConnected:(NSNotification *)note {
    GCController *ctrl = note.object;
    if (!ctrl) return;

    // Refresh title subtitle now that a gamepad may be available.
    BrawlerGamePhase ph = _delegate.gamePhase;
    if (ph == BrawlerGamePhaseTitle || ph == BrawlerGamePhasePlayerSelect)
        [self _updateOverlayForPhase:ph room:1 lives:3];

    int slot = -1;
    for (int i = 0; i < kMaxPlayers; ++i) {
        if (!_assignedControllers[i]) { slot = i; break; }
    }
    if (slot < 0) return;

    _assignedControllers[slot] = ctrl;
    [self _wireController:ctrl toSlot:slot];
}

- (void)_controllerDisconnected:(NSNotification *)note {
    GCController *ctrl = note.object;
    for (int i = 0; i < kMaxPlayers; ++i) {
        if (_assignedControllers[i] == ctrl) {
            _assignedControllers[i] = nil;
            [_delegate setInputState:{} forPlayer:i];
            break;
        }
    }
    // If we're on the title screen and lost the last gamepad, update the message.
    if (_delegate.gamePhase == BrawlerGamePhaseTitle)
        [self _updateOverlayForPhase:BrawlerGamePhaseTitle room:1 lives:3];
}

- (void)_wireController:(GCController *)ctrl toSlot:(int)slot {
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
        ext.buttonB.valueChangedHandler = ^(GCControllerButtonInput *btn, float val, BOOL pressed) {
            GameViewController *vc = weakSelf;
            if (!vc) return;
            InputState s = [vc->_delegate currentInputStateForPlayer:slot];
            s.dodge = pressed;
            [vc->_delegate setInputState:s forPlayer:slot];
        };
        // Options button (☰) = pause/resume. Safe to intercept; no system behavior on tvOS.
        ext.buttonOptions.pressedChangedHandler = ^(GCControllerButtonInput *btn, float val, BOOL pressed) {
            if (!pressed) return; // fire on press only
            GameViewController *vc = weakSelf;
            if (!vc) return;
            [vc->_delegate triggerPause];
        };
        return;
    }
    // Siri Remote (micro-gamepad only, no extended profile) — not supported.
    // Too few buttons to play comfortably; require a proper gamepad.
}

@end
