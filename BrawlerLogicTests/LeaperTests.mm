#import <XCTest/XCTest.h>
#include "Simulation/World.h"
#include "Simulation/RoomBounds.h"
#include "Simulation/Systems/EnemyFactory.h"

static constexpr float kFixedDt = 1.0f / 120.0f;

static void advance(World& world, int ticks) {
    for (int i = 0; i < ticks; ++i) world.update(kFixedDt, kFixedDt);
}

static void advanceUntilState(World& world, EntityID leaper, uint8_t state, int maxTicks) {
    for (int i = 0; i < maxTicks; ++i) {
        if (world.get_component<LeaperComponent>(leaper).state == state) return;
        world.update(kFixedDt, kFixedDt);
    }
}

static EntityID spawnPlayer(World& world, float x, float y, int hp = 10) {
    EntityID e = world.defer_create();
    world.add_component<PlayerTagComponent>(e) = {true, 0};
    world.add_component<PositionComponent>(e) = {x, y, 0.f};
    world.add_component<VelocityComponent>(e) = {0.f, 0.f, 0.f};
    world.add_component<FactionComponent>(e).type = FactionComponent::Player;
    world.add_component<HealthComponent>(e) = {hp, hp};
    world.add_component<DamageCooldownComponent>(e).remaining = 0.f;
    world.add_component<AnimationComponent>(e);
    world.add_component<FacingComponent>(e);
    return e;
}

@interface LeaperTests : XCTestCase
@end

@implementation LeaperTests

- (void)test_leaperFullCycleObstacleShortenAndSingleContactDamage {
    World world;
    EntityID player = spawnPlayer(world, 360.f, 0.f);
    EntityID leaper = Enemy_spawn(world, (uint8_t)EnemyArchetype::Leaper, 0.f, 0.f);
    EntityID obstacle = world.defer_create();
    world.add_component<PositionComponent>(obstacle) = {440.f, 0.f, 0.f};
    world.add_component<ObstacleComponent>(obstacle) = {20.f, 80.f};

    world.update(kFixedDt, kFixedDt);

    XCTAssertEqual(world.get_component<LeaperComponent>(leaper).state, 1);
    XCTAssertTrue(world.telegraph_lines().present(leaper));
    const LeaperComponent& telegraph = world.get_component<LeaperComponent>(leaper);
    XCTAssertEqualWithAccuracy(telegraph.destX, 360.f, 0.01f);
    XCTAssertEqualWithAccuracy(telegraph.destY, 0.f, 0.01f);

    advanceUntilState(world, leaper, 2, 140);
    while (world.get_component<HealthComponent>(player).current == 10 &&
           world.get_component<LeaperComponent>(leaper).state == 2) {
        world.update(kFixedDt, kFixedDt);
    }

    XCTAssertEqual(world.get_component<LeaperComponent>(leaper).state, 2);
    XCTAssertFalse(world.telegraph_lines().present(leaper));
    XCTAssertEqual(world.get_component<HealthComponent>(player).current, 7);
    XCTAssertGreaterThan(world.get_component<DamageCooldownComponent>(player).remaining, 0.f);

    advanceUntilState(world, leaper, 3, 100);
    XCTAssertEqual(world.get_component<HealthComponent>(player).current, 7);

    advanceUntilState(world, leaper, 0, 120);
    XCTAssertEqual(world.get_component<LeaperComponent>(leaper).state, 0);
    XCTAssertGreaterThan(world.get_component<LeaperComponent>(leaper).cooldown, 3.9f);
}

- (void)test_leaperDestinationClampsInsideRoomBounds {
    World world;
    spawnPlayer(world, 480.f, 0.f);
    EntityID leaper = Enemy_spawn(world, (uint8_t)EnemyArchetype::Leaper, 120.f, 0.f);

    world.update(kFixedDt, kFixedDt);

    const LeaperComponent& leap = world.get_component<LeaperComponent>(leaper);
    XCTAssertEqual(leap.state, 1);
    XCTAssertEqualWithAccuracy(leap.destX, kRoomMaxX - 60.f, 0.01f);
    XCTAssertEqualWithAccuracy(leap.destY, 0.f, 0.01f);
}

- (void)test_leaperDodgeIFramesAvoidLeapDamage {
    World world;
    EntityID player = spawnPlayer(world, 300.f, 0.f);
    world.add_component<DodgeComponent>(player);
    EntityID leaper = Enemy_spawn(world, (uint8_t)EnemyArchetype::Leaper, 0.f, 0.f);

    world.update(kFixedDt, kFixedDt);
    advanceUntilState(world, leaper, 3, 220);

    XCTAssertEqual(world.get_component<HealthComponent>(player).current, 10);
}

- (void)test_leaperDoesNotAttemptWhenPlayerOutsideRange {
    World nearWorld;
    spawnPlayer(nearWorld, 100.f, 0.f);
    EntityID nearLeaper = Enemy_spawn(nearWorld, (uint8_t)EnemyArchetype::Leaper, 0.f, 0.f);
    nearWorld.update(kFixedDt, kFixedDt);
    XCTAssertEqual(nearWorld.get_component<LeaperComponent>(nearLeaper).state, 0);
    XCTAssertFalse(nearWorld.telegraph_lines().present(nearLeaper));

    World farWorld;
    spawnPlayer(farWorld, 700.f, 0.f);
    EntityID farLeaper = Enemy_spawn(farWorld, (uint8_t)EnemyArchetype::Leaper, 0.f, 0.f);
    farWorld.update(kFixedDt, kFixedDt);
    XCTAssertEqual(farWorld.get_component<LeaperComponent>(farLeaper).state, 0);
    XCTAssertFalse(farWorld.telegraph_lines().present(farLeaper));
}

@end
