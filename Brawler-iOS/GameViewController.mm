#import "GameViewController.h"
#import <MetalKit/MetalKit.h>
#import <GameController/GameController.h>
#import "BrawlerGameDelegate.h"
#import "BrawlerStrings.h"
#include "Platform/InputState.h"
#include <math.h>

@implementation GameViewController {
    MTKView             *_mtkView;
    BrawlerGameDelegate *_delegate;
    UITouch             *_moveTouchRef;
    CGPoint              _moveOrigin;
    CGPoint              _moveTouchStartPos;
    NSTimeInterval       _moveTouchStartTime;
    UIButton            *_pauseButton;
    UIView              *_damageFlashView;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    _mtkView = [[MTKView alloc] initWithFrame:self.view.bounds device:device];
    _mtkView.autoresizingMask        = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _mtkView.colorPixelFormat        = MTLPixelFormatBGRA8Unorm;
    _mtkView.depthStencilPixelFormat = MTLPixelFormatDepth32Float;
    _mtkView.multipleTouchEnabled    = YES;
    [self.view addSubview:_mtkView];

    _delegate = [[BrawlerGameDelegate alloc] initWithDevice:device
                                                pixelFormat:_mtkView.colorPixelFormat];
    [_delegate mtkView:_mtkView drawableSizeWillChange:_mtkView.bounds.size];
    _mtkView.delegate = _delegate;

    // Pause button — top-right corner, hidden until game starts.
    _pauseButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [_pauseButton setTitle:@"⏸" forState:UIControlStateNormal];
    _pauseButton.titleLabel.font = [UIFont systemFontOfSize:28];
    _pauseButton.frame = CGRectMake(self.view.bounds.size.width - 60, 20, 44, 44);
    _pauseButton.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    _pauseButton.hidden = YES;
    [_pauseButton addTarget:self action:@selector(_pauseTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_pauseButton];

    // Red edge flash when the player takes a hit.
    _damageFlashView = [[UIView alloc] initWithFrame:self.view.bounds];
    _damageFlashView.userInteractionEnabled = NO;
    _damageFlashView.alpha = 0;
    _damageFlashView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    CAGradientLayer *iosFlashGrad = [CAGradientLayer layer];
    iosFlashGrad.frame = _damageFlashView.bounds;
    iosFlashGrad.startPoint = CGPointMake(0, 0.5);
    iosFlashGrad.endPoint   = CGPointMake(1, 0.5);
    UIColor *iosRed   = [UIColor colorWithRed:0.90 green:0.05 blue:0.05 alpha:0.80];
    UIColor *iosClear = [UIColor colorWithRed:0.90 green:0.05 blue:0.05 alpha:0.0];
    iosFlashGrad.colors    = @[(id)iosRed.CGColor, (id)iosClear.CGColor,
                               (id)iosClear.CGColor, (id)iosRed.CGColor];
    iosFlashGrad.locations = @[@0, @0.22, @0.78, @1.0];
    // CALayer autoresizing masks are macOS-only; sync the sublayer frame when
    // the flash fires instead (rotation mid-flash is a non-issue).
    [_damageFlashView.layer addSublayer:iosFlashGrad];
    [self.view addSubview:_damageFlashView];

    __weak GameViewController *weakSelf = self;

    _delegate.onPlayerDamaged = ^{
        GameViewController *vc = weakSelf;
        if (!vc) return;
        vc->_damageFlashView.layer.sublayers.firstObject.frame = vc->_damageFlashView.bounds;
        vc->_damageFlashView.alpha = 1.f;
        [UIView animateWithDuration:0.35 delay:0
                            options:UIViewAnimationOptionCurveEaseOut
                         animations:^{ vc->_damageFlashView.alpha = 0; }
                         completion:nil];
    };

    _delegate.onPhaseChanged = ^(BrawlerGamePhase phase, int room, int lives) {
        GameViewController *vc = weakSelf;
        if (!vc) return;
        vc->_pauseButton.hidden = (phase != BrawlerGamePhasePlaying &&
                                   phase != BrawlerGamePhasePaused);
    };

    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(_controllerConnected:)
               name:GCControllerDidConnectNotification
             object:nil];
    [GCController startWirelessControllerDiscoveryWithCompletionHandler:nil];

    // Controllers already connected at launch don't re-post the connect
    // notification — wire them up explicitly.
    for (GCController *ctrl in [GCController controllers])
        [self _attachController:ctrl];
}

- (void)_pauseTapped      { [_delegate triggerPause]; }

- (void)pauseRendering  { [_delegate resetInput]; _mtkView.paused = YES; }
- (void)resumeRendering { _mtkView.paused = NO; }

// First finger = virtual joystick. Any subsequent finger = attack tap.
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    for (UITouch *t in touches) {
        CGPoint loc = [t locationInView:_mtkView];
        if (_delegate.gamePhase == BrawlerGamePhaseTitle) {
            if (loc.x > _mtkView.bounds.size.width * 0.5)
                [_delegate enterMetaShop];
            else
                [_delegate triggerAttack];
            return;
        }
        if (_delegate.gamePhase == BrawlerGamePhaseMetaShop) {
            if (loc.x > _mtkView.bounds.size.width * 0.72) {
                [_delegate exitMetaShop];
            } else if (loc.x < _mtkView.bounds.size.width * 0.28) {
                [_delegate buySelectedMetaUpgrade];
            } else {
                [_delegate metaShopMove:(loc.y < _mtkView.bounds.size.height * 0.5 ? -1 : 1)];
            }
            return;
        }
        if (_delegate.gamePhase == BrawlerGamePhasePlayerSelect) {
            [_delegate startGameWithPlayers:(loc.x < _mtkView.bounds.size.width * 0.5 ? 1 : 2)];
            return;
        }
        if (_delegate.gamePhase == BrawlerGamePhaseUpgrade) {
            [_delegate chooseUpgrade:(loc.x < _mtkView.bounds.size.width * 0.5 ? 0 : 1)];
            return;
        }
        if (!_moveTouchRef) {
            _moveTouchRef        = t;
            _moveOrigin          = loc;
            _moveTouchStartPos   = _moveOrigin;
            _moveTouchStartTime  = event.timestamp;
        } else {
            [_delegate triggerAttack];
        }
    }
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (!_moveTouchRef) return;
    CGPoint cur = [_moveTouchRef locationInView:_mtkView];
    float dx = (float)(cur.x - _moveOrigin.x);
    float dy = (float)(cur.y - _moveOrigin.y);

    static const float kJoyRadius = 80.f;
    float len = sqrtf(dx*dx + dy*dy);
    float mx = 0, my = 0;
    if (len > 4.f) {
        float scale = fminf(len, kJoyRadius) / kJoyRadius;
        mx =  (dx / len) * scale;
        my = -(dy / len) * scale; // screen Y is inverted vs game Y
    }
        [_delegate setInputState:{mx, my, false, false, false}];
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    for (UITouch *t in touches) {
        if (t == _moveTouchRef) {
            // Flick gesture: quick lift after a short fast swipe = dodge.
            CGPoint endPos = [t locationInView:_mtkView];
            float dx = endPos.x - _moveTouchStartPos.x;
            float dy = endPos.y - _moveTouchStartPos.y;
            float dist = sqrtf(dx * dx + dy * dy);
            NSTimeInterval duration = event.timestamp - _moveTouchStartTime;
            if (duration < 0.20 && dist > 40.f) {
                [_delegate triggerDodge];
            }
            _moveTouchRef = nil;
            [_delegate setInputState:{0, 0, false, false, false}];
        }
    }
}

- (void)_controllerConnected:(NSNotification *)note {
    [self _attachController:note.object];
}

- (void)_attachController:(GCController *)ctrl {
    if (!ctrl.extendedGamepad) return;
    __weak GameViewController *weakSelf = self;
    GCExtendedGamepad *ext = ctrl.extendedGamepad;
    ext.buttonX.valueChangedHandler = ^(GCControllerButtonInput *btn, float val, BOOL pressed) {
        GameViewController *vc = weakSelf;
        if (!vc) return;
        InputState s = [vc->_delegate currentInputStateForPlayer:0];
        s.special = pressed;
        [vc->_delegate setInputState:s forPlayer:0];
    };
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self touchesEnded:touches withEvent:event];
}

@end
