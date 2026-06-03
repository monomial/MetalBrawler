#import "GameViewController.h"
#import <MetalKit/MetalKit.h>
#import "BrawlerGameDelegate.h"
#include "Platform/InputState.h"
#include <math.h>

@implementation GameViewController {
    MTKView             *_mtkView;
    BrawlerGameDelegate *_delegate;
    UITouch             *_moveTouchRef;
    CGPoint              _moveOrigin;
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
}

- (void)pauseRendering  { [_delegate resetInput]; _mtkView.paused = YES; }
- (void)resumeRendering { _mtkView.paused = NO; }

// First finger = virtual joystick. Any subsequent finger = attack tap.
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    for (UITouch *t in touches) {
        if (!_moveTouchRef) {
            _moveTouchRef = t;
            _moveOrigin   = [t locationInView:_mtkView];
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
            _moveTouchRef = nil;
            [_delegate setInputState:{0, 0, false, false, false}];
        }
    }
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self touchesEnded:touches withEvent:event];
}

@end
