#import "BrawlerGameDelegate.h"
#import <MetalKit/MetalKit.h>
#include "Simulation/World.h"
#include "Simulation/Systems/RespawnSystem.h"
#include "Simulation/Systems/AnimationSystem.h"
#include "Assets/CharacterLoader.h"
#import "Renderer/BrawlerRenderer.h"
#import "Haptics/HapticsEngine.h"
#import "Audio/AudioEngine.h"

@implementation BrawlerGameDelegate {
    World                _world;
    CFTimeInterval       _lastTime;
    id<MTLCommandQueue>  _commandQueue;
    BrawlerRenderer     *_renderer;
    HapticsEngine       *_haptics;
    AudioEngine         *_audio;
    dispatch_semaphore_t _frameSemaphore;
    BOOL                 _gameOver;
    float                _gameOverTimer;
    BOOL                 _attackPulse; // single-frame flag set by triggerAttack
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
    _world.add_component<PlayerTagComponent>(player).active   = true;
    _world.add_component<PositionComponent>(player)           = {0, -100, 0};
    _world.add_component<VelocityComponent>(player)           = {0, 0, 0};
    _world.add_component<FactionComponent>(player).type       = FactionComponent::Player;
    _world.add_component<HealthComponent>(player)             = {10, 10};
    _world.add_component<DamageCooldownComponent>(player).remaining = 0.f;
    _world.add_component<AnimationComponent>(player);
    _world.add_component<FacingComponent>(player); // default (0,1) = facing +Y

    EntityID enemy = _world.defer_create();
    _world.add_component<PositionComponent>(enemy)            = {200, 300, 0};
    _world.add_component<VelocityComponent>(enemy)            = {0, 0, 0};
    _world.add_component<FactionComponent>(enemy).type        = FactionComponent::Enemy;
    _world.add_component<HealthComponent>(enemy)              = {3, 3};
    _world.add_component<AnimationComponent>(enemy);
}

- (void)setInputState:(InputState)state { _world.set_input(state); }
- (InputState)currentInputState         { return _world.current_input(); }

- (void)triggerAttack  { _attackPulse = YES; }

- (void)resetInput {
    InputState zero = {};
    _world.set_input(zero);
    _attackPulse = NO;
}

- (void)_restart {
    _world    = World();
    _gameOver = NO;
    [self resetInput];
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

    // Apply single-frame attack pulse before this tick (touch/tap input only).
    if (_attackPulse) {
        InputState s = _world.current_input();
        s.attack = true;
        _world.set_input(s);
        _attackPulse = NO;
    }

    // Always update — lets the death animation finish before restart fires.
    _world.update(physicalDt, physicalDt);

    _world.events().for_each(EventType::HitContact, [self](const Event&) {
        [_audio  playHitSound];
        [_haptics playHitHaptic];
    });

    if (!_gameOver) {
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
