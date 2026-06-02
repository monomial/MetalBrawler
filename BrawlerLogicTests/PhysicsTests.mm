#import <XCTest/XCTest.h>
#include "Simulation/World.h"

static constexpr float kFixedDt = 1.0f / 120.0f;
static constexpr float kEps     = 1e-4f;

@interface PhysicsTests : XCTestCase
@end

@implementation PhysicsTests

- (void)test_velocity_movesPosition {
    World world;
    EntityID e = world.defer_create();
    world.add_component<PositionComponent>(e) = {0, 0, 0};
    world.add_component<VelocityComponent>(e) = {100, 0, 0}; // 100 units/sec right

    world.update(kFixedDt, kFixedDt); // one physics tick

    float x = world.get_component<PositionComponent>(e).x;
    XCTAssertEqualWithAccuracy(x, 100.f * kFixedDt, kEps);
}

- (void)test_zeroVelocity_doesNotMove {
    World world;
    EntityID e = world.defer_create();
    world.add_component<PositionComponent>(e) = {5, 10, 0};
    world.add_component<VelocityComponent>(e) = {0, 0, 0};

    world.update(kFixedDt, kFixedDt);

    XCTAssertEqualWithAccuracy(world.get_component<PositionComponent>(e).x, 5.f, kEps);
    XCTAssertEqualWithAccuracy(world.get_component<PositionComponent>(e).y, 10.f, kEps);
}

- (void)test_multipleTicksAccumulate {
    World world;
    EntityID e = world.defer_create();
    world.add_component<PositionComponent>(e) = {0, 0, 0};
    world.add_component<VelocityComponent>(e) = {60, 0, 0}; // 60 units/sec

    // Feed 1 second of wall-clock time — should produce 120 fixed ticks.
    // Drive in small chunks to exercise the accumulator.
    for (int i = 0; i < 60; ++i)
        world.update(1.0f / 60.0f, 1.0f / 60.0f);

    float x = world.get_component<PositionComponent>(e).x;
    // 60 units/sec * 1 sec = 60 units (within floating-point rounding)
    XCTAssertEqualWithAccuracy(x, 60.f, 0.01f);
}

- (void)test_noPosition_entitySkipped {
    World world;
    EntityID e = world.defer_create();
    // Velocity only — no position. Should not crash.
    world.add_component<VelocityComponent>(e) = {100, 0, 0};

    XCTAssertNoThrow(world.update(kFixedDt, kFixedDt));
    XCTAssertFalse(world.has_component<PositionComponent>(e));
}

- (void)test_hitStop_freezesPosition {
    World world;
    EntityID e = world.defer_create();
    world.add_component<PositionComponent>(e) = {0, 0, 0};
    world.add_component<VelocityComponent>(e) = {100, 0, 0};

    world.trigger_hit_stop(4); // freeze 4 ticks
    world.update(4 * kFixedDt, kFixedDt); // 4 ticks of physicalDt

    // Position should not have moved — all 4 ticks had gameDt=0.
    float x = world.get_component<PositionComponent>(e).x;
    XCTAssertEqualWithAccuracy(x, 0.f, kEps);
}

- (void)test_hitStop_resumesAfterFreeze {
    World world;
    EntityID e = world.defer_create();
    world.add_component<PositionComponent>(e) = {0, 0, 0};
    world.add_component<VelocityComponent>(e) = {100, 0, 0};

    world.trigger_hit_stop(2);
    // 3 ticks total: 2 frozen, 1 live
    world.update(3 * kFixedDt, kFixedDt);

    float x = world.get_component<PositionComponent>(e).x;
    XCTAssertEqualWithAccuracy(x, 100.f * kFixedDt, kEps); // only 1 live tick
}

@end
