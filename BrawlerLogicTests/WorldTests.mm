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
