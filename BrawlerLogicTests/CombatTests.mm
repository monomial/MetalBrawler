#import <XCTest/XCTest.h>
#include "Simulation/World.h"
#include "Simulation/Systems/WaveSystem.h"
#include "Platform/InputState.h"

static constexpr float kFixedDt      = 1.0f / 120.0f;
static constexpr float kAttackRange  = 130.0f; // must match CombatSystem.mm
static constexpr float kAttackDur    = 1.03f;  // matches kClipDurationFallback[Attack]
// Active window: 35%–60% of clip duration (matches kAttackWindows[Attack])
static constexpr float kActiveStart  = kAttackDur * 0.35f;
static constexpr float kActiveMid    = kAttackDur * 0.475f; // middle of active window
static constexpr float kActiveEnd    = kAttackDur * 0.60f;

static EntityID spawnPlayer(World& world, float x = 0, float y = 0,
                            float facingDx = 1.f, float facingDy = 0.f) {
    EntityID e = world.defer_create();
    world.add_component<PlayerTagComponent>(e) = {true, 0};
    world.add_component<PositionComponent>(e)         = {x, y, 0};
    world.add_component<FactionComponent>(e).type     = FactionComponent::Player;
    world.add_component<HealthComponent>(e)           = {10, 10};
    world.add_component<FacingComponent>(e)           = {facingDx, facingDy};
    return e;
}

// Puts the player in the Attack clip at the middle of its active window.
static void setPlayerAttacking(World& world, EntityID player) {
    if (!world.has_component<AnimationComponent>(player))
        world.add_component<AnimationComponent>(player);
    auto& anim = world.get_component<AnimationComponent>(player);
    anim.currentClip   = AnimClipID::Attack;
    anim.requestedClip = AnimClipID::Attack;
    anim.clipTime      = kActiveMid;
    anim.looping       = false;
    anim.hitApplied    = false;
}

static EntityID spawnEnemy(World& world, float x, float y, int hp = 3) {
    EntityID e = world.defer_create();
    world.add_component<PositionComponent>(e)       = {x, y, 0};
    world.add_component<VelocityComponent>(e)       = {0, 0, 0};
    world.add_component<FactionComponent>(e).type   = FactionComponent::Enemy;
    world.add_component<HealthComponent>(e)         = {hp, hp};
    return e;
}

static EntityID addWaveController(World& world, int currentWave, int waveCount) {
    EntityID c = world.defer_create();
    WaveControllerComponent& wave = world.add_component<WaveControllerComponent>(c);
    wave.phase = WavePhaseFighting;
    wave.currentWave = currentWave;
    wave.waveCount = waveCount;
    return c;
}

static int eventCount(World& world, EventType type) {
    int count = 0;
    world.events().for_each(type, [&count](const Event&) { count++; });
    return count;
}

@interface CombatTests : XCTestCase
@end

@implementation CombatTests

// --- ECS VALIDATION GATE ---
// Player presses attack → enemy in range takes damage → HP 0 → entity destroyed.

- (void)test_ECSGate_attackKillsEnemy {
    World world;
    EntityID player = spawnPlayer(world, 0, 0);
    setPlayerAttacking(world, player);
    EntityID enemy = spawnEnemy(world, 50, 0, /*hp=*/1); // 1 HP, within range

    world.update(kFixedDt, kFixedDt);

    // flush() ran — enemy had no AnimationComponent so was defer_destroyed immediately.
    XCTAssertFalse(world.has_component<HealthComponent>(enemy));
    XCTAssertFalse(world.has_component<PositionComponent>(enemy));
    XCTAssertFalse(world.has_component<FactionComponent>(enemy));
}

// --- Damage ---

- (void)test_attackInRange_dealsDamage {
    World world;
    EntityID player = spawnPlayer(world, 0, 0);
    setPlayerAttacking(world, player);
    EntityID enemy = spawnEnemy(world, 50, 0, /*hp=*/3);

    world.update(kFixedDt, kFixedDt);

    XCTAssertEqual(world.get_component<HealthComponent>(enemy).current, 2);
}

- (void)test_attackOutOfRange_noDamage {
    World world;
    EntityID player = spawnPlayer(world, 0, 0);
    setPlayerAttacking(world, player);
    EntityID enemy = spawnEnemy(world, kAttackRange + 10, 0, 3);

    world.update(kFixedDt, kFixedDt);

    XCTAssertEqual(world.get_component<HealthComponent>(enemy).current, 3);
}

- (void)test_notInActiveWindow_noDamage {
    // Player is in the Attack clip but before the active window — no damage yet.
    World world;
    EntityID player = spawnPlayer(world, 0, 0);
    setPlayerAttacking(world, player);
    world.get_component<AnimationComponent>(player).clipTime = kActiveStart * 0.5f; // before window
    EntityID enemy = spawnEnemy(world, 50, 0, 3);

    world.update(kFixedDt, kFixedDt);

    XCTAssertEqual(world.get_component<HealthComponent>(enemy).current, 3);
}

- (void)test_hitApplied_onlyOncePerSwing {
    // Even if the player stays in the active window for multiple ticks, damage fires once.
    World world;
    EntityID player = spawnPlayer(world, 0, 0);
    setPlayerAttacking(world, player);
    EntityID enemy = spawnEnemy(world, 50, 0, 5);

    // Run several ticks while clipTime stays inside the active window.
    for (int i = 0; i < 5; ++i) world.update(kFixedDt, kFixedDt);

    XCTAssertEqual(world.get_component<HealthComponent>(enemy).current, 4); // only 1 damage total
}

- (void)test_noAttackClip_noDamage {
    // Player in Idle — no damage regardless of proximity.
    World world;
    EntityID player = spawnPlayer(world, 0, 0);
    world.add_component<AnimationComponent>(player); // starts in Idle
    EntityID enemy = spawnEnemy(world, 50, 0, 3);

    world.update(kFixedDt, kFixedDt);

    XCTAssertEqual(world.get_component<HealthComponent>(enemy).current, 3);
}

// Directional punch: both enemies in the forward arc take damage.
- (void)test_multipleEnemiesInArc_allTakeDamage {
    World world;
    EntityID player = spawnPlayer(world, 0, 0, 1.f, 0.f); // facing +X
    setPlayerAttacking(world, player);
    EntityID e1 = spawnEnemy(world, 50,  20, 3); // in arc
    EntityID e2 = spawnEnemy(world, 50, -20, 3); // in arc

    world.update(kFixedDt, kFixedDt);

    XCTAssertEqual(world.get_component<HealthComponent>(e1).current, 2);
    XCTAssertEqual(world.get_component<HealthComponent>(e2).current, 2);
}

// ---------------------------------------------------------------------------
// Enemy attack path
// ---------------------------------------------------------------------------

static EntityID spawnAttackingEnemy(World& world, float x, float y,
                                    float facingDx = 1.f, float facingDy = 0.f) {
    EntityID e = world.defer_create();
    world.add_component<PositionComponent>(e)     = {x, y, 0};
    world.add_component<FactionComponent>(e).type = FactionComponent::Enemy;
    world.add_component<HealthComponent>(e)       = {5, 5};
    world.add_component<FacingComponent>(e)       = {facingDx, facingDy};
    // Put the enemy in the middle of its attack active window.
    auto& anim = world.add_component<AnimationComponent>(e);
    anim.currentClip   = AnimClipID::Attack;
    anim.requestedClip = AnimClipID::Attack;
    anim.clipTime      = kActiveMid;
    anim.looping       = false;
    anim.hitApplied    = false;
    return e;
}

- (void)test_enemyAttack_inActiveWindow_damagesPlayer {
    World world;
    // Player facing +X, enemy also facing +X and attacking from player's left (same Y).
    // Enemy is within attack range of player.
    EntityID player = spawnPlayer(world, 0, 0, 1.f, 0.f);
    world.add_component<AnimationComponent>(player);
    world.add_component<DamageCooldownComponent>(player).remaining = 0.f;
    // Enemy at (-50, 0) facing +X (toward the player to their right).
    EntityID enemy = spawnAttackingEnemy(world, -50, 0, 1.f, 0.f);

    world.update(kFixedDt, kFixedDt);

    XCTAssertEqual(world.get_component<HealthComponent>(player).current, 9); // 1 damage
}

- (void)test_enemyAttack_outOfRange_noDamage {
    World world;
    EntityID player = spawnPlayer(world, 0, 0);
    world.add_component<AnimationComponent>(player);
    world.add_component<DamageCooldownComponent>(player).remaining = 0.f;
    // Enemy well out of range.
    EntityID enemy = spawnAttackingEnemy(world, -(kAttackRange + 20), 0, 1.f, 0.f);

    world.update(kFixedDt, kFixedDt);

    XCTAssertEqual(world.get_component<HealthComponent>(player).current, 10);
}

- (void)test_enemyAttack_hitApplied_onlyOncePerSwing {
    World world;
    EntityID player = spawnPlayer(world, 0, 0);
    world.add_component<AnimationComponent>(player);
    world.add_component<DamageCooldownComponent>(player).remaining = 0.f;
    EntityID enemy = spawnAttackingEnemy(world, -50, 0, 1.f, 0.f);

    // Run several ticks while the enemy stays in its active window.
    for (int i = 0; i < 5; ++i) world.update(kFixedDt, kFixedDt);

    XCTAssertEqual(world.get_component<HealthComponent>(player).current, 9); // only 1 damage
}

// Directional punch: enemy directly behind the player is not hit.
- (void)test_enemyBehindPlayer_noDamage {
    World world;
    EntityID player = spawnPlayer(world, 0, 0, 1.f, 0.f); // facing +X
    setPlayerAttacking(world, player);
    EntityID front = spawnEnemy(world,  50, 0, 3); // in front — hit
    EntityID back  = spawnEnemy(world, -50, 0, 3); // behind  — not hit

    world.update(kFixedDt, kFixedDt);

    XCTAssertEqual(world.get_component<HealthComponent>(front).current, 2);
    XCTAssertEqual(world.get_component<HealthComponent>(back).current,  3);
}

// --- Hit-stop ---

- (void)test_hitConnects_triggersHitStop {
    World world;
    EntityID player = spawnPlayer(world, 0, 0);
    setPlayerAttacking(world, player);
    EntityID enemy = spawnEnemy(world, 50, 0, 3);

    world.update(kFixedDt, kFixedDt);
    XCTAssertEqual(world.get_component<HealthComponent>(enemy).current, 2);

    // During HitStop the next tick is frozen (gameDt=0) — CombatSystem skips it.
    world.update(kFixedDt, kFixedDt); // gameDt=0
    XCTAssertEqual(world.get_component<HealthComponent>(enemy).current, 2); // no extra damage
}

- (void)test_hitStopActive_attackBlocked {
    World world;
    EntityID player = spawnPlayer(world, 0, 0);
    setPlayerAttacking(world, player);
    EntityID enemy = spawnEnemy(world, 50, 0, 3);

    world.trigger_hit_stop(1);
    world.update(kFixedDt, kFixedDt); // gameDt=0 — CombatSystem returns early

    XCTAssertEqual(world.get_component<HealthComponent>(enemy).current, 3);
}

- (void)test_finalKillEmittedOnlyForTrueLastKill {
    World midWave;
    EntityID p1 = spawnPlayer(midWave, 0, 0);
    setPlayerAttacking(midWave, p1);
    spawnEnemy(midWave, 50, 0, 1);
    addWaveController(midWave, 0, 2);
    midWave.update(kFixedDt, kFixedDt);
    XCTAssertEqual(eventCount(midWave, EventType::FinalKill), 0);
    XCTAssertEqualWithAccuracy(midWave.time_scale(), 1.f, 0.001f);

    World anotherAlive;
    EntityID p2 = spawnPlayer(anotherAlive, 0, 0);
    setPlayerAttacking(anotherAlive, p2);
    spawnEnemy(anotherAlive, 50, 0, 1);
    spawnEnemy(anotherAlive, 200, 0, 1);
    addWaveController(anotherAlive, 0, 1);
    anotherAlive.update(kFixedDt, kFixedDt);
    XCTAssertEqual(eventCount(anotherAlive, EventType::FinalKill), 0);

    World lastKill;
    EntityID p3 = spawnPlayer(lastKill, 0, 0);
    setPlayerAttacking(lastKill, p3);
    EntityID enemy = spawnEnemy(lastKill, 50, 0, 1);
    addWaveController(lastKill, 0, 1);
    lastKill.update(kFixedDt, kFixedDt);
    XCTAssertEqual(eventCount(lastKill, EventType::FinalKill), 1);
    XCTAssertEqualWithAccuracy(lastKill.time_scale(), 0.1f, 0.001f);
    BOOL payloadOK = NO;
    lastKill.events().for_each(EventType::FinalKill, [p3, enemy, &payloadOK](const Event& ev) {
        payloadOK = ev.finalKill.killerID == p3 && ev.finalKill.victimID == enemy;
    });
    XCTAssertTrue(payloadOK);
}

// ---------------------------------------------------------------------------
// Dead-player invariants — the class of bugs in the "player stuck in death
// pose while still attacking" and "player not respawning" reports.
// ---------------------------------------------------------------------------

// Bug: CombatSystem didn't check player dying flag, only InputSystem did.
// A dying player pressing attack should deal no damage.
- (void)test_dyingPlayer_cannotAttack {
    // Player is in the attack active window but dying — no damage.
    World world;
    EntityID player = spawnPlayer(world, 0, 0);
    setPlayerAttacking(world, player);
    world.get_component<AnimationComponent>(player).dying = true;
    EntityID enemy = spawnEnemy(world, 50, 0, 3);

    world.update(kFixedDt, kFixedDt);

    XCTAssertEqual(world.get_component<HealthComponent>(enemy).current, 3);
}

// Bug: game-over detection used EntityDied event (single-tick) which is lost
// when the physics accumulator runs 2+ ticks per render frame.
// The dying flag must be set and PERSIST after player HP reaches 0 so the
// platform layer can detect death using the flag rather than the event.
- (void)test_playerDeath_dyingFlagPersistsAcrossMultipleTicks {
    // Validate that the dying flag survives multiple physics ticks in one render frame.
    // Previously relied on ContactDamageSystem; now uses an enemy Attack hitbox.
    World world;
    EntityID player = spawnPlayer(world, 0, 0, 1.f, 0.f); // facing +X
    world.add_component<AnimationComponent>(player);
    world.get_component<HealthComponent>(player).current = 1; // dies in one hit
    world.get_component<HealthComponent>(player).max     = 1;

    // Enemy at (-50,0) facing +X — player is directly in its forward arc.
    EntityID e = world.defer_create();
    world.add_component<PositionComponent>(e)     = {-50, 0, 0};
    world.add_component<FactionComponent>(e).type = FactionComponent::Enemy;
    world.add_component<HealthComponent>(e)       = {5, 5};
    world.add_component<FacingComponent>(e)       = {1.f, 0.f};
    auto& anim = world.add_component<AnimationComponent>(e);
    anim.currentClip = anim.requestedClip = AnimClipID::Attack;
    anim.clipTime    = kActiveMid;
    anim.looping     = false;
    anim.hitApplied  = false;

    // Simulate 2 ticks in one update (as happens at 60fps with 120Hz physics).
    // Tick 1: enemy attack hits player (1 HP) → player dies → EntityDied fires.
    // Tick 2: EntityDied is cleared from the event bus. Platform code that checks
    //         events after world.update() returns would miss the death entirely.
    world.update(2 * kFixedDt, kFixedDt);

    // The dying flag must still be set — it's the only reliable death signal.
    XCTAssertTrue(world.get_component<AnimationComponent>(player).dying);
}

@end
