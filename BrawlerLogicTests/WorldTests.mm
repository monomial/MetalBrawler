#import <XCTest/XCTest.h>
#include "Simulation/World.h"

@interface WorldTests : XCTestCase
@end

@implementation WorldTests

// --- Entity lifecycle ---

- (void)test_deferCreate_returnsSequentialIDs {
    World world;
    EntityID a = world.defer_create();
    EntityID b = world.defer_create();
    XCTAssertNotEqual(a, b);
    XCTAssertEqual(b, a + 1);
}

- (void)test_update_doesNotCrash {
    World world;
    XCTAssertNoThrow(world.update(0.0f, 0.0f));
}

- (void)test_deferDestroy_withinBufferLimit {
    World world;
    for (int i = 0; i < 256; ++i) {
        EntityID id = world.defer_create();
        world.defer_destroy(id);
    }
    // flush happens inside update — should not assert/crash
    XCTAssertNoThrow(world.update(0.016f, 0.016f));
}

// --- Component add / get ---

- (void)test_addGetPosition {
    World world;
    EntityID e = world.defer_create();

    PositionComponent& pos = world.add_component<PositionComponent>(e);
    pos.x = 10.f; pos.y = 20.f; pos.z = 0.f;

    XCTAssertEqual(world.get_component<PositionComponent>(e).x, 10.f);
    XCTAssertEqual(world.get_component<PositionComponent>(e).y, 20.f);
}

- (void)test_addGetHealth {
    World world;
    EntityID e = world.defer_create();

    HealthComponent& hp = world.add_component<HealthComponent>(e);
    hp.current = 3;
    hp.max     = 5;

    XCTAssertEqual(world.get_component<HealthComponent>(e).current, 3);
    XCTAssertEqual(world.get_component<HealthComponent>(e).max,     5);
}

- (void)test_addGetFaction {
    World world;
    EntityID player = world.defer_create();
    EntityID enemy  = world.defer_create();

    world.add_component<FactionComponent>(player).type = FactionComponent::Player;
    world.add_component<FactionComponent>(enemy).type  = FactionComponent::Enemy;

    XCTAssertEqual(world.get_component<FactionComponent>(player).type, FactionComponent::Player);
    XCTAssertEqual(world.get_component<FactionComponent>(enemy).type,  FactionComponent::Enemy);
}

// --- has_component ---

- (void)test_hasComponent_falseBeforeAdd {
    World world;
    EntityID e = world.defer_create();
    XCTAssertFalse(world.has_component<HealthComponent>(e));
}

- (void)test_hasComponent_trueAfterAdd {
    World world;
    EntityID e = world.defer_create();
    world.add_component<HealthComponent>(e);
    XCTAssertTrue(world.has_component<HealthComponent>(e));
}

// --- remove_component ---

- (void)test_removeComponent_clearsPresence {
    World world;
    EntityID e = world.defer_create();
    world.add_component<HealthComponent>(e).current = 5;
    world.remove_component<HealthComponent>(e);
    XCTAssertFalse(world.has_component<HealthComponent>(e));
}

// --- defer_destroy clears all components ---

- (void)test_deferDestroy_clearsComponents {
    World world;
    EntityID e = world.defer_create();
    world.add_component<PositionComponent>(e);
    world.add_component<HealthComponent>(e);

    world.defer_destroy(e);
    world.update(0.016f, 0.016f); // flush happens here

    XCTAssertFalse(world.has_component<PositionComponent>(e));
    XCTAssertFalse(world.has_component<HealthComponent>(e));
}

- (void)test_slowMotion_scalesTickGameDtAndExpires {
    World world;
    EntityID e = world.defer_create();
    world.add_component<PositionComponent>(e) = {0.f, 0.f, 0.f};
    world.add_component<VelocityComponent>(e) = {120.f, 0.f, 0.f};

    world.trigger_slow_motion(2, 0.3f);
    XCTAssertEqualWithAccuracy(world.time_scale(), 0.3f, 0.001f);
    world.update(1.f / 120.f, 1.f / 120.f);
    XCTAssertEqualWithAccuracy(world.get_component<PositionComponent>(e).x, 0.3f, 0.001f);
    world.update(1.f / 120.f, 1.f / 120.f);
    XCTAssertEqualWithAccuracy(world.get_component<PositionComponent>(e).x, 0.6f, 0.001f);
    XCTAssertEqualWithAccuracy(world.time_scale(), 1.f, 0.001f);
    world.update(1.f / 120.f, 1.f / 120.f);
    XCTAssertEqualWithAccuracy(world.get_component<PositionComponent>(e).x, 1.6f, 0.001f);
}

- (void)test_hitStopTakesPrecedenceOverSlowMotion {
    World world;
    EntityID e = world.defer_create();
    world.add_component<PositionComponent>(e) = {0.f, 0.f, 0.f};
    world.add_component<VelocityComponent>(e) = {120.f, 0.f, 0.f};

    world.trigger_slow_motion(2, 0.3f);
    world.trigger_hit_stop(1);
    world.update(1.f / 120.f, 1.f / 120.f);
    XCTAssertEqualWithAccuracy(world.get_component<PositionComponent>(e).x, 0.f, 0.001f);
    XCTAssertEqualWithAccuracy(world.time_scale(), 0.3f, 0.001f);
    world.update(1.f / 120.f, 1.f / 120.f);
    XCTAssertEqualWithAccuracy(world.get_component<PositionComponent>(e).x, 0.3f, 0.001f);
}

// --- Multiple entities are independent ---

- (void)test_multipleEntities_independentComponents {
    World world;
    EntityID a = world.defer_create();
    EntityID b = world.defer_create();

    world.add_component<HealthComponent>(a).current = 10;
    world.add_component<HealthComponent>(b).current = 3;

    XCTAssertEqual(world.get_component<HealthComponent>(a).current, 10);
    XCTAssertEqual(world.get_component<HealthComponent>(b).current,  3);
}

@end
