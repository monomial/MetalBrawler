#import "BrawlerGameDelegate.h"
#import <MetalKit/MetalKit.h>
#include "Simulation/World.h"
#include "Simulation/AutoPilot.h"
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
    BOOL                 _dodgePulse;
    BOOL                 _pausePulse;
    int                  _numPlayers; // 1 or 2; set at player-select, remembered between runs

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
    _numPlayers = 1; // default; overridden at player-select
    _phase = BrawlerGamePhaseTitle;

    return self;
}

- (instancetype)initHeadless {
    self = [super init];
    if (!self) return nil;

    // No command queue, renderer, audio, haptics, or meshes — every message to
    // those nil ivars is a no-op, so the full game logic runs unchanged.
    _lastTime   = CACurrentMediaTime();
    _numPlayers = 1;
    _phase      = BrawlerGamePhaseTitle;

    return self;
}

- (void)_loadCharacters:(id<MTLDevice>)device {
    NSString *res = [NSBundle mainBundle].resourcePath;
    NSString *playerDir = [res stringByAppendingPathComponent:@"assets/characters/player"];
    NSString *mesh = [playerDir stringByAppendingPathComponent:@"Ch24_nonPBR.usdz"];

    NSMutableArray<NSString*> *clips = [NSMutableArray array];
    for (NSString *n in @[@"idle.usdz", @"walk.usdz", @"attack.usdz",
                           @"hurt.usdz", @"death.usdz", @"dodge.usdz"])
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
        case BrawlerGamePhaseTitle:
            [_audio stopMusic];
            break;
        case BrawlerGamePhasePlayerSelect:
            [self resetInput]; // clear any button that triggered the title→select transition
            break;
        case BrawlerGamePhasePlaying:
            [_audio startBattleMusic];
            _phaseTimer = 0;
            break;
        case BrawlerGamePhaseRoomClear:
            _phaseTimer = kRoomClearDuration;
            break;
        case BrawlerGamePhaseWin:
            [_audio stopMusic];
            _phaseTimer = kWinDuration;
            break;
        case BrawlerGamePhaseLose:
            [_audio stopMusic];
            _phaseTimer = kLoseDuration;
            break;
        case BrawlerGamePhasePaused:
            // Leave music playing — startBattleMusic has a guard so resuming won't restart it.
            break;
    }
    if (self.onPhaseChanged)
        self.onPhaseChanged(newPhase, _currentRoom + 1, _lives);
}

- (void)_startNewRun {
    _currentRoom = 0;
    _lives       = kStartingLives;
    _phase       = (BrawlerGamePhase)-1; // sentinel: force the first transition to fire
    [self _loadRoom];
    [self _transitionToPhase:BrawlerGamePhasePlaying];
}

- (void)_loadRoom {
    _world = World();
    _world.set_seed(self.rngSeedOverride ? self.rngSeedOverride : arc4random());
    [self resetInput];
    [self _spawnPlayers];
    [self _spawnEnemiesForCurrentRoom];
    _renderer.livesRemaining = _lives;
}

- (void)_spawnPlayers {
    if (_numPlayers >= 1) [self _spawnPlayer:0 at:(_numPlayers == 1 ? 0 : -150) y:-100];
    if (_numPlayers >= 2) [self _spawnPlayer:1 at:150 y:-100];
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
        if (room.isBoss)
            _world.add_component<BossTagComponent>(e);
    }
}

// Returns YES when no enemy entities remain in the world — i.e. all death
// animations have finished and AnimationSystem has removed the entities.
// Checking the dying flag would trigger too early (entities still visible
// mid-animation); waiting for removal means the room-clear message only
// appears after the last enemy has fully collapsed.
- (BOOL)_allEnemiesDefeated {
    for (EntityID id = 0; id < _world.entity_count(); ++id) {
        if (!_world.has_component<FactionComponent>(id)) continue;
        if (_world.get_component<FactionComponent>(id).type == FactionComponent::Enemy)
            return NO; // at least one enemy (alive or mid-death-anim) still exists
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
- (void)startGameWithPlayers:(int)playerCount {
    _numPlayers = MAX(1, MIN(2, playerCount));
    _currentRoom = 0;
    _lives       = kStartingLives;
    _phase       = (BrawlerGamePhase)-1;
    [self _loadRoom];
    [self _transitionToPhase:BrawlerGamePhasePlaying];
}

- (void)triggerAttack                                    { _attackPulse = YES; }
- (void)triggerDodge                                     { _dodgePulse  = YES; }
- (void)triggerPause                                     { _pausePulse  = YES; }

- (void)resetInput {
    InputState zero = {};
    for (int i = 0; i < 4; ++i) _world.set_input(zero, i);
    _attackPulse = NO;
    _dodgePulse  = NO;
    _pausePulse  = NO;
}

// ---------------------------------------------------------------------------
// MTKViewDelegate
// ---------------------------------------------------------------------------

- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {
    [_renderer updateDrawableSize:size];
}

// One frame of game logic, independent of rendering: input pulses, simulation,
// event→audio/haptics routing, phase state machine. Headless drivers (scenario
// tests, --autotest) call this directly with a fixed dt.
- (void)advanceFrame:(float)dt {
    // AutoPilot (scenario tests, --autotest): bot input replaces human input.
    if (self.autoPilotEnabled && _phase == BrawlerGamePhasePlaying) {
        for (int p = 0; p < _numPlayers; ++p)
            _world.set_input(AutoPilot_input(_world, p), p);
    }

    // Single-frame pulses (touch tap / flick / pause).
    BOOL anyActionPulse = _attackPulse || _dodgePulse || _pausePulse;
    if (_attackPulse || _dodgePulse) {
        InputState s = _world.current_input(0);
        if (_attackPulse) s.attack = true;
        if (_dodgePulse)  s.dodge  = true;
        _world.set_input(s, 0);
    }

    // Title and Paused phases freeze the simulation.
    BOOL simActive = (_phase != BrawlerGamePhaseTitle && _phase != BrawlerGamePhasePaused);

    if (simActive) {
        _world.update(dt, dt);

        // Play hit sound/haptic once per frame regardless of how many enemies connected —
        // queuing one buffer per HitContact event causes sounds to pile up sequentially.
        bool hitThisFrame = false;
        _world.events().for_each(EventType::HitContact, [self, &hitThisFrame](const Event&) {
            if (!hitThisFrame) {
                [_audio  playHitSound];
                [_haptics playHitHaptic];
                hitThisFrame = true;
            }
        });

        _world.events().for_each(EventType::EntityDied, [self](const Event& ev) {
            if (_world.player_tags().present(ev.entityDied.entityID))
                [_audio playHurtSound];
            else
                [_audio playDeathSound];
        });

        _world.events().for_each(EventType::DamageDealt, [self](const Event& ev) {
            uint32_t tid = ev.damageDealt.targetID;
            if (_world.player_tags().present(tid) &&
                _world.has_component<HealthComponent>(tid) &&
                _world.get_component<HealthComponent>(tid).current > 0) {
                [_audio playHurtSound];
                if (self.onPlayerDamaged)
                    dispatch_async(dispatch_get_main_queue(), self.onPlayerDamaged);
            }
        });
    }

    // -----------------------------------------------------------------------
    // Phase state machine
    // -----------------------------------------------------------------------
    switch (_phase) {

        case BrawlerGamePhaseTitle: {
            InputState s0 = _world.current_input(0);
            if (anyActionPulse || s0.attack || s0.dodge)
                [self _transitionToPhase:BrawlerGamePhasePlayerSelect];
            break;
        }

        case BrawlerGamePhasePlayerSelect: {
            // attack pulse / A button → 1 player
            // dodge  pulse / B button → 2 players
            // Platform VCs may also call startGameWithPlayers: directly (macOS keys, iOS buttons).
            InputState s0 = _world.current_input(0);
            if (_attackPulse || s0.attack)
                [self startGameWithPlayers:1];
            else if (_dodgePulse || s0.dodge)
                [self startGameWithPlayers:2];
            break;
        }

        case BrawlerGamePhasePaused: {
            if (_pausePulse)
                [self _transitionToPhase:BrawlerGamePhasePlaying];
            break;
        }

        case BrawlerGamePhasePlaying: {
            if (_pausePulse) {
                [self _transitionToPhase:BrawlerGamePhasePaused];
                break;
            }
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
                [self _transitionToPhase:BrawlerGamePhaseTitle]; // back to title, don't auto-restart
            break;
        }
    }

    _attackPulse = NO;
    _dodgePulse  = NO;
    _pausePulse  = NO;
}

- (void)drawInMTKView:(MTKView *)view {
    dispatch_semaphore_wait(_frameSemaphore, DISPATCH_TIME_FOREVER);

    CFTimeInterval now = CACurrentMediaTime();
    float dt = fminf((float)(now - _lastTime), 0.1f);
    _lastTime = now;

    [self advanceFrame:dt];

    id<MTLCommandBuffer> cmd = [_commandQueue commandBuffer];
    __block dispatch_semaphore_t sem = _frameSemaphore;
    [cmd addCompletedHandler:^(id<MTLCommandBuffer> _) {
        dispatch_semaphore_signal(sem);
    }];

    [_renderer drawWorld:&_world inView:view commandBuffer:cmd];
    [cmd commit];
}

@end
