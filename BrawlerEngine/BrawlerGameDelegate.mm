#import "BrawlerGameDelegate.h"
#import <MetalKit/MetalKit.h>
#include "Simulation/World.h"
#include "Simulation/Systems/AnimationSystem.h"
#include "Assets/CharacterLoader.h"
#import "Renderer/BrawlerRenderer.h"
#import "Haptics/HapticsEngine.h"
#import "Audio/AudioEngine.h"

// ---------------------------------------------------------------------------
// Room definitions — 3 combat rooms + 1 boss room.
// ---------------------------------------------------------------------------
struct RoomDef {
    int  enemyCount;
    int  enemyHP;
    bool isBoss;
};

static const RoomDef kRooms[] = {
    {2,  3, false}, // Room 1 — two grunts
    {3,  3, false}, // Room 2 — three grunts
    {4,  4, false}, // Room 3 — four tougher grunts
    {1, 12, true }, // Room 4 — boss
};
static const int kNumRooms      = 4;
static const int kStartingLives = 3;

// Enemy spawn positions — first N are used for a room with N enemies.
static const float kEnemySpawns[][2] = {
    {   0, 350},
    {-200, 250},
    { 200, 250},
    {   0, 150},
    {-250, 380},
    { 200, 380},
};

// Phase timers (seconds).
static const float kRoomClearDuration = 2.0f;
static const float kWinDuration       = 5.0f;
static const float kLoseDuration      = 3.5f;

// ---------------------------------------------------------------------------

@implementation BrawlerGameDelegate {
    World                _world;
    CFTimeInterval       _lastTime;
    id<MTLCommandQueue>  _commandQueue;
    BrawlerRenderer     *_renderer;
    HapticsEngine       *_haptics;
    AudioEngine         *_audio;
    dispatch_semaphore_t _frameSemaphore;
    BOOL                 _attackPulse;

    BrawlerGamePhase     _phase;
    float                _phaseTimer;
    int                  _currentRoom;  // 0-indexed internally
    int                  _lives;
}

@synthesize onPhaseChanged;

- (BrawlerGamePhase)gamePhase    { return _phase; }
- (int)currentRoom               { return _currentRoom + 1; } // 1-indexed for UI
- (int)livesRemaining            { return _lives; }

// ---------------------------------------------------------------------------
// Init
// ---------------------------------------------------------------------------

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
    [self _startNewRun];

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

// ---------------------------------------------------------------------------
// Game state helpers
// ---------------------------------------------------------------------------

- (void)_transitionToPhase:(BrawlerGamePhase)newPhase {
    if (_phase == newPhase) return;
    _phase = newPhase;
    switch (newPhase) {
        case BrawlerGamePhaseRoomClear: _phaseTimer = kRoomClearDuration; break;
        case BrawlerGamePhaseWin:       _phaseTimer = kWinDuration;       break;
        case BrawlerGamePhaseLose:      _phaseTimer = kLoseDuration;      break;
        default: break;
    }
    if (self.onPhaseChanged)
        self.onPhaseChanged(newPhase, _currentRoom + 1, _lives);
}

- (void)_startNewRun {
    _currentRoom = 0;
    _lives       = kStartingLives;
    [self _loadRoom];
    [self _transitionToPhase:BrawlerGamePhasePlaying];
}

- (void)_loadRoom {
    _world = World();
    [self resetInput];
    [self _spawnPlayers];
    [self _spawnEnemiesForCurrentRoom];
    _renderer.livesRemaining = _lives;
}

- (void)_spawnPlayers {
    [self _spawnPlayer:0 at:-150 y:-100];
    [self _spawnPlayer:1 at: 150 y:-100];
}

- (void)_spawnPlayer:(uint8_t)index at:(float)x y:(float)y {
    EntityID e = _world.defer_create();
    _world.add_component<PlayerTagComponent>(e) = {true, index};
    _world.add_component<PositionComponent>(e)  = {x, y, 0};
    _world.add_component<VelocityComponent>(e)  = {0, 0, 0};
    _world.add_component<FactionComponent>(e).type = FactionComponent::Player;
    _world.add_component<HealthComponent>(e)    = {10, 10};
    _world.add_component<DamageCooldownComponent>(e).remaining = 0.f;
    _world.add_component<AnimationComponent>(e);
    _world.add_component<FacingComponent>(e);
}

- (void)_spawnEnemiesForCurrentRoom {
    const RoomDef& room = kRooms[_currentRoom];
    for (int i = 0; i < room.enemyCount; ++i) {
        EntityID e = _world.defer_create();
        _world.add_component<PositionComponent>(e)  = {kEnemySpawns[i][0], kEnemySpawns[i][1], 0};
        _world.add_component<VelocityComponent>(e)  = {0, 0, 0};
        _world.add_component<FactionComponent>(e).type = FactionComponent::Enemy;
        _world.add_component<HealthComponent>(e)    = {room.enemyHP, room.enemyHP};
        _world.add_component<AnimationComponent>(e);
        _world.add_component<FacingComponent>(e);
        _world.add_component<EnemyAttackCooldownComponent>(e);
    }
}

// Returns YES when no living (non-dying) enemies remain.
- (BOOL)_allEnemiesDefeated {
    for (EntityID id = 0; id < _world.entity_count(); ++id) {
        if (!_world.has_component<FactionComponent>(id)) continue;
        if (_world.get_component<FactionComponent>(id).type != FactionComponent::Enemy) continue;
        bool dying = _world.has_component<AnimationComponent>(id) &&
                     _world.get_component<AnimationComponent>(id).dying;
        if (!dying) return NO;
    }
    return YES;
}

// Returns YES when all players are in their death animation.
- (BOOL)_allPlayersDying {
    int playerCount = 0, dyingCount = 0;
    for (EntityID id = 0; id < _world.entity_count(); ++id) {
        if (!_world.player_tags().present(id)) continue;
        playerCount++;
        if (_world.has_component<AnimationComponent>(id) &&
            _world.get_component<AnimationComponent>(id).dying)
            dyingCount++;
    }
    return playerCount > 0 && dyingCount == playerCount;
}

// ---------------------------------------------------------------------------
// Input
// ---------------------------------------------------------------------------

- (void)setInputState:(InputState)state forPlayer:(int)p { _world.set_input(state, p); }
- (InputState)currentInputStateForPlayer:(int)p          { return _world.current_input(p); }
- (void)setInputState:(InputState)state                  { _world.set_input(state, 0); }
- (InputState)currentInputState                          { return _world.current_input(0); }
- (void)triggerAttack                                    { _attackPulse = YES; }

- (void)resetInput {
    InputState zero = {};
    for (int i = 0; i < 4; ++i) _world.set_input(zero, i);
    _attackPulse = NO;
}

// ---------------------------------------------------------------------------
// MTKViewDelegate
// ---------------------------------------------------------------------------

- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {
    [_renderer updateDrawableSize:size];
}

- (void)drawInMTKView:(MTKView *)view {
    dispatch_semaphore_wait(_frameSemaphore, DISPATCH_TIME_FOREVER);

    CFTimeInterval now = CACurrentMediaTime();
    float dt = fminf((float)(now - _lastTime), 0.1f);
    _lastTime = now;

    // Single-frame attack pulse (touch tap).
    if (_attackPulse) {
        InputState s = _world.current_input(0);
        s.attack = true;
        _world.set_input(s, 0);
        _attackPulse = NO;
    }

    // World always updates so death animations finish before transitions.
    _world.update(dt, dt);

    _world.events().for_each(EventType::HitContact, [self](const Event&) {
        [_audio  playHitSound];
        [_haptics playHitHaptic];
    });

    // -----------------------------------------------------------------------
    // Phase state machine
    // -----------------------------------------------------------------------
    switch (_phase) {

        case BrawlerGamePhasePlaying: {
            // All enemies defeated → room clear.
            if ([self _allEnemiesDefeated]) {
                [self _transitionToPhase:BrawlerGamePhaseRoomClear];
                break;
            }
            // All players dead → lose a life.
            if ([self _allPlayersDying]) {
                _lives--;
                _renderer.livesRemaining = _lives;
                if (self.onPhaseChanged)
                    self.onPhaseChanged(_phase, _currentRoom + 1, _lives);
                if (_lives > 0) {
                    // Retry the current room.
                    [self _loadRoom];
                    [self _transitionToPhase:BrawlerGamePhasePlaying];
                } else {
                    [self _transitionToPhase:BrawlerGamePhaseLose];
                }
            }
            break;
        }

        case BrawlerGamePhaseRoomClear: {
            _phaseTimer -= dt;
            if (_phaseTimer <= 0.f) {
                int nextRoom = _currentRoom + 1;
                if (nextRoom >= kNumRooms) {
                    [self _transitionToPhase:BrawlerGamePhaseWin];
                } else {
                    _currentRoom = nextRoom;
                    [self _loadRoom];
                    [self _transitionToPhase:BrawlerGamePhasePlaying];
                }
            }
            break;
        }

        case BrawlerGamePhaseWin:
        case BrawlerGamePhaseLose: {
            _phaseTimer -= dt;
            if (_phaseTimer <= 0.f)
                [self _startNewRun];
            break;
        }
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
