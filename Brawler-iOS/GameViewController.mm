#import "GameViewController.h"
#import <MetalKit/MetalKit.h>
#include "Simulation/World.h"
#include "Simulation/Systems/ScreenShakeSystem.h"
#include "Platform/InputState.h"
#import "Renderer/BrawlerRenderer.h"
#import "Haptics/HapticsEngine.h"
#import "Audio/AudioEngine.h"

// ---------------------------------------------------------------------------
// BrawlerDelegate_iOS — owns World, drives update + render
// ---------------------------------------------------------------------------
@interface BrawlerDelegate_iOS : NSObject <MTKViewDelegate>
- (instancetype)initWithDevice:(id<MTLDevice>)device
                   pixelFormat:(MTLPixelFormat)pfmt
                hapticsEngine:(HapticsEngine*)haptics;
- (void)setInputState:(InputState)state;
- (void)triggerAttack;
@end

@implementation BrawlerDelegate_iOS {
    World              _world;
    CFTimeInterval     _lastTime;
    id<MTLCommandQueue> _commandQueue;
    BrawlerRenderer    *_renderer;
    HapticsEngine      *_haptics;
    AudioEngine        *_audio;
    dispatch_semaphore_t _frameSemaphore;
}

- (instancetype)initWithDevice:(id<MTLDevice>)device
                   pixelFormat:(MTLPixelFormat)pfmt
                hapticsEngine:(HapticsEngine*)haptics {
    self = [super init];
    if (!self) return nil;

    _commandQueue   = [device newCommandQueue];
    _lastTime       = CACurrentMediaTime();
    _frameSemaphore = dispatch_semaphore_create(3);
    _haptics        = haptics;
    _audio          = [[AudioEngine alloc] init];
    [_audio startupInit];
    _renderer       = [[BrawlerRenderer alloc] initWithDevice:device pixelFormat:pfmt];

    // Spawn entities
    EntityID player = _world.defer_create();
    _world.add_component<PlayerTagComponent>(player).active = true;
    _world.add_component<PositionComponent>(player)         = {0, -100, 0};
    _world.add_component<VelocityComponent>(player)         = {0, 0, 0};
    _world.add_component<FactionComponent>(player).type     = FactionComponent::Player;
    _world.add_component<HealthComponent>(player)           = {10, 10};

    EntityID enemy = _world.defer_create();
    _world.add_component<PositionComponent>(enemy)          = {200, 300, 0};
    _world.add_component<VelocityComponent>(enemy)          = {0, 0, 0};
    _world.add_component<FactionComponent>(enemy).type      = FactionComponent::Enemy;
    _world.add_component<HealthComponent>(enemy)            = {3, 3};

    return self;
}

- (void)setInputState:(InputState)state { _world.set_input(state); }

- (void)triggerAttack {
    InputState s = _world.current_input();
    s.attack = true;
    _world.set_input(s);
}

- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {
    [_renderer updateDrawableSize:size];
}

- (void)drawInMTKView:(MTKView *)view {
    dispatch_semaphore_wait(_frameSemaphore, DISPATCH_TIME_FOREVER);

    CFTimeInterval now = CACurrentMediaTime();
    float physicalDt = (float)(now - _lastTime);
    _lastTime = now;
    if (physicalDt > 0.1f) physicalDt = 0.1f;

    _world.update(physicalDt, physicalDt);

    // Sound + haptics on hit.
    _world.events().for_each(EventType::HitContact, [self](const Event&) {
        [_audio  playHitSound];
        [_haptics playHitHaptic];
    });

    // Clear attack — single-frame pulse.
    InputState s = _world.current_input();
    s.attack = false;
    _world.set_input(s);

    id<MTLCommandBuffer> cmd = [_commandQueue commandBuffer];
    __block dispatch_semaphore_t sem = _frameSemaphore;
    [cmd addCompletedHandler:^(id<MTLCommandBuffer> _) {
        dispatch_semaphore_signal(sem);
    }];

    [_renderer drawWorld:&_world inView:view commandBuffer:cmd];
    [cmd commit];
}

@end

// ---------------------------------------------------------------------------
// GameViewController — manages MTKView + touch input
// ---------------------------------------------------------------------------
@implementation GameViewController {
    MTKView             *_mtkView;
    BrawlerDelegate_iOS *_delegate;
    HapticsEngine       *_haptics;

    // Virtual joystick state
    UITouch  *_moveTouchRef;
    CGPoint   _moveOrigin;
    BOOL      _moving;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    _haptics = [[HapticsEngine alloc] init];
    [_haptics startupInit];

    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    _mtkView = [[MTKView alloc] initWithFrame:self.view.bounds device:device];
    _mtkView.autoresizingMask        = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _mtkView.colorPixelFormat        = MTLPixelFormatBGRA8Unorm;
    _mtkView.depthStencilPixelFormat = MTLPixelFormatDepth32Float;
    _mtkView.multipleTouchEnabled    = YES;
    [self.view addSubview:_mtkView];

    _delegate = [[BrawlerDelegate_iOS alloc] initWithDevice:device
                                                pixelFormat:_mtkView.colorPixelFormat
                                             hapticsEngine:_haptics];
    [_delegate mtkView:_mtkView drawableSizeWillChange:_mtkView.bounds.size];
    _mtkView.delegate = _delegate;
}

// ---------------------------------------------------------------------------
// Touch → InputState
// Touch anywhere: virtual joystick relative to touch-start position.
// Second simultaneous touch: attack.
// ---------------------------------------------------------------------------

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    for (UITouch *t in touches) {
        if (!_moveTouchRef) {
            _moveTouchRef = t;
            _moveOrigin   = [t locationInView:_mtkView];
            _moving       = YES;
        } else {
            // Second finger = attack
            [_delegate triggerAttack];
        }
    }
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (!_moveTouchRef) return;
    CGPoint cur = [_moveTouchRef locationInView:_mtkView];
    float dx = (float)(cur.x - _moveOrigin.x);
    float dy = (float)(cur.y - _moveOrigin.y); // screen Y-down, world Y-up inverted below

    static const float kJoyRadius = 80.f;
    float len = sqrtf(dx*dx + dy*dy);
    float mx = 0, my = 0;
    if (len > 4.f) { // small dead-zone for resting finger
        float scale = fminf(len, kJoyRadius) / kJoyRadius;
        mx =  (dx / len) * scale;
        my = -(dy / len) * scale; // invert Y: screen down = world backward
    }
    [_delegate setInputState:{mx, my, false, false, false}];
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    for (UITouch *t in touches) {
        if (t == _moveTouchRef) {
            _moveTouchRef = nil;
            _moving       = NO;
            [_delegate setInputState:{0, 0, false, false, false}];
        }
    }
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self touchesEnded:touches withEvent:event];
}

@end
