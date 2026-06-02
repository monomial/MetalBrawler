#import <XCTest/XCTest.h>
#include "Simulation/World.h"

static constexpr float kFixedDt  = 1.0f / 120.0f;
static constexpr float kEps      = 1e-3f;
static constexpr float kStopRadius = 30.0f;

static EntityID spawnPlayer(World& world, float x, float y) {
    EntityID e = world.defer_create();
    world.add_component<PlayerTagComponent>(e).active = true;
    world.add_component<PositionComponent>(e)         = {x, y, 0};
    world.add_component<FactionComponent>(e).type     = FactionComponent::Player;
    return e;
}

static EntityID spawnEnemy(World& world, float x, float y) {
    EntityID e = world.defer_create();
    world.add_component<PositionComponent>(e)        = {x, y, 0};
    world.add_component<VelocityComponent>(e)        = {0, 0, 0};
    world.add_component<FactionComponent>(e).type    = FactionComponent::Enemy;
    world.add_component<HealthComponent>(e)          = {3, 3};
    return e;
}

@interface EnemyAITests : XCTestCase
@end

@implementation EnemyAITests

- (void)test_enemy_movesCloserToPlayer {
    World world;
    spawnPlayer(world, 0, 0);
    EntityID enemy = spawnEnemy(world, 400, 0);

    float startX = world.get_component<PositionComponent>(enemy).x;
    world.update(kFixedDt, kFixedDt);
    float endX = world.get_component<PositionComponent>(enemy).x;

    XCTAssertLessThan(endX, startX); // moved left toward player at origin
}

- (void)test_enemy_approachesAlongCorrectAxis {
    World world;
    spawnPlayer(world, 0, 0);
    EntityID enemy = spawnEnemy(world, 0, 300); // directly above player

    world.update(kFixedDt, kFixedDt);

    PositionComponent pos = world.get_component<PositionComponent>(enemy);
    // Should move in -Y direction; X should be nearly unchanged.
    XCTAssertLessThan(pos.y, 300.f);
    XCTAssertEqualWithAccuracy(pos.x, 0.f, kEps);
}

- (void)test_enemy_stopsWithinStopRadius {
    World world;
    spawnPlayer(world, 0, 0);
    // Place enemy exactly at stop radius — it should not move.
    EntityID enemy = spawnEnemy(world, kStopRadius, 0);

    world.update(kFixedDt, kFixedDt);

    // Velocity should be zero (stopped at contact range).
    VelocityComponent vel = world.get_component<VelocityComponent>(enemy);
    XCTAssertEqualWithAccuracy(vel.vx, 0.f, kEps);
    XCTAssertEqualWithAccuracy(vel.vy, 0.f, kEps);
}

- (void)test_noPlayer_doesNotCrash {
    World world;
    spawnEnemy(world, 400, 0);
    XCTAssertNoThrow(world.update(kFixedDt, kFixedDt));
}

- (void)test_multipleEnemies_allMoveTowardPlayer {
    World world;
    spawnPlayer(world, 0, 0);
    EntityID e1 = spawnEnemy(world,  400,    0);
    EntityID e2 = spawnEnemy(world, -400,    0);
    EntityID e3 = spawnEnemy(world,    0,  400);

    world.update(kFixedDt, kFixedDt);

    XCTAssertLessThan(world.get_component<PositionComponent>(e1).x,  400.f); // moved left
    XCTAssertGreaterThan(world.get_component<PositionComponent>(e2).x, -400.f); // moved right
    XCTAssertLessThan(world.get_component<PositionComponent>(e3).y,  400.f); // moved down
}

- (void)test_hitStop_enemyDoesNotMove {
    World world;
    spawnPlayer(world, 0, 0);
    EntityID enemy = spawnEnemy(world, 400, 0);

    world.trigger_hit_stop(4);
    world.update(4 * kFixedDt, kFixedDt);

    // All 4 ticks had gameDt=0 — enemy should not have moved.
    float x = world.get_component<PositionComponent>(enemy).x;
    XCTAssertEqualWithAccuracy(x, 400.f, kEps);
}

@end
