#import <XCTest/XCTest.h>
#include "Simulation/World.h"
#include "Platform/InputState.h"

static constexpr float kFixedDt      = 1.0f / 120.0f;
static constexpr float kAttackRange  = 80.0f;
static constexpr float kAttackDur    = 1.03f;  // matches kClipDurationFallback[Attack]
// Active window: 35%–60% of clip duration (matches kAttackWindows[Attack])
static constexpr float kActiveStart  = kAttackDur * 0.35f;
static constexpr float kActiveMid    = kAttackDur * 0.475f; // middle of active window
static constexpr float kActiveEnd    = kAttackDur * 0.60f;

static EntityID spawnPlayer(World& world, float x = 0, float y = 0) {
    EntityID e = world.defer_create();
    world.add_component<PlayerTagComponent>(e).active = true;
    world.add_component<PositionComponent>(e)         = {x, y, 0};
    world.add_component<FactionComponent>(e).type     = FactionComponent::Player;
    world.add_component<HealthComponent>(e)           = {10, 10};
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

- (void)test_multipleEnemiesInRange_allTakeDamage {
    World world;
    EntityID player = spawnPlayer(world, 0, 0);
    setPlayerAttacking(world, player);
    EntityID e1 = spawnEnemy(world,  50, 0, 3);
    EntityID e2 = spawnEnemy(world, -50, 0, 3);

    world.update(kFixedDt, kFixedDt);

    XCTAssertEqual(world.get_component<HealthComponent>(e1).current, 2);
    XCTAssertEqual(world.get_component<HealthComponent>(e2).current, 2);
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
    World world;
    EntityID player = spawnPlayer(world, 0, 0);
    world.add_component<AnimationComponent>(player);
    // Place an enemy in contact range so ContactDamageSystem kills the player.
    // Player has 1 HP — one contact hit kills immediately.
    world.get_component<HealthComponent>(player).current = 1;
    world.get_component<HealthComponent>(player).max     = 1;
    world.add_component<DamageCooldownComponent>(player).remaining = 0.f;
    EntityID e = world.defer_create();
    world.add_component<PositionComponent>(e)     = {30, 0, 0}; // within contact range (65)
    world.add_component<VelocityComponent>(e)     = {0, 0, 0};
    world.add_component<FactionComponent>(e).type = FactionComponent::Enemy;
    world.add_component<HealthComponent>(e)       = {5, 5};

    // Simulate 2 ticks in one update (as happens at 60fps with 120Hz physics).
    // Tick 1: player takes damage and dies — EntityDied fires.
    // Tick 2: EntityDied is cleared. Platform code checking events AFTER this
    //         call would miss the death entirely.
    world.update(2 * kFixedDt, kFixedDt);

    // The dying flag must still be set — it's the only reliable death signal.
    XCTAssertTrue(world.get_component<AnimationComponent>(player).dying);
}

@end
