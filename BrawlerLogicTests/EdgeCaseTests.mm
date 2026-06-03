#import <XCTest/XCTest.h>
#include "Simulation/World.h"
#include "Simulation/EventBus.h"
#include "Platform/InputState.h"

static constexpr float kFixedDt = 1.0f / 120.0f;

// --- Helpers ---

static constexpr float kAttackDur   = 1.03f;
static constexpr float kActiveMid   = kAttackDur * 0.475f;

static EntityID spawn_player(World& w) {
    EntityID e = w.defer_create();
    w.add_component<PlayerTagComponent>(e) = {true, 0};
    w.add_component<PositionComponent>(e) = {0, 0, 0};
    w.add_component<FactionComponent>(e).type = FactionComponent::Player;
    w.add_component<HealthComponent>(e) = {10, 10};
    w.add_component<FacingComponent>(e) = {1.f, 0.f}; // facing +X to match enemy placements
    return e;
}

static void set_attacking(World& w, EntityID player) {
    if (!w.has_component<AnimationComponent>(player))
        w.add_component<AnimationComponent>(player);
    auto& anim = w.get_component<AnimationComponent>(player);
    anim.currentClip = anim.requestedClip = AnimClipID::Attack;
    anim.clipTime    = kActiveMid;
    anim.looping     = false;
    anim.hitApplied  = false;
}

static EntityID spawn_enemy_full(World& w, float x) {
    EntityID e = w.defer_create();
    w.add_component<PositionComponent>(e) = {x, 0, 0};
    w.add_component<VelocityComponent>(e) = {0, 0, 0};
    w.add_component<FactionComponent>(e).type = FactionComponent::Enemy;
    w.add_component<HealthComponent>(e) = {1, 1};
    return e;
}

@interface EdgeCaseTests : XCTestCase
@end

@implementation EdgeCaseTests

// MARK: - CombatSystem safety

- (void)test_combat_enemyWithNoPosition_doesNotCrash {
    // Enemy has Faction + Health but NO PositionComponent — CombatSystem should skip it.
    World world;
    spawn_player(world);
    EntityID enemy = world.defer_create();
    world.add_component<FactionComponent>(enemy).type = FactionComponent::Enemy;
    world.add_component<HealthComponent>(enemy) = {3, 3};

    world.set_input({0, 0, /*attack=*/true, false, false});
    XCTAssertNoThrow(world.update(kFixedDt, kFixedDt));
    // Enemy health unchanged (was not hit).
    XCTAssertEqual(world.get_component<HealthComponent>(enemy).current, 3);
}

- (void)test_combat_enemyWithNoHealth_doesNotCrash {
    // Enemy has Position + Faction but NO HealthComponent.
    World world;
    spawn_player(world);
    EntityID enemy = world.defer_create();
    world.add_component<PositionComponent>(enemy) = {30, 0, 0}; // within attack range
    world.add_component<FactionComponent>(enemy).type = FactionComponent::Enemy;

    world.set_input({0, 0, /*attack=*/true, false, false});
    XCTAssertNoThrow(world.update(kFixedDt, kFixedDt));
}

- (void)test_combat_playerWithNoPosition_doesNotCrash {
    // Player exists (PlayerTag) but has no PositionComponent.
    World world;
    EntityID player = world.defer_create();
    world.add_component<PlayerTagComponent>(player) = {true, 0};
    world.add_component<FactionComponent>(player).type = FactionComponent::Player;
    spawn_enemy_full(world, 50);

    world.set_input({0, 0, /*attack=*/true, false, false});
    XCTAssertNoThrow(world.update(kFixedDt, kFixedDt));
}

- (void)test_combat_twoEnemiesDieInSameFrame {
    // Two enemies with 1 HP both in the forward arc — both destroyed in one attack.
    World world;
    EntityID player = spawn_player(world); // facing +X
    set_attacking(world, player);
    EntityID e1 = spawn_enemy_full(world, 40);   // in arc (+X)
    EntityID e2 = spawn_enemy_full(world, 50);   // in arc (+X, further)

    world.update(kFixedDt, kFixedDt);

    // Both destroyed (no AnimationComponent → immediate defer_destroy).
    XCTAssertFalse(world.has_component<HealthComponent>(e1));
    XCTAssertFalse(world.has_component<HealthComponent>(e2));
}

// MARK: - EnemyAI safety

- (void)test_enemyAI_enemyWithNoPosition_doesNotCrash {
    // Enemy has Faction but no PositionComponent — AI should skip it.
    World world;
    spawn_player(world);
    EntityID enemy = world.defer_create();
    world.add_component<FactionComponent>(enemy).type = FactionComponent::Enemy;

    XCTAssertNoThrow(world.update(kFixedDt, kFixedDt));
}

- (void)test_enemyAI_playerWithNoPosition_doesNotCrash {
    // Player tag exists but no Position — AI should bail early.
    World world;
    EntityID player = world.defer_create();
    world.add_component<PlayerTagComponent>(player) = {true, 0};
    EntityID enemy = world.defer_create();
    world.add_component<PositionComponent>(enemy) = {200, 0, 0};
    world.add_component<FactionComponent>(enemy).type = FactionComponent::Enemy;

    XCTAssertNoThrow(world.update(kFixedDt, kFixedDt));
}

// MARK: - World safety

- (void)test_world_deferDestroyTwice_doesNotCrash {
    // Destroying the same entity twice in one frame should not corrupt the buffer.
    World world;
    EntityID e = world.defer_create();
    world.add_component<PositionComponent>(e) = {0, 0, 0};
    world.defer_destroy(e);
    world.defer_destroy(e);

    // flush is called inside update — should not crash.
    XCTAssertNoThrow(world.update(kFixedDt, kFixedDt));
}

- (void)test_world_entityCountMonotonicallyIncreases {
    World world;
    XCTAssertEqual(world.entity_count(), (uint32_t)0);
    world.defer_create();
    XCTAssertEqual(world.entity_count(), (uint32_t)1);
    world.defer_create();
    XCTAssertEqual(world.entity_count(), (uint32_t)2);
    // Destroying does not reduce entity_count (IDs are not recycled in V1).
    EntityID e = world.defer_create();
    world.defer_destroy(e);
    world.update(kFixedDt, kFixedDt);
    XCTAssertEqual(world.entity_count(), (uint32_t)3);
}

// MARK: - EventBus safety

- (void)test_eventBus_forEachOnEmptyBus_doesNotCrash {
    EventBus bus;
    int count = 0;
    XCTAssertNoThrow(
        bus.for_each(EventType::HitContact, [&](const Event&) { ++count; })
    );
    XCTAssertEqual(count, 0);
}

- (void)test_eventBus_forEachMismatchedType_returnsZero {
    EventBus bus;
    bus.emit_damage(1, 5); // DamageDealt, not HitContact
    int count = 0;
    bus.for_each(EventType::HitContact, [&](const Event&) { ++count; });
    XCTAssertEqual(count, 0);
}

- (void)test_eventBus_multipleClears_idempotent {
    EventBus bus;
    bus.emit_damage(1, 1);
    bus.clear();
    bus.clear(); // second clear should be safe
    XCTAssertEqual(bus.count, 0);
}

- (void)test_eventBus_eventsPreserveOrder {
    EventBus bus;
    bus.emit_damage(10, 1);
    bus.emit_damage(20, 2);
    bus.emit_damage(30, 3);

    int idx = 0;
    uint32_t expectedIDs[] = {10, 20, 30};
    bus.for_each(EventType::DamageDealt, [&](const Event& e) {
        XCTAssertEqual(e.damageDealt.targetID, expectedIDs[idx++]);
    });
    XCTAssertEqual(idx, 3);
}

@end
