#import <XCTest/XCTest.h>
#include "Simulation/World.h"
#include "Simulation/Systems/RespawnSystem.h"
#include "Platform/InputState.h"

static constexpr float kFixedDt     = 1.0f / 120.0f;
static constexpr float kRespawnDelay = 1.5f;

static constexpr float kAttackDur = 1.03f;
static constexpr float kActiveMid = kAttackDur * 0.475f;

static EntityID spawn_player(World& w) {
    EntityID e = w.defer_create();
    w.add_component<PlayerTagComponent>(e).active = true;
    w.add_component<PositionComponent>(e) = {0, -100, 0};
    w.add_component<FactionComponent>(e).type = FactionComponent::Player;
    w.add_component<HealthComponent>(e) = {10, 10};
    w.add_component<FacingComponent>(e) = {1.f, 0.f}; // enemy spawns at +50 on X axis
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

static EntityID spawn_enemy(World& w) {
    EntityID e = w.defer_create();
    w.add_component<PositionComponent>(e) = {50, -100, 0}; // within 80-unit attack range
    w.add_component<VelocityComponent>(e) = {0, 0, 0};
    w.add_component<FactionComponent>(e).type = FactionComponent::Enemy;
    w.add_component<HealthComponent>(e) = {1, 1}; // dies in one hit
    return e;
}

static bool has_living_enemy(World& w) {
    for (EntityID id = 0; id < w.entity_count(); ++id) {
        if (!w.has_component<FactionComponent>(id)) continue;
        if (w.get_component<FactionComponent>(id).type == FactionComponent::Enemy) return true;
    }
    return false;
}

@interface RespawnTests : XCTestCase
@end

@implementation RespawnTests

- (void)setUp {
    [super setUp];
    RespawnSystem_reset(); // clear static timer state between tests
}

- (void)test_enemyKilled_respawnsAfterDelay {
    World world;
    EntityID player = spawn_player(world);
    set_attacking(world, player);
    spawn_enemy(world);

    // Player is in attack active window — enemy takes damage and dies.
    world.update(kFixedDt, kFixedDt);
    XCTAssertFalse(has_living_enemy(world));

    // Advance time past respawn delay (1.5s).
    int ticks = (int)((kRespawnDelay + 0.1f) / kFixedDt) + 1;
    world.set_input({0, 0, false, false, false});
    for (int i = 0; i < ticks; ++i)
        world.update(kFixedDt, kFixedDt);

    XCTAssertTrue(has_living_enemy(world));
}

- (void)test_enemyAlive_noRespawnTimer {
    // While an enemy is still alive, RespawnSystem should not spawn a second one.
    World world;
    spawn_player(world);
    spawn_enemy(world);

    world.set_input({0, 0, false, false, false});
    for (int i = 0; i < 300; ++i) // 2.5 seconds
        world.update(kFixedDt, kFixedDt);

    // Still exactly one enemy.
    int enemyCount = 0;
    for (EntityID id = 0; id < world.entity_count(); ++id) {
        if (world.has_component<FactionComponent>(id) &&
            world.get_component<FactionComponent>(id).type == FactionComponent::Enemy)
            ++enemyCount;
    }
    XCTAssertEqual(enemyCount, 1);
}

- (void)test_respawnedEnemy_hasFullHP {
    World world;
    spawn_player(world);
    spawn_enemy(world);

    world.set_input({0, 0, true, false, false});
    world.update(kFixedDt, kFixedDt);

    int ticks = (int)((kRespawnDelay + 0.2f) / kFixedDt) + 1;
    world.set_input({0, 0, false, false, false});
    for (int i = 0; i < ticks; ++i)
        world.update(kFixedDt, kFixedDt);

    for (EntityID id = 0; id < world.entity_count(); ++id) {
        if (!world.has_component<FactionComponent>(id)) continue;
        if (world.get_component<FactionComponent>(id).type != FactionComponent::Enemy) continue;
        XCTAssertEqual(world.get_component<HealthComponent>(id).current,
                       world.get_component<HealthComponent>(id).max);
    }
}

@end
