#import <XCTest/XCTest.h>
#include "Simulation/World.h"
#include "Platform/InputState.h"

static constexpr float kFixedDt     = 1.0f / 120.0f;
static constexpr float kEps         = 1e-3f;
static constexpr float kAttackRange = 80.0f;

static EntityID spawnPlayer(World& world, float x = 0, float y = 0) {
    EntityID e = world.defer_create();
    world.add_component<PlayerTagComponent>(e).active = true;
    world.add_component<PositionComponent>(e)         = {x, y, 0};
    world.add_component<FactionComponent>(e).type     = FactionComponent::Player;
    world.add_component<HealthComponent>(e)           = {10, 10};
    return e;
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
    spawnPlayer(world, 0, 0);
    EntityID enemy = spawnEnemy(world, 50, 0, /*hp=*/1); // 1 HP, within range

    world.set_input({0, 0, /*attack=*/true, false, false});
    world.update(kFixedDt, kFixedDt);

    // flush() ran inside tick — all components removed from dead entity.
    XCTAssertFalse(world.has_component<HealthComponent>(enemy));
    XCTAssertFalse(world.has_component<PositionComponent>(enemy));
    XCTAssertFalse(world.has_component<FactionComponent>(enemy));
}

// --- Damage ---

- (void)test_attackInRange_dealsDamage {
    World world;
    spawnPlayer(world, 0, 0);
    EntityID enemy = spawnEnemy(world, 50, 0, /*hp=*/3);

    world.set_input({0, 0, true, false, false});
    world.update(kFixedDt, kFixedDt);

    XCTAssertEqual(world.get_component<HealthComponent>(enemy).current, 2);
}

- (void)test_attackOutOfRange_noDamage {
    World world;
    spawnPlayer(world, 0, 0);
    EntityID enemy = spawnEnemy(world, kAttackRange + 10, 0, 3);

    world.set_input({0, 0, true, false, false});
    world.update(kFixedDt, kFixedDt);

    XCTAssertEqual(world.get_component<HealthComponent>(enemy).current, 3);
}

- (void)test_noAttackInput_noDamage {
    World world;
    spawnPlayer(world, 0, 0);
    EntityID enemy = spawnEnemy(world, 50, 0, 3);

    world.set_input({0, 0, /*attack=*/false, false, false});
    world.update(kFixedDt, kFixedDt);

    XCTAssertEqual(world.get_component<HealthComponent>(enemy).current, 3);
}

- (void)test_multipleEnemiesInRange_allTakeDamage {
    World world;
    spawnPlayer(world, 0, 0);
    EntityID e1 = spawnEnemy(world,  50, 0, 3);
    EntityID e2 = spawnEnemy(world, -50, 0, 3);

    world.set_input({0, 0, true, false, false});
    world.update(kFixedDt, kFixedDt);

    XCTAssertEqual(world.get_component<HealthComponent>(e1).current, 2);
    XCTAssertEqual(world.get_component<HealthComponent>(e2).current, 2);
}

// --- Hit-stop ---

- (void)test_hitConnects_triggersHitStop {
    // Verify that a successful attack lands and triggers HitStop (second attack within
    // the frozen window must not deal damage).
    World world;
    spawnPlayer(world, 0, 0);
    EntityID enemy = spawnEnemy(world, 50, 0, 3);

    // First attack — should hit (distance 50 < kAttackRange 80) and trigger HitStop.
    world.set_input({0, 0, /*attack=*/true, false, false});
    world.update(kFixedDt, kFixedDt);
    int hpAfterFirstHit = world.get_component<HealthComponent>(enemy).current;
    XCTAssertEqual(hpAfterFirstHit, 2); // took 1 damage

    // Second attack attempt while still inside the HitStop window — blocked.
    world.set_input({0, 0, /*attack=*/true, false, false});
    world.update(kFixedDt, kFixedDt); // gameDt=0 (frozen tick)
    XCTAssertEqual(world.get_component<HealthComponent>(enemy).current, 2); // no extra damage
}

- (void)test_hitStopActive_attackBlocked {
    World world;
    spawnPlayer(world, 0, 0);
    EntityID enemy = spawnEnemy(world, 50, 0, 3);

    // Pre-freeze the world before the attack tick.
    world.trigger_hit_stop(1);
    world.set_input({0, 0, true, false, false});
    world.update(kFixedDt, kFixedDt); // this tick has gameDt=0

    // CombatSystem returned early — no damage.
    XCTAssertEqual(world.get_component<HealthComponent>(enemy).current, 3);
}

// ---------------------------------------------------------------------------
// Dead-player invariants — the class of bugs in the "player stuck in death
// pose while still attacking" and "player not respawning" reports.
// ---------------------------------------------------------------------------

// Bug: CombatSystem didn't check player dying flag, only InputSystem did.
// A dying player pressing attack should deal no damage.
- (void)test_dyingPlayer_cannotAttack {
    World world;
    EntityID player = spawnPlayer(world, 0, 0);
    world.add_component<AnimationComponent>(player).dying = true;
    EntityID enemy = spawnEnemy(world, 50, 0, 3);

    world.set_input({0, 0, /*attack=*/true, false, false});
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
