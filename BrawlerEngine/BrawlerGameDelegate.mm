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
// Room definitions — spawn lists of {archetype, x, y}. HP/speed/scale come
// from the archetype table (Simulation/EnemyArchetypes.h).
// ---------------------------------------------------------------------------
struct EnemySpawn {
    EnemyArchetype type;
    float x, y;
};

struct RoomDef {
    const EnemySpawn* spawns;
    int               count;
};

static const EnemySpawn kRoom1[] = {
    {EnemyArchetype::Grunt,     0, 350},
    {EnemyArchetype::Grunt,  -200, 250},
};
static const EnemySpawn kRoom2[] = {
    {EnemyArchetype::Grunt,  -200, 250},
    {EnemyArchetype::Grunt,   200, 250},
    {EnemyArchetype::Rusher,    0, 400},
};
static const EnemySpawn kRoom3[] = {
    {EnemyArchetype::Rusher, -250, 380},
    {EnemyArchetype::Rusher,  250, 380},
    {EnemyArchetype::Heavy,     0, 300},
    {EnemyArchetype::Grunt,     0, 150},
};
static const EnemySpawn kRoom4[] = {
    {EnemyArchetype::Boss,      0, 350},
};

static const RoomDef kRooms[] = {
    {kRoom1, 2},
    {kRoom2, 3},
    {kRoom3, 4},
    {kRoom4, 1},
};
static const int kNumRooms      = 4;
static const int kStartingLives = 3;

// Phase timers (seconds).
static const float kRoomClearDuration = 2.0f;
static const float kWinDuration       = 5.0f;
static const float kLoseDuration      = 3.5f;
static const float kUpgradeGrace      = 0.35f; // ignore held buttons right after entering Upgrade

// ---------------------------------------------------------------------------
// Perk pool — two distinct picks are offered between rooms; the chosen perk
// folds into run-level PlayerPerks and is re-applied to players at each spawn
// (the World is rebuilt per room, so entities can't carry run state).
// ---------------------------------------------------------------------------
typedef NS_ENUM(int, BrawlerPerk) {
    BrawlerPerkDamage = 0,
    BrawlerPerkSpeed,
    BrawlerPerkMaxHP,
    BrawlerPerkLife,
    BrawlerPerkCount
};

static NSString *const kPerkLabels[BrawlerPerkCount] = {
    @"+1 Punch Damage",
    @"+20% Move Speed",
    @"+3 Max Health",
    @"+1 Life",
};

struct PlayerPerks {
    int   bonusDamage = 0;
    float speedMult   = 1.f;
    int   bonusMaxHP  = 0;
};

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

    PlayerPerks          _perks;            // run-level, reset each new run
    int                  _upgradeChoice[2]; // BrawlerPerk indices on offer
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

    // Order must match AnimClipID: Idle, Walk, Attack, Hurt, Death, Dodge, Attack2.
    NSMutableArray<NSString*> *clips = [NSMutableArray array];
    for (NSString *n in @[@"idle.usdz", @"walk.usdz", @"attack.usdz",
                           @"hurt.usdz", @"death.usdz", @"dodge.usdz",
                           @"attack2.usdz"])
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
            [_audio playUIClickSound];
            break;
        case BrawlerGamePhasePlaying:
            [_audio startBattleMusic];
            _phaseTimer = 0;
            break;
        case BrawlerGamePhaseRoomClear:
            _phaseTimer = kRoomClearDuration;
            [_audio playRoomClearSound];
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
        case BrawlerGamePhaseUpgrade:
            [self resetInput];
            _phaseTimer = kUpgradeGrace; // brief grace so held buttons don't insta-pick
            break;
    }
    if (self.onPhaseChanged)
        self.onPhaseChanged(newPhase, _currentRoom + 1, _lives);
}

- (void)_startNewRun {
    _currentRoom = 0;
    _lives       = kStartingLives;
    _perks       = PlayerPerks{};
    _phase       = (BrawlerGamePhase)-1; // sentinel: force the first transition to fire
    [self _loadRoom];
    [self _transitionToPhase:BrawlerGamePhasePlaying];
}

// Roll two distinct perks from the pool using the (seeded) world RNG so
// deterministic runs offer deterministic choices.
- (void)_rollUpgradeChoices {
    _upgradeChoice[0] = (int)_world.rand_range(BrawlerPerkCount);
    _upgradeChoice[1] = (_upgradeChoice[0] + 1 +
                         (int)_world.rand_range(BrawlerPerkCount - 1)) % BrawlerPerkCount;
}

- (NSString *)upgradeChoiceLabel:(int)index {
    if (index < 0 || index > 1) return @"";
    return kPerkLabels[_upgradeChoice[index]];
}

- (void)chooseUpgrade:(int)index {
    if (_phase != BrawlerGamePhaseUpgrade) return;
    if (index < 0 || index > 1) return;

    switch ((BrawlerPerk)_upgradeChoice[index]) {
        case BrawlerPerkDamage: _perks.bonusDamage += 1;   break;
        case BrawlerPerkSpeed:  _perks.speedMult   += 0.2f; break;
        case BrawlerPerkMaxHP:  _perks.bonusMaxHP  += 3;   break;
        case BrawlerPerkLife:   _lives += 1;               break;
        case BrawlerPerkCount:  break;
    }
    [_audio playUIClickSound];

    _currentRoom += 1;
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
    _renderer.roomIndex      = _currentRoom;
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
    int maxHP = 10 + _perks.bonusMaxHP;
    _world.add_component<HealthComponent>(e)    = {maxHP, maxHP};
    _world.add_component<DamageCooldownComponent>(e).remaining = 0.f;
    _world.add_component<AnimationComponent>(e);
    _world.add_component<FacingComponent>(e);
    auto& stats = _world.add_component<StatsComponent>(e);
    stats.damageBonus = _perks.bonusDamage;
    stats.speedMult   = _perks.speedMult;
}

- (void)_spawnEnemiesForCurrentRoom {
    const RoomDef& room = kRooms[_currentRoom];
    for (int i = 0; i < room.count; ++i) {
        const EnemySpawn& spawn = room.spawns[i];
        const EnemyArchetypeDef& def = enemy_archetype_def((uint8_t)spawn.type);

        EntityID e = _world.defer_create();
        _world.add_component<PositionComponent>(e)  = {spawn.x, spawn.y, 0};
        _world.add_component<VelocityComponent>(e)  = {0, 0, 0};
        _world.add_component<FactionComponent>(e).type = FactionComponent::Enemy;
        _world.add_component<HealthComponent>(e)    = {def.maxHP, def.maxHP};
        _world.add_component<AnimationComponent>(e);
        _world.add_component<FacingComponent>(e);
        _world.add_component<EnemyAttackCooldownComponent>(e);
        _world.add_component<EnemyArchetypeComponent>(e).type = (uint8_t)spawn.type;
        if (spawn.type == EnemyArchetype::Boss) {
            _world.add_component<BossTagComponent>(e);
            _world.add_component<BossChargeComponent>(e); // charge attack state machine
        }
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
    [self _startNewRun];
}

- (void)captureNextFrameToPath:(NSString *)path          { [_renderer captureNextFrameToPath:path]; }

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

    // Title, Paused, and Upgrade phases freeze the simulation.
    BOOL simActive = (_phase != BrawlerGamePhaseTitle &&
                      _phase != BrawlerGamePhasePaused &&
                      _phase != BrawlerGamePhaseUpgrade);

    if (simActive) {
        _world.update(dt, dt);

        // Play hit sound/haptic once per frame regardless of how many enemies connected —
        // queuing one buffer per HitContact event causes sounds to pile up sequentially.
        // The finisher (Attack2) gets its own heavier sound + haptic.
        bool hitThisFrame = false;
        _world.events().for_each(EventType::HitContact, [self, &hitThisFrame](const Event& ev) {
            uint32_t atk = ev.hitContact.attackerID;
            uint32_t tgt = ev.hitContact.targetID;
            bool finisher = _world.has_component<AnimationComponent>(atk) &&
                            _world.get_component<AnimationComponent>(atk).currentClip
                                == AnimClipID::Attack2;

            // Spark burst at the impact point — per contact, not per frame.
            if (_world.has_component<PositionComponent>(tgt)) {
                const auto& p = _world.get_component<PositionComponent>(tgt);
                if (finisher)
                    [_renderer spawnBurstAt:(simd_float3){p.x, p.y, 90.f}
                                      count:26 speed:420.f size:16.f
                                      color:(simd_float4){1.0f, 0.45f, 0.15f, 1.f}];
                else
                    [_renderer spawnBurstAt:(simd_float3){p.x, p.y, 80.f}
                                      count:14 speed:300.f size:12.f
                                      color:(simd_float4){1.0f, 0.85f, 0.35f, 1.f}];
            }

            if (hitThisFrame) return; // sound/haptic once per frame
            hitThisFrame = true;
            if (finisher) {
                [_audio  playFinisherSound];
                [_haptics playFinisherHaptic];
            } else {
                [_audio  playHitSound];
                [_haptics playHitHaptic];
            }
        });

        // Swing whoosh + light haptic when a player's punch starts (whiff or not).
        // Player-only: four grunts swinging at once would be a wall of noise.
        bool swingThisFrame = false;
        _world.events().for_each(EventType::AttackStarted, [self, &swingThisFrame](const Event& ev) {
            if (swingThisFrame) return;
            if (!_world.player_tags().present(ev.attackStarted.entityID)) return;
            swingThisFrame = true;
            [_audio  playSwingSound];
            [_haptics playAttackHaptic];
        });

        _world.events().for_each(EventType::DodgeStarted, [self](const Event& ev) {
            if (!_world.player_tags().present(ev.dodgeStarted.entityID)) return;
            [_audio  playDodgeSound];
            [_haptics playDodgeHaptic];
        });

        // Boss winding up a charge: warning burst + an audible cue.
        _world.events().for_each(EventType::BossTelegraph, [self](const Event& ev) {
            uint32_t bid = ev.bossTelegraph.entityID;
            if (_world.has_component<PositionComponent>(bid)) {
                const auto& p = _world.get_component<PositionComponent>(bid);
                [_renderer spawnBurstAt:(simd_float3){p.x, p.y, 120.f}
                                  count:32 speed:260.f size:18.f
                                  color:(simd_float4){1.0f, 0.15f, 0.10f, 1.f}];
            }
            [_audio playSwingSound];
        });

        _world.events().for_each(EventType::EntityDied, [self](const Event& ev) {
            uint32_t died = ev.entityDied.entityID;
            if (_world.player_tags().present(died)) {
                [_audio playHurtSound];
            } else {
                [_audio  playDeathSound];
                [_haptics playDeathHaptic];
                if (_world.has_component<PositionComponent>(died)) {
                    const auto& p = _world.get_component<PositionComponent>(died);
                    [_renderer spawnBurstAt:(simd_float3){p.x, p.y, 60.f}
                                      count:30 speed:360.f size:14.f
                                      color:(simd_float4){1.0f, 0.25f, 0.20f, 1.f}];
                }
            }
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
                if (_currentRoom + 1 >= kNumRooms) {
                    [self _transitionToPhase:BrawlerGamePhaseWin];
                } else {
                    // Pick a perk before the next room (chooseUpgrade: advances).
                    [self _rollUpgradeChoices];
                    [self _transitionToPhase:BrawlerGamePhaseUpgrade];
                }
            }
            break;
        }

        case BrawlerGamePhaseUpgrade: {
            _phaseTimer -= dt;
            if (_phaseTimer > 0.f) break; // input grace window
            // Platform VCs may call chooseUpgrade: directly (keys/buttons);
            // the universal mapping is attack → choice 0, dodge → choice 1.
            InputState s0 = _world.current_input(0);
            if (_attackPulse || s0.attack)      [self chooseUpgrade:0];
            else if (_dodgePulse || s0.dodge)   [self chooseUpgrade:1];
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
    if (self.fixedFrameDt > 0.f) dt = self.fixedFrameDt; // deterministic autotest

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
