#import "GameViewController.h"
#import <MetalKit/MetalKit.h>
#include "Simulation/World.h"
#include "Platform/InputState.h"

@interface BrawlerDelegate : NSObject <MTKViewDelegate>
- (instancetype)initWithDevice:(id<MTLDevice>)device;
- (void)setInputState:(InputState)state;
@end

@implementation BrawlerDelegate {
    World          _world;
    CFTimeInterval _lastTime;
    id<MTLCommandQueue> _commandQueue;
}

- (instancetype)initWithDevice:(id<MTLDevice>)device {
    self = [super init];
    if (self) {
        _commandQueue = [device newCommandQueue];
        _lastTime = CACurrentMediaTime();

        // Spawn the player entity at the world origin.
        EntityID player = _world.defer_create();
        _world.add_component<PlayerTagComponent>(player).active = true;
        _world.add_component<PositionComponent>(player)        = {0, 0, 0};
        _world.add_component<VelocityComponent>(player)        = {0, 0, 0};
        _world.add_component<FactionComponent>(player).type    = FactionComponent::Player;
        _world.add_component<HealthComponent>(player)          = {10, 10};

        // Spawn one enemy offset from the player.
        EntityID enemy = _world.defer_create();
        _world.add_component<PositionComponent>(enemy)      = {400, 0, 0};
        _world.add_component<VelocityComponent>(enemy)      = {0, 0, 0};
        _world.add_component<FactionComponent>(enemy).type  = FactionComponent::Enemy;
        _world.add_component<HealthComponent>(enemy)        = {3, 3};
    }
    return self;
}

- (void)setInputState:(InputState)state {
    _world.set_input(state);
}

- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {}

- (void)drawInMTKView:(MTKView *)view {
    CFTimeInterval now = CACurrentMediaTime();
    float physicalDt = (float)(now - _lastTime);
    _lastTime = now;
    if (physicalDt > 0.1f) physicalDt = 0.1f;

    _world.update(physicalDt, physicalDt);

    id<MTLCommandBuffer> cmd = [_commandQueue commandBuffer];
    MTLRenderPassDescriptor *rpd = view.currentRenderPassDescriptor;
    if (rpd) {
        rpd.colorAttachments[0].clearColor = MTLClearColorMake(0.05, 0.05, 0.10, 1.0);
        rpd.colorAttachments[0].loadAction  = MTLLoadActionClear;
        rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLRenderCommandEncoder> enc = [cmd renderCommandEncoderWithDescriptor:rpd];
        // TODO: RenderSystem draws here
        [enc endEncoding];
    }
    [cmd presentDrawable:view.currentDrawable];
    [cmd commit];
}

@end

// ---- GameViewController ----

@implementation GameViewController {
    MTKView         *_mtkView;
    BrawlerDelegate *_delegate;

    // Key state — updated by keyDown/keyUp, consumed each frame.
    BOOL _left, _right, _up, _down;
    BOOL _attack, _dodge;
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
    _delegate = [[BrawlerDelegate alloc] initWithDevice:_mtkView.device];
    _mtkView.delegate = _delegate;

    // Schedule input → world feed once per display refresh.
    NSTimer *inputTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 / 120.0
                                                           target:self
                                                         selector:@selector(_feedInput)
                                                         userInfo:nil
                                                          repeats:YES];
    (void)inputTimer;
}

- (void)viewDidAppear {
    [super viewDidAppear];
    [self.view.window makeFirstResponder:self];
}

- (BOOL)acceptsFirstResponder { return YES; }

- (void)_feedInput {
    float mx = (_right ? 1.f : 0.f) - (_left  ? 1.f : 0.f);
    float my = (_down  ? 1.f : 0.f) - (_up    ? 1.f : 0.f);
    InputState state = { mx, my, (bool)_attack, (bool)_dodge, false };
    [_delegate setInputState:state];
    _attack = NO; // consume single-frame button presses
    _dodge  = NO;
}

- (void)keyDown:(NSEvent *)event {
    if (event.isARepeat) return;
    switch (event.keyCode) {
        case 0:  _left   = YES; break; // A
        case 2:  _right  = YES; break; // D
        case 13: _up     = YES; break; // W
        case 1:  _down   = YES; break; // S
        case 123: _left  = YES; break; // left arrow
        case 124: _right = YES; break; // right arrow
        case 125: _down  = YES; break; // down arrow
        case 126: _up    = YES; break; // up arrow
        case 49: _attack = YES; break; // space
        case 56: _dodge  = YES; break; // shift
        default: [super keyDown:event];
    }
}

- (void)keyUp:(NSEvent *)event {
    switch (event.keyCode) {
        case 0:  _left   = NO; break;
        case 2:  _right  = NO; break;
        case 13: _up     = NO; break;
        case 1:  _down   = NO; break;
        case 123: _left  = NO; break;
        case 124: _right = NO; break;
        case 125: _down  = NO; break;
        case 126: _up    = NO; break;
        default: [super keyUp:event];
    }
}

@end
