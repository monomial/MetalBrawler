#import "GameViewController.h"
#import <MetalKit/MetalKit.h>
#import "BrawlerGameDelegate.h"
#include "Platform/InputState.h"

@implementation GameViewController {
    MTKView             *_mtkView;
    BrawlerGameDelegate *_delegate;
    BOOL _left, _right, _up, _down, _attack, _dodge;
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

    [NSTimer scheduledTimerWithTimeInterval:1.0/120.0 target:self
                                   selector:@selector(_feedInput) userInfo:nil repeats:YES];
}

- (void)viewDidAppear {
    [super viewDidAppear];
    [self.view.window makeFirstResponder:self];
}

- (BOOL)acceptsFirstResponder { return YES; }

- (void)_feedInput {
    float mx = (_right ? 1.f : 0.f) - (_left ? 1.f : 0.f);
    float my = (_up    ? 1.f : 0.f) - (_down ? 1.f : 0.f);
    InputState s = { mx, my, (bool)_attack, (bool)_dodge, false };
    [_delegate setInputState:s];
    _attack = NO;
    _dodge  = NO;
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
        case 49:  _attack = YES; break; // Space
        case 56:  _dodge  = YES; break; // Shift
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

@end
