#import "GameViewController.h"
#import <MetalKit/MetalKit.h>
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
    UILabel             *_overlayLabel;
    UIButton            *_pauseButton;
    UIButton            *_onePlayerButton;
    UIButton            *_twoPlayersButton;
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

    _overlayLabel = [[UILabel alloc] initWithFrame:self.view.bounds];
    _overlayLabel.numberOfLines    = 0;
    _overlayLabel.textAlignment    = NSTextAlignmentCenter;
    _overlayLabel.textColor        = [UIColor whiteColor];
    _overlayLabel.font             = [UIFont boldSystemFontOfSize:48];
    _overlayLabel.backgroundColor  = [UIColor colorWithWhite:0 alpha:0.72];
    _overlayLabel.hidden           = YES;
    _overlayLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:_overlayLabel];

    // Pause button — top-right corner, hidden until game starts.
    _pauseButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [_pauseButton setTitle:@"⏸" forState:UIControlStateNormal];
    _pauseButton.titleLabel.font = [UIFont systemFontOfSize:28];
    _pauseButton.frame = CGRectMake(self.view.bounds.size.width - 60, 20, 44, 44);
    _pauseButton.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    _pauseButton.hidden = YES;
    [_pauseButton addTarget:self action:@selector(_pauseTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_pauseButton];

    // Player-select buttons — shown only during player-select phase.
    CGFloat bw = self.view.bounds.size.width * 0.38f;
    CGFloat bh = 80.f;
    CGFloat cy = self.view.bounds.size.height * 0.55f;
    CGFloat cx = self.view.bounds.size.width  * 0.5f;

    _onePlayerButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [_onePlayerButton setTitle:@"1 PLAYER" forState:UIControlStateNormal];
    _onePlayerButton.titleLabel.font = [UIFont boldSystemFontOfSize:28];
    _onePlayerButton.backgroundColor = [UIColor colorWithWhite:0.15 alpha:0.9];
    [_onePlayerButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    _onePlayerButton.layer.cornerRadius = 12;
    _onePlayerButton.frame = CGRectMake(cx - bw - 12, cy, bw, bh);
    _onePlayerButton.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleTopMargin;
    _onePlayerButton.hidden = YES;
    [_onePlayerButton addTarget:self action:@selector(_onePlayerTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_onePlayerButton];

    _twoPlayersButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [_twoPlayersButton setTitle:@"2 PLAYERS" forState:UIControlStateNormal];
    _twoPlayersButton.titleLabel.font = [UIFont boldSystemFontOfSize:28];
    _twoPlayersButton.backgroundColor = [UIColor colorWithWhite:0.15 alpha:0.9];
    [_twoPlayersButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    _twoPlayersButton.layer.cornerRadius = 12;
    _twoPlayersButton.frame = CGRectMake(cx + 12, cy, bw, bh);
    _twoPlayersButton.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleTopMargin;
    _twoPlayersButton.hidden = YES;
    [_twoPlayersButton addTarget:self action:@selector(_twoPlayersTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_twoPlayersButton];

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
    iosFlashGrad.autoresizingMask = kCALayerWidthSizable | kCALayerHeightSizable;
    [_damageFlashView.layer addSublayer:iosFlashGrad];
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
        switch (phase) {
            case BrawlerGamePhaseTitle:
                vc->_overlayLabel.text      = [NSString stringWithFormat:@"%@\nTap to start",
                    kBrawlerStringTitle];
                vc->_overlayLabel.hidden    = NO;
                vc->_pauseButton.hidden     = YES;
                vc->_onePlayerButton.hidden = YES;
                vc->_twoPlayersButton.hidden = YES; break;
            case BrawlerGamePhasePlayerSelect:
                vc->_overlayLabel.text      = kBrawlerStringSelectPlayers;
                vc->_overlayLabel.hidden    = NO;
                vc->_pauseButton.hidden     = YES;
                vc->_onePlayerButton.hidden  = NO;
                vc->_twoPlayersButton.hidden = NO; break;
            case BrawlerGamePhasePlaying:
                vc->_overlayLabel.hidden     = YES;
                vc->_pauseButton.hidden      = NO;
                vc->_onePlayerButton.hidden  = YES;
                vc->_twoPlayersButton.hidden = YES; break;
            case BrawlerGamePhaseRoomClear:
                vc->_overlayLabel.text   = [NSString stringWithFormat:kBrawlerStringRoomClearFmt, room];
                vc->_overlayLabel.hidden = NO; break;
            case BrawlerGamePhaseWin:
                vc->_overlayLabel.text      = kBrawlerStringWin;
                vc->_overlayLabel.hidden    = NO;
                vc->_pauseButton.hidden     = YES;
                vc->_onePlayerButton.hidden = YES;
                vc->_twoPlayersButton.hidden = YES; break;
            case BrawlerGamePhaseLose:
                vc->_overlayLabel.text      = kBrawlerStringGameOver;
                vc->_overlayLabel.hidden    = NO;
                vc->_pauseButton.hidden     = YES;
                vc->_onePlayerButton.hidden = YES;
                vc->_twoPlayersButton.hidden = YES; break;
            case BrawlerGamePhasePaused:
                vc->_overlayLabel.text   = [NSString stringWithFormat:@"%@\n%@",
                    kBrawlerStringPaused, kBrawlerStringPausedResume];
                vc->_overlayLabel.hidden = NO;
                vc->_pauseButton.hidden  = NO; break;
        }
    };

    // Show title screen immediately.
    _delegate.onPhaseChanged(BrawlerGamePhaseTitle, 1, 3);
}

- (void)_pauseTapped      { [_delegate triggerPause]; }
- (void)_onePlayerTapped  { [_delegate startGameWithPlayers:1]; }
- (void)_twoPlayersTapped { [_delegate startGameWithPlayers:2]; }

- (void)pauseRendering  { [_delegate resetInput]; _mtkView.paused = YES; }
- (void)resumeRendering { _mtkView.paused = NO; }

// First finger = virtual joystick. Any subsequent finger = attack tap.
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    for (UITouch *t in touches) {
        if (!_moveTouchRef) {
            _moveTouchRef        = t;
            _moveOrigin          = [t locationInView:_mtkView];
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

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self touchesEnded:touches withEvent:event];
}

@end
