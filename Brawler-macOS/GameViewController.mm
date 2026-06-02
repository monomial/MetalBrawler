#import "GameViewController.h"
#import <MetalKit/MetalKit.h>
#include "Simulation/World.h"
#include "Simulation/Systems/ScreenShakeSystem.h"
#include "Platform/InputState.h"
#import "Renderer/BrawlerRenderer.h"
#import "Haptics/HapticsEngine.h"
#import "Audio/AudioEngine.h"
#include "Simulation/Systems/RespawnSystem.h"

// ---------------------------------------------------------------------------
// BrawlerDelegate — owns World, drives update + render via BrawlerRenderer
// ---------------------------------------------------------------------------
@interface BrawlerDelegate : NSObject <MTKViewDelegate>
- (instancetype)initWithDevice:(id<MTLDevice>)device pixelFormat:(MTLPixelFormat)pfmt;
- (void)setInputState:(InputState)state;
@end

@implementation BrawlerDelegate {
    World                _world;
    CFTimeInterval       _lastTime;
    id<MTLCommandQueue>  _commandQueue;
    BrawlerRenderer     *_renderer;
    HapticsEngine       *_haptics;
    AudioEngine         *_audio;
    dispatch_semaphore_t _frameSemaphore;
    BOOL                 _gameOver;
    float                _gameOverTimer;
}

- (instancetype)initWithDevice:(id<MTLDevice>)device pixelFormat:(MTLPixelFormat)pfmt {
    self = [super init];
    if (!self) return nil;

    _commandQueue   = [device newCommandQueue];
    _lastTime       = CACurrentMediaTime();
    _frameSemaphore = dispatch_semaphore_create(3);
    _renderer = [[BrawlerRenderer alloc] initWithDevice:device pixelFormat:pfmt];
    _haptics  = [[HapticsEngine alloc] init];
    [_haptics startupInit];
    _audio    = [[AudioEngine alloc] init];
    [_audio startupInit];

    [self _spawnEntities];

    return self;
}

- (void)_spawnEntities {
    EntityID player = _world.defer_create();
    _world.add_component<PlayerTagComponent>(player).active   = true;
    _world.add_component<PositionComponent>(player)           = {0, -100, 0};
    _world.add_component<VelocityComponent>(player)           = {0, 0, 0};
    _world.add_component<FactionComponent>(player).type       = FactionComponent::Player;
    _world.add_component<HealthComponent>(player)             = {10, 10};
    _world.add_component<DamageCooldownComponent>(player).remaining = 0.f;

    EntityID enemy = _world.defer_create();
    _world.add_component<PositionComponent>(enemy)            = {200, 300, 0};
    _world.add_component<VelocityComponent>(enemy)            = {0, 0, 0};
    _world.add_component<FactionComponent>(enemy).type        = FactionComponent::Enemy;
    _world.add_component<HealthComponent>(enemy)              = {3, 3};
}

- (void)setInputState:(InputState)state { _world.set_input(state); }

- (void)_restart {
    _world   = World();
    _gameOver = NO;
    [self _spawnEntities];
    RespawnSystem_reset();
}

- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {
    [_renderer updateDrawableSize:size];
}

- (void)drawInMTKView:(MTKView *)view {
    dispatch_semaphore_wait(_frameSemaphore, DISPATCH_TIME_FOREVER);

    CFTimeInterval now = CACurrentMediaTime();
    float physicalDt = fminf((float)(now - _lastTime), 0.1f);
    _lastTime = now;

    if (!_gameOver) {
        _world.update(physicalDt, physicalDt);

        _world.events().for_each(EventType::HitContact, [self](const Event&) {
            [_audio  playHitSound];
            [_haptics playHitHaptic];
        });

        // Detect player death → game over.
        bool playerDied = false;
        _world.events().for_each(EventType::EntityDied, [&](const Event& e) {
            if (_world.player_tags().present(e.entityDied.entityID)) playerDied = true;
        });
        if (playerDied) {
            _gameOver      = YES;
            _gameOverTimer = 3.0f; // restart after 3 seconds
        }
    } else {
        _gameOverTimer -= physicalDt;
        if (_gameOverTimer <= 0.f) [self _restart];
    }

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
// GameViewController — WASD/arrow key input → BrawlerDelegate
// ---------------------------------------------------------------------------
@implementation GameViewController {
    MTKView         *_mtkView;
    BrawlerDelegate *_delegate;
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
    _delegate = [[BrawlerDelegate alloc] initWithDevice:_mtkView.device
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
        case 0:   _left   = YES; break;
        case 2:   _right  = YES; break;
        case 13:  _up     = YES; break;
        case 1:   _down   = YES; break;
        case 123: _left   = YES; break;
        case 124: _right  = YES; break;
        case 126: _up     = YES; break;
        case 125: _down   = YES; break;
        case 49:  _attack = YES; break;
        case 56:  _dodge  = YES; break;
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
