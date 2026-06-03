#import "GameViewController.h"
#import <MetalKit/MetalKit.h>
#include "Simulation/World.h"
#include "Simulation/Systems/RespawnSystem.h"
#include "Platform/InputState.h"
#import "Renderer/BrawlerRenderer.h"
#import "Haptics/HapticsEngine.h"
#import "Audio/AudioEngine.h"
#include "Simulation/Systems/AnimationSystem.h"
#include "Assets/CharacterLoader.h"

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

    [self _loadCharacters:device];
    [self _spawnEntities];
    return self;
}

- (void)_loadCharacters:(id<MTLDevice>)device {
    NSString *res = [NSBundle mainBundle].resourcePath;
    NSString *playerDir = [res stringByAppendingPathComponent:@"assets/characters/player"];
    NSString *mesh = [playerDir stringByAppendingPathComponent:@"Ch24_nonPBR.usdz"];

    NSMutableArray<NSString*> *clips = [NSMutableArray array];
    for (NSString *n in @[@"idle.usdz", @"walk.usdz", @"attack.usdz",
                           @"hurt.usdz", @"death.usdz"])
        [clips addObject:[playerDir stringByAppendingPathComponent:n]];

    LoadedCharacter *player = CharacterLoader_load(mesh, clips, device);
    AnimationSystem_set_characters(player, player);
    [_renderer setPlayerCharacter:player enemyCharacter:player];
}

- (void)_spawnEntities {
    EntityID player = _world.defer_create();
    _world.add_component<PlayerTagComponent>(player).active       = true;
    _world.add_component<PositionComponent>(player)               = {0, -100, 0};
    _world.add_component<VelocityComponent>(player)               = {0, 0, 0};
    _world.add_component<FactionComponent>(player).type           = FactionComponent::Player;
    _world.add_component<HealthComponent>(player)                 = {10, 10};
    _world.add_component<DamageCooldownComponent>(player).remaining = 0.f;
    _world.add_component<AnimationComponent>(player);

    EntityID enemy = _world.defer_create();
    _world.add_component<PositionComponent>(enemy)                = {200, 300, 0};
    _world.add_component<VelocityComponent>(enemy)                = {0, 0, 0};
    _world.add_component<FactionComponent>(enemy).type            = FactionComponent::Enemy;
    _world.add_component<HealthComponent>(enemy)                  = {3, 3};
    _world.add_component<AnimationComponent>(enemy);
}

- (void)setInputState:(InputState)state { _world.set_input(state); }

- (void)triggerAttack {
    InputState s = _world.current_input();
    s.attack = true;
    _world.set_input(s);
}

- (void)_restart {
    _world        = World();
    _gameOver     = NO;
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

    // Always update the world so the player death animation plays through.
    _world.update(physicalDt, physicalDt);

    _world.events().for_each(EventType::HitContact, [self](const Event&) {
        [_audio  playHitSound];
        [_haptics playHitHaptic];
    });

    // Clear single-frame attack pulse.
    InputState s = _world.current_input();
    s.attack = false;
    _world.set_input(s);

    if (!_gameOver) {
        // Detect player death via dying flag (persists across ticks).
        for (EntityID id = 0; id < _world.entity_count(); ++id) {
            if (!_world.player_tags().present(id)) continue;
            if (_world.has_component<AnimationComponent>(id) &&
                _world.get_component<AnimationComponent>(id).dying) {
                _gameOver      = YES;
                _gameOverTimer = 3.0f;
            }
            break;
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
// GameViewController — manages MTKView + touch input
// ---------------------------------------------------------------------------
@implementation GameViewController {
    MTKView              *_mtkView;
    BrawlerDelegate_iOS  *_delegate;
    HapticsEngine        *_haptics;

    UITouch  *_moveTouchRef;
    CGPoint   _moveOrigin;
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
        my = -(dy / len) * scale;
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
