#import <XCTest/XCTest.h>
#include "Simulation/World.h"
#include "Simulation/RoomBounds.h"

static constexpr float kFixedDt = 1.0f / 120.0f;
static constexpr float kEps     = 1e-3f;

static void runTicks(World& world, int ticks) {
    for (int i = 0; i < ticks; ++i) {
        world.update(kFixedDt, kFixedDt);
    }
}

@interface WallCollisionTests : XCTestCase
@end

@implementation WallCollisionTests

- (void)test_entityWithinBounds_notClamped {
    World world;
    EntityID e = world.defer_create();
    world.add_component<PositionComponent>(e) = {0, 0, 0};
    world.add_component<VelocityComponent>(e) = {0, 0, 0};

    world.update(kFixedDt, kFixedDt);
    XCTAssertEqualWithAccuracy(world.get_component<PositionComponent>(e).x, 0.f, kEps);
}

- (void)test_entityPastRightWall_clampedToMaxX {
    World world;
    EntityID e = world.defer_create();
    world.add_component<PositionComponent>(e) = {kRoomMaxX + 100.f, 0, 0};
    world.add_component<VelocityComponent>(e) = {0, 0, 0};

    world.update(kFixedDt, kFixedDt);
    XCTAssertEqualWithAccuracy(world.get_component<PositionComponent>(e).x,
                               kRoomMaxX, kEps);
}

- (void)test_entityPastLeftWall_clampedToMinX {
    World world;
    EntityID e = world.defer_create();
    world.add_component<PositionComponent>(e) = {kRoomMinX - 50.f, 0, 0};
    world.add_component<VelocityComponent>(e) = {0, 0, 0};

    world.update(kFixedDt, kFixedDt);
    XCTAssertEqualWithAccuracy(world.get_component<PositionComponent>(e).x,
                               kRoomMinX, kEps);
}

- (void)test_entityPastTopWall_clampedToMaxY {
    World world;
    EntityID e = world.defer_create();
    world.add_component<PositionComponent>(e) = {0, kRoomMaxY + 200.f, 0};
    world.add_component<VelocityComponent>(e) = {0, 0, 0};

    world.update(kFixedDt, kFixedDt);
    XCTAssertEqualWithAccuracy(world.get_component<PositionComponent>(e).y,
                               kRoomMaxY, kEps);
}

- (void)test_entityPastBottomWall_clampedToMinY {
    World world;
    EntityID e = world.defer_create();
    world.add_component<PositionComponent>(e) = {0, kRoomMinY - 50.f, 0};
    world.add_component<VelocityComponent>(e) = {0, 0, 0};

    world.update(kFixedDt, kFixedDt);
    XCTAssertEqualWithAccuracy(world.get_component<PositionComponent>(e).y,
                               kRoomMinY, kEps);
}

- (void)test_wallContact_zeroesVelocityInContactAxis {
    World world;
    EntityID e = world.defer_create();
    world.add_component<PositionComponent>(e) = {kRoomMaxX + 10.f, 0, 0};
    world.add_component<VelocityComponent>(e) = {500, 0, 0}; // moving into wall

    world.update(kFixedDt, kFixedDt);
    // vx zeroed; vy unchanged (was 0)
    XCTAssertEqualWithAccuracy(world.get_component<VelocityComponent>(e).vx, 0.f, kEps);
    XCTAssertEqualWithAccuracy(world.get_component<VelocityComponent>(e).vy, 0.f, kEps);
}

- (void)test_wallContact_preservesUnrelatedVelocityAxis {
    World world;
    EntityID e = world.defer_create();
    world.add_component<PositionComponent>(e) = {kRoomMaxX + 10.f, 0, 0}; // right wall
    world.add_component<VelocityComponent>(e) = {500, 200, 0}; // moving right AND up

    world.update(kFixedDt, kFixedDt);
    // vx zeroed (hit right wall); vy preserved
    XCTAssertEqualWithAccuracy(world.get_component<VelocityComponent>(e).vx, 0.f, kEps);
    XCTAssertGreaterThan(fabsf(world.get_component<VelocityComponent>(e).vy), 100.f);
}

- (void)test_entityWithNoVelocity_clampedWithoutCrash {
    World world;
    EntityID e = world.defer_create();
    world.add_component<PositionComponent>(e) = {kRoomMaxX + 50.f, 0, 0};
    // No VelocityComponent

    XCTAssertNoThrow(world.update(kFixedDt, kFixedDt));
    XCTAssertEqualWithAccuracy(world.get_component<PositionComponent>(e).x,
                               kRoomMaxX, kEps);
}

- (void)test_hitStop_wallCollisionFrozen {
    World world;
    EntityID e = world.defer_create();
    world.add_component<PositionComponent>(e) = {0, 0, 0};
    world.add_component<VelocityComponent>(e) = {9999, 0, 0}; // would exit instantly

    world.trigger_hit_stop(4);
    world.update(4 * kFixedDt, kFixedDt); // 4 frozen ticks

    // Position must not have changed (PhysicsSystem + WallCollision both skip on gameDt=0)
    XCTAssertEqualWithAccuracy(world.get_component<PositionComponent>(e).x, 0.f, kEps);
}

- (void)test_obstaclePushesEntityOutOnXAxis {
    World world;
    EntityID obstacle = world.defer_create();
    world.add_component<PositionComponent>(obstacle) = {0, 0, 0};
    world.add_component<ObstacleComponent>(obstacle) = {30.f, 30.f};
    EntityID e = world.defer_create();
    world.add_component<PositionComponent>(e) = {60.f, 0.f, 0.f};
    world.add_component<VelocityComponent>(e) = {100.f, 0.f, 0.f};

    world.update(kFixedDt, kFixedDt);

    XCTAssertEqualWithAccuracy(world.get_component<PositionComponent>(e).x, 70.f, kEps);
    XCTAssertEqualWithAccuracy(world.get_component<VelocityComponent>(e).vx, 0.f, kEps);
}

- (void)test_obstaclePushesEntityOutOnYAxis {
    World world;
    EntityID obstacle = world.defer_create();
    world.add_component<PositionComponent>(obstacle) = {0, 0, 0};
    world.add_component<ObstacleComponent>(obstacle) = {30.f, 30.f};
    EntityID e = world.defer_create();
    world.add_component<PositionComponent>(e) = {0.f, 60.f, 0.f};
    world.add_component<VelocityComponent>(e) = {0.f, 100.f, 0.f};

    world.update(kFixedDt, kFixedDt);

    XCTAssertEqualWithAccuracy(world.get_component<PositionComponent>(e).y, 70.f, kEps);
    XCTAssertEqualWithAccuracy(world.get_component<VelocityComponent>(e).vy, 0.f, kEps);
}

- (void)test_obstacleSlidePreservesTangentialVelocity {
    World world;
    EntityID obstacle = world.defer_create();
    world.add_component<PositionComponent>(obstacle) = {0, 0, 0};
    world.add_component<ObstacleComponent>(obstacle) = {30.f, 30.f};
    EntityID e = world.defer_create();
    world.add_component<PositionComponent>(e) = {60.f, 20.f, 0.f};
    world.add_component<VelocityComponent>(e) = {120.f, 220.f, 0.f};

    world.update(kFixedDt, kFixedDt);

    XCTAssertEqualWithAccuracy(world.get_component<PositionComponent>(e).x, 70.f, kEps);
    XCTAssertEqualWithAccuracy(world.get_component<VelocityComponent>(e).vx, 0.f, kEps);
    XCTAssertGreaterThan(world.get_component<VelocityComponent>(e).vy, 100.f);
}

- (void)test_obstacleCornerSlideProgressesAroundCorner {
    World world;
    EntityID obstacle = world.defer_create();
    world.add_component<PositionComponent>(obstacle) = {0.f, 0.f, 0.f};
    world.add_component<ObstacleComponent>(obstacle) = {30.f, 30.f};
    EntityID e = world.defer_create();
    world.add_component<PositionComponent>(e) = {-120.f, -95.f, 0.f};
    world.add_component<VelocityComponent>(e) = {160.f, 100.f, 0.f};

    runTicks(world, (int)(1.5f / kFixedDt));

    const PositionComponent& pos = world.get_component<PositionComponent>(e);
    XCTAssertGreaterThan(pos.x, 40.f,
                         @"corner contact should slide around the pillar instead of pinning near the lower-left contact point");
}

- (void)test_obstacleFaceSlideStillPreservesParallelMovement {
    World world;
    EntityID obstacle = world.defer_create();
    world.add_component<PositionComponent>(obstacle) = {0.f, 0.f, 0.f};
    world.add_component<ObstacleComponent>(obstacle) = {30.f, 30.f};
    EntityID e = world.defer_create();
    world.add_component<PositionComponent>(e) = {-20.f, -60.f, 0.f};
    world.add_component<VelocityComponent>(e) = {180.f, 0.f, 0.f};

    runTicks(world, 20);

    const PositionComponent& pos = world.get_component<PositionComponent>(e);
    const VelocityComponent& vel = world.get_component<VelocityComponent>(e);
    XCTAssertEqualWithAccuracy(pos.y, -70.f, kEps);
    XCTAssertGreaterThan(pos.x, 5.f);
    XCTAssertGreaterThan(vel.vx, 100.f);
}

- (void)test_obstacleDeepPenetrationPushesEntityFullyOutside {
    World world;
    EntityID obstacle = world.defer_create();
    world.add_component<PositionComponent>(obstacle) = {0.f, 0.f, 0.f};
    world.add_component<ObstacleComponent>(obstacle) = {30.f, 30.f};
    EntityID e = world.defer_create();
    world.add_component<PositionComponent>(e) = {0.f, 0.f, 0.f};
    world.add_component<VelocityComponent>(e) = {0.f, 0.f, 0.f};

    world.update(kFixedDt, kFixedDt);

    const PositionComponent& pos = world.get_component<PositionComponent>(e);
    XCTAssertTrue(fabsf(pos.x) >= 70.f || fabsf(pos.y) >= 70.f);
}

- (void)test_hazardPassesThroughObstacle {
    World world;
    EntityID obstacle = world.defer_create();
    world.add_component<PositionComponent>(obstacle) = {0, 0, 0};
    world.add_component<ObstacleComponent>(obstacle) = {30.f, 30.f};
    EntityID hazard = world.defer_create();
    world.add_component<PositionComponent>(hazard) = {0.f, 0.f, 0.f};
    world.add_component<VelocityComponent>(hazard) = {100.f, 0.f, 0.f};
    world.add_component<HazardComponent>(hazard);

    world.update(kFixedDt, kFixedDt);

    XCTAssertLessThan(world.get_component<PositionComponent>(hazard).x, 2.f,
                      @"hazard moves normally but is not pushed out of pillars");
    XCTAssertEqualWithAccuracy(world.get_component<PositionComponent>(hazard).y, 0.f, kEps);
}

- (void)test_hazardInsideObstaclePassesThroughUnchanged {
    World world;
    EntityID obstacle = world.defer_create();
    world.add_component<PositionComponent>(obstacle) = {0.f, 0.f, 0.f};
    world.add_component<ObstacleComponent>(obstacle) = {30.f, 30.f};
    EntityID hazard = world.defer_create();
    world.add_component<PositionComponent>(hazard) = {0.f, 0.f, 0.f};
    world.add_component<VelocityComponent>(hazard) = {0.f, 0.f, 0.f};
    world.add_component<HazardComponent>(hazard);

    world.update(kFixedDt, kFixedDt);

    XCTAssertEqualWithAccuracy(world.get_component<PositionComponent>(hazard).x, 0.f, kEps);
    XCTAssertEqualWithAccuracy(world.get_component<PositionComponent>(hazard).y, 0.f, kEps);
}

- (void)test_positionOutsideObstacleUntouched {
    World world;
    EntityID obstacle = world.defer_create();
    world.add_component<PositionComponent>(obstacle) = {0, 0, 0};
    world.add_component<ObstacleComponent>(obstacle) = {30.f, 30.f};
    EntityID e = world.defer_create();
    world.add_component<PositionComponent>(e) = {120.f, 0.f, 0.f};
    world.add_component<VelocityComponent>(e) = {0.f, 0.f, 0.f};

    world.update(kFixedDt, kFixedDt);

    XCTAssertEqualWithAccuracy(world.get_component<PositionComponent>(e).x, 120.f, kEps);
}

@end
