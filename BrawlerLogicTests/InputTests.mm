#import <XCTest/XCTest.h>
#include "Simulation/World.h"
#include "Platform/InputState.h"

static constexpr float kFixedDt  = 1.0f / 120.0f;
static constexpr float kEps      = 1e-3f;
static constexpr float kSpeed    = 300.0f; // must match InputSystem kPlayerSpeed

static EntityID spawnPlayer(World& world) {
    EntityID e = world.defer_create();
    world.add_component<PlayerTagComponent>(e) = {true, 0};
    world.add_component<PositionComponent>(e) = {0, 0, 0};
    world.add_component<FactionComponent>(e).type = FactionComponent::Player;
    return e;
}

@interface InputTests : XCTestCase
@end

@implementation InputTests

- (void)test_rightInput_movesPositiveX {
    World world;
    EntityID p = spawnPlayer(world);

    world.set_input({1.f, 0.f, false, false, false});
    world.update(kFixedDt, kFixedDt);

    float x = world.get_component<PositionComponent>(p).x;
    XCTAssertGreaterThan(x, 0.f);
}

- (void)test_noInput_playerDoesNotMove {
    World world;
    EntityID p = spawnPlayer(world);
    world.add_component<VelocityComponent>(p) = {0, 0, 0};

    world.set_input({0.f, 0.f, false, false, false});
    world.update(kFixedDt, kFixedDt);

    XCTAssertEqualWithAccuracy(world.get_component<PositionComponent>(p).x, 0.f, kEps);
    XCTAssertEqualWithAccuracy(world.get_component<PositionComponent>(p).y, 0.f, kEps);
}

- (void)test_diagonalInput_normalizedSpeed {
    World world;
    EntityID p = spawnPlayer(world);

    // Diagonal (1,1) should move at kPlayerSpeed, not kPlayerSpeed*sqrt(2).
    world.set_input({1.f, 1.f, false, false, false});
    world.update(kFixedDt, kFixedDt);

    PositionComponent pos = world.get_component<PositionComponent>(p);
    float dist = sqrtf(pos.x * pos.x + pos.y * pos.y);
    float expected = kSpeed * kFixedDt;
    XCTAssertEqualWithAccuracy(dist, expected, kEps);
}

- (void)test_noPlayer_doesNotCrash {
    World world;
    // No player entity — InputSystem should return early without crashing.
    world.set_input({1.f, 0.f, false, false, false});
    XCTAssertNoThrow(world.update(kFixedDt, kFixedDt));
}

- (void)test_inputChanges_velocityUpdates {
    World world;
    EntityID p = spawnPlayer(world);

    world.set_input({1.f, 0.f, false, false, false});
    world.update(kFixedDt, kFixedDt);
    float x1 = world.get_component<PositionComponent>(p).x;

    world.set_input({-1.f, 0.f, false, false, false});
    world.update(kFixedDt, kFixedDt);
    float x2 = world.get_component<PositionComponent>(p).x;

    // Second tick moved left, so x2 < x1.
    XCTAssertLessThan(x2, x1);
}

@end
