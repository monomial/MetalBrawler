#import "GameViewController.h"
#import <MetalKit/MetalKit.h>
#import <GameController/GameController.h>
#import "BrawlerGameDelegate.h"
#import "BrawlerStrings.h"
#include "Platform/InputState.h"

@implementation GameViewController {
    MTKView             *_mtkView;
    BrawlerGameDelegate *_delegate;
    NSTextField         *_overlayField;
    BOOL _left, _right, _up, _down, _attack;
}

- (void)loadView {
    _mtkView = [[MTKView alloc] initWithFrame:NSMakeRect(0, 0, 960, 720)
                                       device:MTLCreateSystemDefaultDevice()];
    _mtkView.colorPixelFormat        = MTLPixelFormatBGRA8Unorm;
    _mtkView.depthStencilPixelFormat = MTLPixelFormatDepth32Float;
    self.view = _mtkView;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    _delegate = [[BrawlerGameDelegate alloc] initWithDevice:_mtkView.device
                                                pixelFormat:_mtkView.colorPixelFormat];
    [_delegate mtkView:_mtkView drawableSizeWillChange:_mtkView.drawableSize];
    _mtkView.delegate = _delegate;

    // Phase overlay — centered NSTextField with transparent background.
    _overlayField = [[NSTextField alloc] initWithFrame:NSMakeRect(180, 260, 600, 200)];
    _overlayField.editable          = NO;
    _overlayField.selectable        = NO;
    _overlayField.bordered          = NO;
    _overlayField.bezeled           = NO;
    _overlayField.drawsBackground   = YES;
    _overlayField.backgroundColor   = [NSColor colorWithWhite:0 alpha:0.72];
    _overlayField.textColor         = [NSColor whiteColor];
    _overlayField.alignment         = NSTextAlignmentCenter;
    _overlayField.font              = [NSFont boldSystemFontOfSize:48];
    _overlayField.maximumNumberOfLines = 3;
    _overlayField.hidden            = YES;
    [self.view addSubview:_overlayField];

    __weak GameViewController *weakSelf = self;
    _delegate.onPhaseChanged = ^(BrawlerGamePhase phase, int room, int lives) {
        GameViewController *vc = weakSelf;
        if (!vc) return;
        switch (phase) {
            case BrawlerGamePhaseTitle:
                vc->_overlayField.stringValue = [NSString stringWithFormat:@"%@\n%@",
                    kBrawlerStringTitle, kBrawlerStringPressToStart];
                vc->_overlayField.hidden = NO; break;
            case BrawlerGamePhasePlaying:
                vc->_overlayField.hidden = YES; break;
            case BrawlerGamePhaseRoomClear:
                vc->_overlayField.stringValue = [NSString stringWithFormat:kBrawlerStringRoomClearFmt, room];
                vc->_overlayField.hidden = NO; break;
            case BrawlerGamePhaseWin:
                vc->_overlayField.stringValue = kBrawlerStringWin;
                vc->_overlayField.hidden = NO; break;
            case BrawlerGamePhaseLose:
                vc->_overlayField.stringValue = kBrawlerStringGameOver;
                vc->_overlayField.hidden = NO; break;
            case BrawlerGamePhasePaused:
                vc->_overlayField.stringValue = [NSString stringWithFormat:@"%@\n%@",
                    kBrawlerStringPaused, kBrawlerStringPausedResume];
                vc->_overlayField.hidden = NO; break;
        }
    };

    // Show title screen immediately (delegate starts in Title phase).
    _delegate.onPhaseChanged(BrawlerGamePhaseTitle, 1, 3);

    // P1: keyboard — use a local event monitor so key events are captured regardless
    // of which view is first responder (avoids NSTextField stealing focus).
    __weak GameViewController *weakSelfKbd = self;
    [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^NSEvent*(NSEvent *event) {
        GameViewController *vc = weakSelfKbd;
        if (!vc || event.isARepeat) return event;
        [vc keyDown:event];
        return nil; // consume — prevents system beep for unhandled keys
    }];
    [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyUp handler:^NSEvent*(NSEvent *event) {
        GameViewController *vc = weakSelfKbd;
        if (!vc) return event;
        [vc keyUp:event];
        return nil;
    }];
    [NSTimer scheduledTimerWithTimeInterval:1.0/120.0 target:self
                                   selector:@selector(_feedKeyboardInput) userInfo:nil repeats:YES];

    // P2: first connected GCController
    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(_controllerConnected:)
               name:GCControllerDidConnectNotification
             object:nil];
    [GCController startWirelessControllerDiscoveryWithCompletionHandler:nil];
}

// ---------------------------------------------------------------------------
// P1 — keyboard
// ---------------------------------------------------------------------------

- (void)_feedKeyboardInput {
    float mx = (_right ? 1.f : 0.f) - (_left ? 1.f : 0.f);
    float my = (_up    ? 1.f : 0.f) - (_down ? 1.f : 0.f);
    InputState s = { mx, my, (bool)_attack, false, false };
    [_delegate setInputState:s forPlayer:0];
    _attack = NO;
}

- (void)keyDown:(NSEvent *)event {
    if (event.isARepeat) return;
    switch (event.keyCode) {
        case 0:   _left   = YES; break; // A
        case 2:   _right  = YES; break; // D
        case 13:  _up     = YES; break; // W
        case 1:   _down   = YES; break; // S
        case 123: _left   = YES; break; // ←
        case 124: _right  = YES; break; // →
        case 126: _up     = YES; break; // ↑
        case 125: _down   = YES; break; // ↓
        case 49:  _attack = YES; break;             // Space  — attack
        case 12:  [_delegate triggerDodge]; break; // Q      — dodge
        case 53:  [_delegate triggerPause];  break; // Escape — pause
        default: [super keyDown:event];
    }
}

- (void)keyUp:(NSEvent *)event {
    switch (event.keyCode) {
        case 0:   _left  = NO; break;
        case 2:   _right = NO; break;
        case 13:  _up    = NO; break;
        case 1:   _down  = NO; break;
        case 123: _left  = NO; break;
        case 124: _right = NO; break;
        case 126: _up    = NO; break;
        case 125: _down  = NO; break;
        default: [super keyUp:event];
    }
}

// ---------------------------------------------------------------------------
// P2 — first connected GCController (extended gamepad only)
// ---------------------------------------------------------------------------

- (void)_controllerConnected:(NSNotification *)note {
    GCController *ctrl = note.object;
    if (!ctrl) return;
    GCExtendedGamepad *ext = ctrl.extendedGamepad;
    if (!ext) return;

    __weak GameViewController *weakSelf = self;
    ext.leftThumbstick.valueChangedHandler = ^(GCControllerDirectionPad *pad, float x, float y) {
        GameViewController *vc = weakSelf;
        if (!vc) return;
        InputState s = [vc->_delegate currentInputStateForPlayer:1];
        s.moveX = x; s.moveY = y;
        [vc->_delegate setInputState:s forPlayer:1];
    };
    ext.buttonA.valueChangedHandler = ^(GCControllerButtonInput *btn, float val, BOOL pressed) {
        GameViewController *vc = weakSelf;
        if (!vc) return;
        InputState s = [vc->_delegate currentInputStateForPlayer:1];
        s.attack = pressed;
        [vc->_delegate setInputState:s forPlayer:1];
    };
}

@end
