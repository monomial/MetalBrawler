#import <XCTest/XCTest.h>
#include "Simulation/World.h"
#include "Simulation/Systems/ContactDamageSystem.h"

// ContactDamageSystem is no longer called from World::tick() — enemies now deal
// damage through Attack animations (CombatSystem). These tests invoke the system
// directly so the logic is still covered and the code stays ready for hazard reuse.

static constexpr float kFixedDt       = 1.0f / 120.0f;
static constexpr float kContactRange  = 65.f; // must match ContactDamageSystem.mm
static constexpr float kCooldown      = 0.75f;

static EntityID make_player(World& w) {
    EntityID e = w.defer_create();
    w.add_component<PlayerTagComponent>(e).active = true;
    w.add_component<PositionComponent>(e)         = {0, 0, 0};
    w.add_component<FactionComponent>(e).type     = FactionComponent::Player;
    w.add_component<HealthComponent>(e)           = {10, 10};
    w.add_component<DamageCooldownComponent>(e).remaining = 0.f;
    return e;
}

static EntityID make_enemy(World& w, float x, float y) {
    EntityID e = w.defer_create();
    w.add_component<PositionComponent>(e)       = {x, y, 0};
    w.add_component<VelocityComponent>(e)       = {0, 0, 0};
    w.add_component<FactionComponent>(e).type   = FactionComponent::Enemy;
    w.add_component<HealthComponent>(e)         = {5, 5};
    return e;
}

@interface ContactDamageTests : XCTestCase
@end

@implementation ContactDamageTests

- (void)test_enemyInRange_damagesPlayer {
    World world;
    EntityID player = make_player(world);
    make_enemy(world, kContactRange - 5.f, 0); // just inside range

    ContactDamageSystem_update(world, kFixedDt);
    XCTAssertEqual(world.get_component<HealthComponent>(player).current, 9);
}

- (void)test_enemyOutOfRange_noDamage {
    World world;
    EntityID player = make_player(world);
    make_enemy(world, kContactRange + 20.f, 0); // outside range

    world.update(kFixedDt, kFixedDt);
    XCTAssertEqual(world.get_component<HealthComponent>(player).current, 10);
}

- (void)test_cooldown_preventsFastRetrigger {
    World world;
    EntityID player = make_player(world);
    make_enemy(world, 10.f, 0); // well within range

    // First tick — takes damage.
    ContactDamageSystem_update(world, kFixedDt);
    int hpAfterFirst = world.get_component<HealthComponent>(player).current;
    XCTAssertEqual(hpAfterFirst, 9);

    // Several more ticks while still in contact — cooldown should block.
    for (int i = 0; i < 10; ++i) ContactDamageSystem_update(world, kFixedDt);
    XCTAssertEqual(world.get_component<HealthComponent>(player).current, 9);
}

- (void)test_cooldownExpires_allowsNextHit {
    World world;
    EntityID player = make_player(world);
    make_enemy(world, 10.f, 0);

    ContactDamageSystem_update(world, kFixedDt); // first hit
    XCTAssertEqual(world.get_component<HealthComponent>(player).current, 9);

    // Advance past full cooldown duration.
    int ticksToClear = (int)((kCooldown + 0.1f) / kFixedDt) + 1;
    for (int i = 0; i < ticksToClear; ++i) ContactDamageSystem_update(world, kFixedDt);

    XCTAssertEqual(world.get_component<HealthComponent>(player).current, 8);
}

- (void)test_hitStop_blocksContactDamage {
    World world;
    EntityID player = make_player(world);
    make_enemy(world, 10.f, 0);

    world.trigger_hit_stop(4);
    world.update(4 * kFixedDt, kFixedDt); // 4 frozen ticks

    XCTAssertEqual(world.get_component<HealthComponent>(player).current, 10);
}

- (void)test_dyingEnemy_dealsNoContactDamage {
    // A dying enemy (playing death animation) must not hurt the player.
    World world;
    EntityID player = make_player(world);
    EntityID enemy  = make_enemy(world, 10.f, 0); // well within contact range
    world.add_component<AnimationComponent>(enemy).dying = true;

    world.update(kFixedDt, kFixedDt);

    XCTAssertEqual(world.get_component<HealthComponent>(player).current, 10);
}

- (void)test_noPlayer_doesNotCrash {
    World world;
    make_enemy(world, 0, 0);
    XCTAssertNoThrow(world.update(kFixedDt, kFixedDt));
}

- (void)test_playerWithNoHealth_doesNotCrash {
    World world;
    EntityID p = world.defer_create();
    world.add_component<PlayerTagComponent>(p).active = true;
    world.add_component<PositionComponent>(p) = {0, 0, 0};
    world.add_component<FactionComponent>(p).type = FactionComponent::Player;
    // No HealthComponent intentionally
    make_enemy(world, 10.f, 0);
    XCTAssertNoThrow(world.update(kFixedDt, kFixedDt));
}

@end
