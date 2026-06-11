#import "BrawlerGameDelegate.h"
#import <MetalKit/MetalKit.h>
#import "BrawlerStrings.h"
#include "Simulation/World.h"
#include "Simulation/AutoPilot.h"
#include "Simulation/Systems/AnimationSystem.h"
#include "Simulation/Systems/WaveSystem.h"
#include "Assets/CharacterLoader.h"
#import "Renderer/BrawlerRenderer.h"
#import "Haptics/HapticsEngine.h"
#import "Audio/AudioEngine.h"

// ---------------------------------------------------------------------------
// Room definitions — spawn lists of {archetype, wave, x, y}. HP/speed/scale come
// from the archetype table (Simulation/EnemyArchetypes.h).
// ---------------------------------------------------------------------------
struct EnemySpawn {
    EnemyArchetype type;
    uint8_t wave;
    float x, y;
};

struct ObstacleSpawn {
    float x, y;
    float halfW, halfH;
};

struct RoomDef {
    const EnemySpawn* spawns;
    int               count;
    const ObstacleSpawn* obstacles;
    int               obstacleCount;
};

// Run structure: fixed intro room, then kMiddlePerRun of the middle pool in a
// seeded-shuffled order, boss last.
static const EnemySpawn kIntroSpawns[] = {
    {EnemyArchetype::Grunt,  0,    0, 350},
    {EnemyArchetype::Grunt,  1, -200, 250},
    {EnemyArchetype::Grunt,  1,  200, 250},
};
static const EnemySpawn kMidGruntsRusher[] = {
    {EnemyArchetype::Grunt,  0, -200, 250},
    {EnemyArchetype::Grunt,  0,  200, 250},
    {EnemyArchetype::Grunt,  1, -160, 390},
    {EnemyArchetype::Rusher, 1,  160, 390},
};
static const EnemySpawn kMidRusherPack[] = {
    {EnemyArchetype::Rusher, 0, -250, 380},
    {EnemyArchetype::Rusher, 0,  250, 380},
    {EnemyArchetype::Rusher, 1, -160, 450},
    {EnemyArchetype::Rusher, 1,  160, 450},
};
static const EnemySpawn kMidHeavyEscort[] = {
    {EnemyArchetype::Grunt,  0, -250, 400},
    {EnemyArchetype::Grunt,  0,  250, 400},
    {EnemyArchetype::Heavy,  1,    0, 300},
    {EnemyArchetype::Grunt,  1,    0, 450},
};
static const EnemySpawn kMidMixed[] = {
    {EnemyArchetype::Rusher, 0, -250, 380},
    {EnemyArchetype::Rusher, 0,  250, 380},
    {EnemyArchetype::Heavy,  1, -150, 300}, // clear of the (0,320) pillar
    {EnemyArchetype::Grunt,  1,    0, 150},
};
static const EnemySpawn kMidTwinHeavies[] = {
    {EnemyArchetype::Heavy,  0, -180, 320},
    {EnemyArchetype::Heavy,  1,  120, 320},
    {EnemyArchetype::Rusher, 1, -260, 400},
};
static const EnemySpawn kBossSpawns[] = {
    {EnemyArchetype::Boss,   0,    0, 350},
};
static const EnemySpawn kBossReinforcements[] = {
    {EnemyArchetype::Grunt,  0, -260, 330},
    {EnemyArchetype::Rusher, 0,  260, 330},
};
static const ObstacleSpawn kHeavyEscortObstacles[] = {
    {-300.f, 150.f, 30.f, 30.f},
    { 300.f, 150.f, 30.f, 30.f},
};
static const ObstacleSpawn kMixedObstacles[] = {
    {0.f, 320.f, 35.f, 35.f},
};

static const RoomDef kIntroRoom = {kIntroSpawns, 3, nullptr, 0};
static const RoomDef kBossRoom  = {kBossSpawns, 1, nullptr, 0};
static const RoomDef kMiddleRooms[] = {
    {kMidGruntsRusher, 4, nullptr, 0},
    {kMidRusherPack,   4, nullptr, 0},
    {kMidHeavyEscort,  4, kHeavyEscortObstacles, 2},
    {kMidMixed,        4, kMixedObstacles, 1},
    {kMidTwinHeavies,  3, nullptr, 0},
};
static const int kNumMiddleRooms = 5;
static const int kMiddlePerRun   = 4;                  // middle rooms per run
static const int kNumRooms       = kMiddlePerRun + 2;  // intro + middles + boss
static const int kStartingLives  = 3;
static const int kMaxPlayers     = 4;

// Phase timers (seconds).
static const float kRoomClearDuration = 2.0f;
static const float kWinDuration       = 5.0f;
static const float kLoseDuration      = 3.5f;
static const float kUpgradeGrace      = 0.35f; // ignore held buttons right after entering Upgrade

// ---------------------------------------------------------------------------
// Perk pool — two distinct picks are offered between rooms; the chosen perk
// folds into that player's run-level PlayerPerks and is re-applied at each
// spawn (the World is rebuilt per room, so entities can't carry run state).
// Lives are team-level because lives are currently shared by the run.
// ---------------------------------------------------------------------------
typedef NS_ENUM(int, BrawlerPerk) {
    BrawlerPerkDamage = 0,
    BrawlerPerkSpeed,
    BrawlerPerkMaxHP,
    BrawlerPerkLife,
    BrawlerPerkKnockback,
    BrawlerPerkQuickDodge,
    BrawlerPerkSpecialCharge,
    BrawlerPerkSecondWind,
    BrawlerPerkCount
};

static NSString *const kPerkLabels[BrawlerPerkCount] = {
    @"+1 Punch Damage",
    @"+20% Move Speed",
    @"+3 Max Health",
    @"+1 Team Life",
    @"+30% Knockback",
    @"Quick Dodge",
    @"+50% Special Charge",
    @"Second Wind",
};

struct PlayerPerks {
    int   bonusDamage = 0;
    float speedMult   = 1.f;
    int   bonusMaxHP  = 0;
    float knockbackMult = 1.f;
    float dodgeCooldownMult = 1.f;
    float specialChargeMult = 1.f;
    int   secondWinds = 0;
    uint8_t counts[BrawlerPerkCount] = {};
};

struct RunStats {
    int enemiesDefeated = 0;
    int damageDealt     = 0;
    int damageTaken     = 0;
    int heartsCollected = 0;
    int specialsUsed    = 0;
    int perksTaken      = 0;
    float runTime       = 0.f;
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
    BOOL                 _specialPulse;
    int                  _numPlayers; // 1 or 2; set at player-select, remembered between runs

    BrawlerGamePhase     _phase;
    float                _phaseTimer;
    int                  _currentRoom;  // 0-indexed internally
    int                  _lives;

    PlayerPerks          _perks[kMaxPlayers]; // per-player run-level, reset each run
    RunStats             _runStats;
    int                  _upgradePlayerIndex; // active picker during Upgrade, -1 otherwise
    int                  _upgradeChoice[2];   // BrawlerPerk indices on offer
    int                  _middleOrder[kNumMiddleRooms]; // seeded shuffle per run
}

@synthesize onPhaseChanged;

- (BrawlerGamePhase)gamePhase    { return _phase; }
- (int)currentRoom               { return _currentRoom + 1; } // 1-indexed for UI
- (int)livesRemaining            { return _lives; }
- (int)currentUpgradePlayerIndex { return (_phase == BrawlerGamePhaseUpgrade) ? _upgradePlayerIndex : -1; }

- (void)_refreshOverlay {
    switch (_phase) {
        case BrawlerGamePhaseTitle:
            [_renderer setOverlayVisible:YES
                                   title:kBrawlerStringTitle
                                subtitle:kBrawlerStringPressToStart
                                 choiceA:nil choiceB:nil];
            break;
        case BrawlerGamePhasePlayerSelect:
            [_renderer setOverlayVisible:YES
                                   title:kBrawlerStringSelectPlayers
                                subtitle:nil
                                 choiceA:@"Attack  1 Player"
                                 choiceB:@"Dodge   2 Players"];
            break;
        case BrawlerGamePhasePlaying:
            [_renderer setOverlayVisible:NO title:nil subtitle:nil choiceA:nil choiceB:nil];
            break;
        case BrawlerGamePhaseRoomClear:
            [_renderer setOverlayVisible:YES
                                   title:[NSString stringWithFormat:kBrawlerStringRoomClearFmt, _currentRoom + 1]
                                subtitle:nil choiceA:nil choiceB:nil];
            break;
        case BrawlerGamePhaseWin:
            [_renderer setOverlayVisible:YES
                                   title:kBrawlerStringWin
                                subtitle:kBrawlerStringWinSubtitle choiceA:nil choiceB:nil
                               statLines:[self _runStatLines]];
            break;
        case BrawlerGamePhaseLose:
            [_renderer setOverlayVisible:YES
                                   title:kBrawlerStringGameOver
                                subtitle:nil choiceA:nil choiceB:nil
                               statLines:[self _runStatLines]];
            break;
        case BrawlerGamePhasePaused:
            [_renderer setOverlayVisible:YES
                                   title:kBrawlerStringPaused
                                subtitle:kBrawlerStringPausedResume
                                 choiceA:nil choiceB:nil];
            break;
        case BrawlerGamePhaseUpgrade:
            [_renderer setOverlayVisible:YES
                                   title:[NSString stringWithFormat:@"P%d CHOOSE UPGRADE", _upgradePlayerIndex + 1]
                                subtitle:nil
                                 choiceA:[NSString stringWithFormat:@"Attack  %@", [self upgradeChoiceLabel:0]]
                                 choiceB:[NSString stringWithFormat:@"Dodge   %@", [self upgradeChoiceLabel:1]]];
            break;
    }
}

- (NSArray<NSString*> *)_runStatLines {
    int seconds = (int)floorf(_runStats.runTime + 0.5f);
    int minutes = seconds / 60;
    seconds %= 60;
    return @[
        [NSString stringWithFormat:@"Time  %d:%02d", minutes, seconds],
        [NSString stringWithFormat:@"Enemies defeated  %d", _runStats.enemiesDefeated],
        [NSString stringWithFormat:@"Damage dealt  %d", _runStats.damageDealt],
        [NSString stringWithFormat:@"Damage taken  %d", _runStats.damageTaken],
        [NSString stringWithFormat:@"Hearts  %d", _runStats.heartsCollected],
        [NSString stringWithFormat:@"Specials  %d", _runStats.specialsUsed],
    ];
}

- (void)_refreshPerkHUD {
    for (int p = 0; p < kMaxPlayers; ++p) {
        BrawlerPerkSummary summary = {};
        for (int i = 0; i < BrawlerPerkCount && i < kBrawlerPerkTypeCount; ++i)
            summary.counts[i] = _perks[p].counts[i];
        [_renderer setPerkSummary:summary forPlayer:p];
    }
}

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
    [self _refreshOverlay];

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

- (LoadedCharacter *)_loadCharacterIn:(NSString *)folder
                                 mesh:(NSString *)meshName
                               device:(id<MTLDevice>)device {
    NSString *res = [NSBundle mainBundle].resourcePath;
    NSString *dir = [res stringByAppendingPathComponent:
                     [@"assets/characters" stringByAppendingPathComponent:folder]];
    NSString *mesh = [dir stringByAppendingPathComponent:meshName];
    if (![[NSFileManager defaultManager] fileExistsAtPath:mesh]) return nullptr;

    // Order must match AnimClipID: Idle, Walk, Attack, Hurt, Death, Dodge, Attack2, Run.
    NSMutableArray<NSString*> *clips = [NSMutableArray array];
    for (NSString *n in @[@"idle.usdz", @"walk.usdz", @"attack.usdz",
                           @"hurt.usdz", @"death.usdz", @"dodge.usdz",
                           @"attack2.usdz", @"run.usdz"])
        [clips addObject:[dir stringByAppendingPathComponent:n]];

    return CharacterLoader_load(mesh, clips, device);
}

- (void)_loadCharacters:(id<MTLDevice>)device {
    LoadedCharacter *player = [self _loadCharacterIn:@"player"
                                                mesh:@"Ch24_nonPBR.usdz" device:device];
    LoadedCharacter *enemy  = [self _loadCharacterIn:@"enemy"
                                                mesh:@"PumpkinhulkLShaw.usdz" device:device];
    if (!enemy) enemy = player; // enemy assets absent — fall back to tinted player

    AnimationSystem_set_characters(player, enemy);
    [_renderer setPlayerCharacter:player enemyCharacter:enemy];
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
    [self _refreshOverlay];
}

- (void)_startNewRun {
    _currentRoom = 0;
    _lives       = kStartingLives;
    for (int i = 0; i < kMaxPlayers; ++i)
        _perks[i] = PlayerPerks{};
    _runStats = RunStats{};
    [self _refreshPerkHUD];
    _upgradePlayerIndex = -1;

    // Seeded Fisher-Yates over the middle-room pool: rooms 2..N-1 differ per
    // run (the run plays kMiddlePerRun of kNumMiddleRooms), deterministic when
    // rngSeedOverride is set.
    uint32_t s = self.rngSeedOverride ? self.rngSeedOverride : arc4random();
    if (!s) s = 1;
    for (int i = 0; i < kNumMiddleRooms; ++i) _middleOrder[i] = i;
    for (int i = kNumMiddleRooms - 1; i > 0; --i) {
        s ^= s << 13; s ^= s >> 17; s ^= s << 5;
        int j = (int)(s % (uint32_t)(i + 1));
        int t = _middleOrder[i]; _middleOrder[i] = _middleOrder[j]; _middleOrder[j] = t;
    }

    _phase = (BrawlerGamePhase)-1; // sentinel: force the first transition to fire
    [self _loadRoom];
    [self _transitionToPhase:BrawlerGamePhasePlaying];
}

- (const RoomDef&)_currentRoomDef {
    if (_currentRoom <= 0)              return kIntroRoom;
    if (_currentRoom >= kNumRooms - 1)  return kBossRoom;
    return kMiddleRooms[_middleOrder[_currentRoom - 1]];
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
    if (_upgradePlayerIndex < 0 || _upgradePlayerIndex >= _numPlayers) return;

    PlayerPerks& perks = _perks[_upgradePlayerIndex];
    BrawlerPerk chosen = (BrawlerPerk)_upgradeChoice[index];
    switch (chosen) {
        case BrawlerPerkDamage: perks.bonusDamage += 1;    break;
        case BrawlerPerkSpeed:  perks.speedMult   += 0.2f; break;
        case BrawlerPerkMaxHP:  perks.bonusMaxHP  += 3;    break;
        case BrawlerPerkLife:   _lives += 1;               break;
        case BrawlerPerkKnockback:     perks.knockbackMult *= 1.3f; break;
        case BrawlerPerkQuickDodge:    perks.dodgeCooldownMult *= 0.7f; break;
        case BrawlerPerkSpecialCharge: perks.specialChargeMult *= 1.5f; break;
        case BrawlerPerkSecondWind:    perks.secondWinds += 1; break;
        case BrawlerPerkCount:  break;
    }
    if (chosen >= 0 && chosen < BrawlerPerkCount) {
        perks.counts[chosen] += 1;
        _runStats.perksTaken += 1;
        [self _refreshPerkHUD];
    }
    [_audio playUIClickSound];

    // Multiplayer: each active player gets their own fresh, deterministic
    // upgrade offer before the next room starts.
    if (_upgradePlayerIndex + 1 < _numPlayers) {
        _upgradePlayerIndex += 1;
        [self _rollUpgradeChoices];
        [self resetInput];
        _phaseTimer = kUpgradeGrace;
        if (self.onPhaseChanged)
            self.onPhaseChanged(BrawlerGamePhaseUpgrade, _currentRoom + 1, _lives);
        [self _refreshOverlay];
        return;
    }

    _upgradePlayerIndex = -1;
    _currentRoom += 1;
    [self _loadRoom];
    [self _transitionToPhase:BrawlerGamePhasePlaying];
}

- (void)_loadRoom {
    _world = World();
    _world.set_seed(self.rngSeedOverride ? self.rngSeedOverride : arc4random());
    [self resetInput];
    [self _spawnPlayers];
    [self _spawnWaveControllerForCurrentRoom];
    [self _spawnObstaclesForCurrentRoom];
    _renderer.livesRemaining = _lives;
    _renderer.totalRooms = kNumRooms;
    [self _refreshPerkHUD];
    // Boss room always gets the last (violet) palette; others cycle.
    BOOL isBossRoom = (_currentRoom >= kNumRooms - 1);
    _renderer.roomIndex = isBossRoom ? 5 : (_currentRoom % 5);
}

- (void)_spawnPlayers {
    static const float kSpawnX[kMaxPlayers] = { -180.f, 180.f, -60.f, 60.f };
    static const float kSpawnY[kMaxPlayers] = { -120.f, -120.f, -220.f, -220.f };
    if (_numPlayers == 1) {
        [self _spawnPlayer:0 at:0 y:-120];
        return;
    }
    for (int i = 0; i < _numPlayers && i < kMaxPlayers; ++i)
        [self _spawnPlayer:(uint8_t)i at:kSpawnX[i] y:kSpawnY[i]];
}

- (void)_spawnPlayer:(uint8_t)index at:(float)x y:(float)y {
    EntityID e = _world.defer_create();
    _world.add_component<PlayerTagComponent>(e) = {true, index};
    _world.add_component<PositionComponent>(e)  = {x, y, 0};
    _world.add_component<VelocityComponent>(e)  = {0, 0, 0};
    _world.add_component<FactionComponent>(e).type = FactionComponent::Player;
    const PlayerPerks& perks = _perks[index];
    int maxHP = 10 + perks.bonusMaxHP;
    _world.add_component<HealthComponent>(e)    = {maxHP, maxHP};
    _world.add_component<DamageCooldownComponent>(e).remaining = 0.f;
    _world.add_component<AnimationComponent>(e);
    _world.add_component<FacingComponent>(e);
    _world.add_component<SpecialMeterComponent>(e);
    auto& stats = _world.add_component<StatsComponent>(e);
    stats.damageBonus = perks.bonusDamage;
    stats.speedMult   = perks.speedMult;
    stats.knockbackMult = perks.knockbackMult;
    stats.dodgeCooldownMult = perks.dodgeCooldownMult;
    stats.specialChargeMult = perks.specialChargeMult;
    stats.secondWinds = perks.secondWinds;
}

- (void)_spawnWaveControllerForCurrentRoom {
    const RoomDef& room = [self _currentRoomDef];
    EntityID controller = _world.defer_create();
    WaveControllerComponent& wave = _world.add_component<WaveControllerComponent>(controller);
    wave.spawnCount = room.count;
    wave.waveCount = 0;
    wave.currentWave = 0;
    wave.timer = kInitialWaveDelay;
    wave.phase = WavePhaseInitialDelay;
    wave.bossMode = (_currentRoom >= kNumRooms - 1);
    for (int i = 0; i < room.count; ++i) {
        const EnemySpawn& spawn = room.spawns[i];
        wave.spawns[i] = {(uint8_t)spawn.type, spawn.wave, spawn.x, spawn.y};
        if ((int)spawn.wave + 1 > wave.waveCount)
            wave.waveCount = (int)spawn.wave + 1;
    }
    if (wave.bossMode) {
        wave.reinforceCount = (int)(sizeof(kBossReinforcements) / sizeof(kBossReinforcements[0]));
        for (int i = 0; i < wave.reinforceCount; ++i) {
            const EnemySpawn& spawn = kBossReinforcements[i];
            wave.reinforcements[i] = {(uint8_t)spawn.type, spawn.wave, spawn.x, spawn.y};
        }
    }
}

- (void)_spawnObstaclesForCurrentRoom {
    const RoomDef& room = [self _currentRoomDef];
    for (int i = 0; i < room.obstacleCount; ++i) {
        const ObstacleSpawn& spawn = room.obstacles[i];
        EntityID e = _world.defer_create();
        _world.add_component<PositionComponent>(e) = {spawn.x, spawn.y, 0.f};
        _world.add_component<ObstacleComponent>(e) = {spawn.halfW, spawn.halfH};
    }
}

// Returns YES when no enemy entities remain in the world — i.e. all death
// animations have finished and AnimationSystem has removed the entities.
// Checking the dying flag would trigger too early (entities still visible
// mid-animation); waiting for removal means the room-clear message only
// appears after the last enemy has fully collapsed.
- (BOOL)_allEnemiesDefeated {
    if (!WaveSystem_room_finished(_world))
        return NO;
    for (EntityID id = 0; id < _world.entity_count(); ++id) {
        if (!_world.has_component<FactionComponent>(id)) continue;
        if (_world.get_component<FactionComponent>(id).type == FactionComponent::Enemy)
            return NO; // at least one enemy (alive or mid-death-anim) still exists
    }
    return YES;
}

// Returns YES when every player is either downed or in their death animation.
- (BOOL)_allPlayersDying {
    int playerCount = 0, defeatedCount = 0;
    for (EntityID id = 0; id < _world.entity_count(); ++id) {
        if (!_world.player_tags().present(id)) continue;
        playerCount++;
        if (_world.has_component<DownedComponent>(id) ||
            (_world.has_component<AnimationComponent>(id) &&
             _world.get_component<AnimationComponent>(id).dying))
            defeatedCount++;
    }
    return playerCount > 0 && defeatedCount == playerCount;
}

// ---------------------------------------------------------------------------
// Input
// ---------------------------------------------------------------------------

- (void)setInputState:(InputState)state forPlayer:(int)p { _world.set_input(state, p); }
- (InputState)currentInputStateForPlayer:(int)p          { return _world.current_input(p); }
- (void)setInputState:(InputState)state                  { _world.set_input(state, 0); }
- (InputState)currentInputState                          { return _world.current_input(0); }
- (void)startGameWithPlayers:(int)playerCount {
    _numPlayers = MAX(1, MIN(kMaxPlayers, playerCount));
    [self _startNewRun];
}

- (void)captureNextFrameToPath:(NSString *)path          { [_renderer captureNextFrameToPath:path]; }

- (void)triggerAttack                                    { _attackPulse = YES; }
- (void)triggerDodge                                     { _dodgePulse  = YES; }
- (void)triggerSpecial                                   { _specialPulse = YES; }
- (void)triggerPause                                     { _pausePulse  = YES; }

- (void)resetInput {
    InputState zero = {};
    for (int i = 0; i < 4; ++i) _world.set_input(zero, i);
    _attackPulse = NO;
    _dodgePulse  = NO;
    _pausePulse  = NO;
    _specialPulse = NO;
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
    if (_phase == BrawlerGamePhasePlaying)
        _runStats.runTime += dt;

    // AutoPilot (scenario tests, --autotest): bot input replaces human input.
    if (self.autoPilotEnabled && _phase == BrawlerGamePhasePlaying) {
        for (int p = 0; p < _numPlayers; ++p)
            _world.set_input(AutoPilot_input(_world, p), p);
    }

    // Single-frame pulses (touch tap / flick / pause).
    BOOL anyActionPulse = _attackPulse || _dodgePulse || _pausePulse || _specialPulse;
    if (_attackPulse || _dodgePulse || _specialPulse) {
        InputState s = _world.current_input(0);
        if (_attackPulse) s.attack = true;
        if (_dodgePulse)  s.dodge  = true;
        if (_specialPulse) s.special = true;
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
            // Kept light and cartoony (kid-friendly): a few gold sparks, no gore.
            if (_world.has_component<PositionComponent>(tgt)) {
                const auto& p = _world.get_component<PositionComponent>(tgt);
                if (finisher)
                    [_renderer spawnBurstAt:(simd_float3){p.x, p.y, 90.f}
                                      count:12 speed:420.f size:14.f
                                      color:(simd_float4){1.0f, 0.45f, 0.15f, 1.f}];
                else
                    [_renderer spawnBurstAt:(simd_float3){p.x, p.y, 80.f}
                                      count:6 speed:300.f size:10.f
                                      color:(simd_float4){1.0f, 0.85f, 0.35f, 1.f}];
            }

            if (hitThisFrame) return; // sound/haptic/blur once per frame
            hitThisFrame = true;
            [_renderer triggerHitBlur:finisher ? 1.f : 0.45f];
            // No impact thud on regular hits — the swing whoosh (AttackStarted)
            // carries the punch; only the finisher gets an audible accent.
            if (finisher) {
                [_audio  playFinisherSound];
                [_haptics playFinisherHaptic];
            } else {
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

        _world.events().for_each(EventType::SpecialUsed, [self](const Event& ev) {
            _runStats.specialsUsed += 1;
            uint32_t pid = ev.specialUsed.entityID;
            if (_world.has_component<PositionComponent>(pid)) {
                const auto& p = _world.get_component<PositionComponent>(pid);
                [_renderer spawnBurstAt:(simd_float3){p.x, p.y, 110.f}
                                  count:36 speed:520.f size:16.f
                                  color:(simd_float4){1.0f, 0.8f, 0.2f, 1.f}];
            }
            [_renderer triggerHitBlur:1.f];
            [_audio playFinisherSound];
            [_haptics playFinisherHaptic];
        });

        // Ember trail on every lava snake (a few particles per frame).
        for (EntityID id = 0; id < _world.entity_count(); ++id) {
            if (!_world.hazards().present(id)) continue;
            if (!_world.has_component<PositionComponent>(id)) continue;
            const auto& p = _world.get_component<PositionComponent>(id);
            [_renderer spawnBurstAt:(simd_float3){p.x, p.y, 14.f}
                              count:1 speed:90.f size:9.f
                              color:(simd_float4){1.0f, 0.5f, 0.12f, 1.f}];
        }

        // Spawn markers glow on the floor before enemies arrive.
        for (EntityID id = 0; id < _world.entity_count(); ++id) {
            if (!_world.spawn_markers().present(id)) continue;
            if (!_world.has_component<PositionComponent>(id)) continue;
            const auto& p = _world.get_component<PositionComponent>(id);
            [_renderer spawnBurstAt:(simd_float3){p.x, p.y, 18.f}
                              count:1 speed:80.f size:8.f
                              color:(simd_float4){1.0f, 0.58f, 0.16f, 1.f}];
        }

        _world.events().for_each(EventType::WaveStarted, [self](const Event& ev) {
            (void)ev;
            [_audio playUIClickSound];
        });

        _world.events().for_each(EventType::SpawnLanded, [self](const Event& ev) {
            uint32_t eid = ev.spawnLanded.entityID;
            if (_world.has_component<PositionComponent>(eid)) {
                const auto& p = _world.get_component<PositionComponent>(eid);
                [_renderer spawnBurstAt:(simd_float3){p.x, p.y, 30.f}
                                  count:14 speed:230.f size:13.f
                                  color:(simd_float4){0.72f, 0.68f, 0.62f, 1.f}];
            }
            if (ev.spawnLanded.style == SpawnStyleSkyDrop)
                [_audio playDodgeSound];
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

        _world.events().for_each(EventType::BossEnraged, [self](const Event& ev) {
            uint32_t bid = ev.bossEnraged.entityID;
            if (_world.has_component<PositionComponent>(bid)) {
                const auto& p = _world.get_component<PositionComponent>(bid);
                [_renderer spawnBurstAt:(simd_float3){p.x, p.y, 130.f}
                                  count:40 speed:520.f size:20.f
                                  color:(simd_float4){1.0f, 0.05f, 0.03f, 1.f}];
            }
            [_renderer triggerHitBlur:1.f];
            [_audio playFinisherSound];
        });

        _world.events().for_each(EventType::EntityDied, [self](const Event& ev) {
            uint32_t died = ev.entityDied.entityID;
            if (_world.player_tags().present(died)) {
                [_audio playHurtSound];
            } else {
                _runStats.enemiesDefeated += 1;
                [_audio  playDeathSound];
                [_haptics playDeathHaptic];
                // Soft golden "poof" — deliberately not red (kid-friendly).
                if (_world.has_component<PositionComponent>(died)) {
                    const auto& p = _world.get_component<PositionComponent>(died);
                    [_renderer spawnBurstAt:(simd_float3){p.x, p.y, 60.f}
                                      count:10 speed:280.f size:12.f
                                      color:(simd_float4){1.0f, 0.85f, 0.50f, 1.f}];
                }
            }
        });

        _world.events().for_each(EventType::PickupCollected, [self](const Event& ev) {
            _runStats.heartsCollected += 1;
            uint32_t pid = ev.pickupCollected.playerID;
            if (_world.has_component<PositionComponent>(pid)) {
                const auto& p = _world.get_component<PositionComponent>(pid);
                [_renderer spawnBurstAt:(simd_float3){p.x, p.y, 70.f}
                                  count:10 speed:200.f size:10.f
                                  color:(simd_float4){1.0f, 0.5f, 0.6f, 1.f}];
            }
            [_audio playRoomClearSound];
        });

        _world.events().for_each(EventType::SecondWindUsed, [self](const Event& ev) {
            uint32_t pid = ev.secondWindUsed.playerID;
            if (_world.has_component<PositionComponent>(pid)) {
                const auto& p = _world.get_component<PositionComponent>(pid);
                [_renderer spawnBurstAt:(simd_float3){p.x, p.y, 90.f}
                                  count:24 speed:360.f size:14.f
                                  color:(simd_float4){1.0f, 0.82f, 0.25f, 1.f}];
            }
            [_audio playRoomClearSound];
            [_renderer triggerDamageFlash];
        });

        _world.events().for_each(EventType::PlayerDowned, [self](const Event& ev) {
            uint32_t pid = ev.playerDowned.playerID;
            if (_world.has_component<PositionComponent>(pid)) {
                const auto& p = _world.get_component<PositionComponent>(pid);
                [_renderer spawnBurstAt:(simd_float3){p.x, p.y, 80.f}
                                  count:14 speed:220.f size:12.f
                                  color:(simd_float4){0.45f, 0.48f, 0.55f, 1.f}];
            }
            [_audio playHurtSound];
            [_renderer triggerDamageFlash];
        });

        _world.events().for_each(EventType::PlayerRevived, [self](const Event& ev) {
            uint32_t pid = ev.playerRevived.playerID;
            if (_world.has_component<PositionComponent>(pid)) {
                const auto& p = _world.get_component<PositionComponent>(pid);
                [_renderer spawnBurstAt:(simd_float3){p.x, p.y, 90.f}
                                  count:20 speed:360.f size:14.f
                                  color:(simd_float4){1.0f, 0.78f, 0.18f, 1.f}];
            }
            [_audio playRoomClearSound];
        });

        _world.events().for_each(EventType::DamageDealt, [self](const Event& ev) {
            uint32_t tid = ev.damageDealt.targetID;
            if (_world.has_component<FactionComponent>(tid)) {
                FactionComponent::Type targetFaction = _world.get_component<FactionComponent>(tid).type;
                if (targetFaction == FactionComponent::Enemy)
                    _runStats.damageDealt += ev.damageDealt.amount;
                else if (targetFaction == FactionComponent::Player)
                    _runStats.damageTaken += ev.damageDealt.amount;
            }
            if (_world.player_tags().present(tid) &&
                _world.has_component<HealthComponent>(tid) &&
                _world.get_component<HealthComponent>(tid).current > 0) {
                [_audio playHurtSound];
                [_renderer triggerDamageFlash]; // in-shader red edge vignette
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
                    // Each active player picks a perk before the next room.
                    _upgradePlayerIndex = 0;
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
    _specialPulse = NO;
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
