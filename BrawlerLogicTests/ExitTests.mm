#import <XCTest/XCTest.h>
#include "Simulation/World.h"
#include "Simulation/Systems/ExitSystem.h"

static constexpr float kFixedDt = 1.0f / 120.0f;

static EntityID spawnExitPlayer(World& world, float x, float y) {
    EntityID e = world.defer_create();
    world.add_component<PlayerTagComponent>(e) = {true, 0};
    world.add_component<PositionComponent>(e) = {x, y, 0.f};
    world.add_component<FactionComponent>(e).type = FactionComponent::Player;
    world.add_component<HealthComponent>(e) = {10, 10};
    world.add_component<AnimationComponent>(e);
    return e;
}

@interface ExitTests : XCTestCase
@end

@implementation ExitTests

- (void)test_exitReachedFiresOnceWithinRadius {
    World world;
    spawnExitPlayer(world, 0.f, 0.f);
    EntityID exit = world.defer_create();
    world.add_component<PositionComponent>(exit) = {0.f, kExitRadius - 1.f, 0.f};
    world.add_component<ExitComponent>(exit);

    world.update(kFixedDt, kFixedDt);

    int events = 0;
    world.events().for_each(EventType::ExitReached, [&events](const Event&) { events++; });
    XCTAssertEqual(events, 1);
    XCTAssertFalse(world.exits().present(exit));

    world.update(kFixedDt, kFixedDt);
    events = 0;
    world.events().for_each(EventType::ExitReached, [&events](const Event&) { events++; });
    XCTAssertEqual(events, 0);
}

@end
