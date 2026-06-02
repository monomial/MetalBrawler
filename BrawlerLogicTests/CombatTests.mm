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
    World world;
    spawnPlayer(world, 0, 0);
    EntityID enemy = spawnEnemy(world, 50, 0, 3);
    world.add_component<VelocityComponent>(enemy) = {100, 0, 0};

    world.set_input({0, 0, true, false, false});
    // Feed 5 ticks — first tick hits (gameDt=kFixedDt), next 4 frozen (gameDt=0).
    world.update(5 * kFixedDt, kFixedDt);

    // Enemy had velocity 100 but was frozen for 4 ticks after the hit.
    // It only moved during the 1 live tick before the hit registered.
    // Position should be very close to 50 (barely moved).
    float x = world.get_component<PositionComponent>(enemy).x;
    XCTAssertLessThan(x, 50.f + 100.f * kFixedDt * 2); // much less than 5 ticks of movement
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

@end
