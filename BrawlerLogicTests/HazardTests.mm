#import <XCTest/XCTest.h>
#include "Simulation/World.h"
#include "Simulation/Systems/HazardSystem.h"
#include "Platform/InputState.h"

static constexpr float kFixedDt = 1.0f / 120.0f;

static void advance(World& w, float seconds) {
    int ticks = (int)(seconds / kFixedDt) + 1;
    for (int i = 0; i < ticks; ++i) w.update(kFixedDt, kFixedDt);
}

static EntityID spawnPlayer(World& world, float x, float y) {
    EntityID e = world.defer_create();
    world.add_component<PlayerTagComponent>(e) = {true, 0};
    world.add_component<PositionComponent>(e)  = {x, y, 0};
    world.add_component<VelocityComponent>(e)  = {0, 0, 0};
    world.add_component<FactionComponent>(e).type = FactionComponent::Player;
    world.add_component<HealthComponent>(e)    = {10, 10};
    world.add_component<DamageCooldownComponent>(e).remaining = 0.f;
    world.add_component<AnimationComponent>(e);
    world.add_component<FacingComponent>(e);
    return e;
}

@interface HazardTests : XCTestCase
@end

@implementation HazardTests

- (void)test_snake_followsLoopAndReturns {
    World world;
    EntityID snake = HazardSystem_spawn_snake(world, 0, 0, 300, 0);
    world.get_component<HazardComponent>(snake).lifetime = 60.f; // don't expire mid-test

    world.update(kFixedDt, kFixedDt);
    // Total loop ≈ 4 segments of ~192 each ≈ 770 units at 300 u/s ≈ 2.56s.
    float x0 = world.get_component<PositionComponent>(snake).x;

    advance(world, 1.0f);
    float xMid = world.get_component<PositionComponent>(snake).x;
    XCTAssertGreaterThan(xMid, x0 + 50.f, @"snake must travel outbound");

    advance(world, 1.8f); // ~2.8s total ≈ one full loop
    const auto& p = world.get_component<PositionComponent>(snake);
    XCTAssertLessThan(fabsf(p.x), 80.f, @"snake loops back near its origin");
    XCTAssertLessThan(fabsf(p.y), 130.f);
}

- (void)test_contactDamage_gatedByCooldown {
    World world;
    EntityID player = spawnPlayer(world, 0, 0);
    EntityID snake  = HazardSystem_spawn_snake(world, 0, 0, 300, 0);
    // Park the snake on the player: no path → it never moves.
    world.remove_component<PathFollowComponent>(snake);
    world.get_component<HazardComponent>(snake).lifetime = 60.f;

    advance(world, 2.0f);

    // Re-hit delay is 0.8s → at most 3 hits in 2s, far from 120 hits/sec.
    int hp = world.get_component<HealthComponent>(player).current;
    XCTAssertLessThan(hp, 10, @"standing in lava must hurt");
    XCTAssertGreaterThanOrEqual(hp, 10 - 3, @"cooldown must gate re-hits");
}

- (void)test_dodge_iFramesBlockHazard {
    World world;
    EntityID player = spawnPlayer(world, 0, 0);
    world.add_component<DodgeComponent>(player);
    EntityID snake = HazardSystem_spawn_snake(world, 0, 0, 300, 0);
    world.remove_component<PathFollowComponent>(snake);

    advance(world, 1.0f);

    XCTAssertEqual(world.get_component<HealthComponent>(player).current, 10);
}

- (void)test_lifetime_despawns {
    World world;
    EntityID snake = HazardSystem_spawn_snake(world, 0, 0, 300, 0);
    XCTAssertTrue(world.hazards().present(snake) ||
                  world.has_component<PositionComponent>(snake));

    advance(world, 6.5f); // default lifetime 6s

    XCTAssertFalse(world.has_component<PositionComponent>(snake),
                   @"snake must despawn after its lifetime");
}

- (void)test_bossChargeEnd_spawnsSnakes {
    World world;
    spawnPlayer(world, 0, -100);
    EntityID boss = world.defer_create();
    world.add_component<PositionComponent>(boss)       = {0, 300, 0};
    world.add_component<VelocityComponent>(boss)       = {0, 0, 0};
    world.add_component<FactionComponent>(boss).type   = FactionComponent::Enemy;
    world.add_component<HealthComponent>(boss)         = {12, 12};
    world.add_component<AnimationComponent>(boss);
    world.add_component<FacingComponent>(boss);
    world.add_component<EnemyAttackCooldownComponent>(boss);
    world.add_component<BossTagComponent>(boss);
    world.add_component<BossChargeComponent>(boss).timer = 0.01f;

    advance(world, 2.0f); // telegraph + charge + recover entry

    int snakes = 0;
    for (EntityID id = 0; id < world.entity_count(); ++id)
        if (world.hazards().present(id)) snakes++;
    XCTAssertEqual(snakes, 3, @"charge end must crack the floor into 3 snakes");
}

- (void)test_hazards_dontBlockRoomClear {
    // Hazards have no FactionComponent — _allEnemiesDefeated-style scans must
    // not see them as enemies.
    World world;
    EntityID snake = HazardSystem_spawn_snake(world, 0, 0, 300, 0);
    XCTAssertFalse(world.has_component<FactionComponent>(snake));
}

@end
