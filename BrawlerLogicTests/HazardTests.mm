#import <XCTest/XCTest.h>
#include "Simulation/World.h"
#include "Simulation/AutoPilot.h"
#include "Simulation/Systems/HazardSystem.h"
#include "Simulation/AutoPilot.h"
#include "Platform/InputState.h"

static constexpr float kFixedDt = 1.0f / 120.0f;

static void advance(World& w, float seconds) {
    int ticks = (int)(seconds / kFixedDt) + 1;
    for (int i = 0; i < ticks; ++i) w.update(kFixedDt, kFixedDt);
}

static EntityID spawnPlayer(World& world, float x, float y) {
    EntityID e = world.defer_create();
    world.add_component<PlayerTagComponent>(e) = {true, 0};
    world.add_component<PositionComponent>(e)  = {x, y, 0};
    world.add_component<VelocityComponent>(e)  = {0, 0, 0};
    world.add_component<FactionComponent>(e).type = FactionComponent::Player;
    world.add_component<HealthComponent>(e)    = {10, 10};
    world.add_component<DamageCooldownComponent>(e).remaining = 0.f;
    world.add_component<AnimationComponent>(e);
    world.add_component<FacingComponent>(e);
    world.add_component<DodgeChargesComponent>(e);
    return e;
}

@interface HazardTests : XCTestCase
@end

@implementation HazardTests

- (void)test_autoPilotSteersAwayFromStandingHazard {
    World world;
    AutoPilot_reset();
    spawnPlayer(world, 0.f, 0.f);
    EntityID enemy = world.defer_create();
    world.add_component<PositionComponent>(enemy) = {200.f, 0.f, 0.f};
    world.add_component<VelocityComponent>(enemy) = {0.f, 0.f, 0.f};
    world.add_component<FactionComponent>(enemy).type = FactionComponent::Enemy;
    world.add_component<HealthComponent>(enemy) = {2, 2};
    world.add_component<AnimationComponent>(enemy);
    EntityID lava = world.defer_create();
    world.add_component<PositionComponent>(lava) = {40.f, 0.f, 0.f};
    world.add_component<HazardComponent>(lava).radius = 70.f;

    InputState in = AutoPilot_input(world, 0);
    XCTAssertLessThan(in.moveX, 0.f, @"bot should avoid stepping into lava, not chase through it");
}

- (void)test_autoPilotDodgesIncomingProjectile {
    World world;
    AutoPilot_reset();
    spawnPlayer(world, 0.f, 0.f);
    EntityID enemy = world.defer_create();
    world.add_component<PositionComponent>(enemy) = {220.f, 0.f, 0.f};
    world.add_component<VelocityComponent>(enemy) = {0.f, 0.f, 0.f};
    world.add_component<FactionComponent>(enemy).type = FactionComponent::Enemy;
    world.add_component<HealthComponent>(enemy) = {4, 4};
    world.add_component<AnimationComponent>(enemy);
    EntityID projectile = world.defer_create();
    world.add_component<PositionComponent>(projectile) = {-120.f, 0.f, 0.f};
    world.add_component<ProjectileComponent>(projectile) = {420.f, 0.f, 1, 2.5f, 2.2f};

    InputState in = AutoPilot_input(world, 0);
    XCTAssertTrue(in.dodge);
    XCTAssertNotEqualWithAccuracy(in.moveY, 0.f, 0.001f);
}

- (void)test_autoPilotDodgesLeaperTelegraphDestination {
    World world;
    AutoPilot_reset();
    spawnPlayer(world, 0.f, 0.f);
    EntityID leaper = world.defer_create();
    world.add_component<PositionComponent>(leaper) = {0.f, 200.f, 0.f};
    world.add_component<VelocityComponent>(leaper) = {0.f, 0.f, 0.f};
    world.add_component<FactionComponent>(leaper).type = FactionComponent::Enemy;
    world.add_component<HealthComponent>(leaper) = {4, 4};
    world.add_component<AnimationComponent>(leaper);
    LeaperComponent& leap = world.add_component<LeaperComponent>(leaper);
    leap.state = 1;
    leap.destX = 20.f;
    leap.destY = 0.f;

    InputState in = AutoPilot_input(world, 0);
    XCTAssertTrue(in.dodge);
    XCTAssertLessThan(in.moveX, 0.f);
}

- (void)test_snake_followsLoopAndReturns {
    World world;
    EntityID snake = HazardSystem_spawn_snake(world, 0, 0, 300, 0);
    world.get_component<HazardComponent>(snake).lifetime = 60.f; // don't expire mid-test

    world.update(kFixedDt, kFixedDt);
    // Total loop ≈ 4 segments of ~192 each ≈ 770 units at 300 u/s ≈ 2.56s.
    float x0 = world.get_component<PositionComponent>(snake).x;

    advance(world, 1.0f);
    float xMid = world.get_component<PositionComponent>(snake).x;
    XCTAssertGreaterThan(xMid, x0 + 50.f, @"snake must travel outbound");

    advance(world, 1.8f); // ~2.8s total ≈ one full loop
    const auto& p = world.get_component<PositionComponent>(snake);
    XCTAssertLessThan(fabsf(p.x), 80.f, @"snake loops back near its origin");
    XCTAssertLessThan(fabsf(p.y), 130.f);
}

- (void)test_contactDamage_gatedByCooldown {
    World world;
    EntityID player = spawnPlayer(world, 0, 0);
    EntityID snake  = HazardSystem_spawn_snake(world, 0, 0, 300, 0);
    // Park the snake on the player: no path → it never moves.
    world.remove_component<PathFollowComponent>(snake);
    world.get_component<HazardComponent>(snake).lifetime = 60.f;

    advance(world, 2.0f);

    // Re-hit delay is 0.8s → at most 3 hits in 2s, far from 120 hits/sec.
    int hp = world.get_component<HealthComponent>(player).current;
    XCTAssertLessThan(hp, 10, @"standing in lava must hurt");
    XCTAssertGreaterThanOrEqual(hp, 10 - 3, @"cooldown must gate re-hits");
}

- (void)test_curseScalesLavaPoolDamage {
    World world;
    world.set_curse(1.6f);
    EntityID player = spawnPlayer(world, 0, 0);
    EntityID pool = world.defer_create();
    world.add_component<PositionComponent>(pool) = {0.f, 0.f, 0.f};
    world.add_component<HazardComponent>(pool).damage = 1;

    world.update(kFixedDt, kFixedDt);

    XCTAssertEqual(world.get_component<HealthComponent>(player).current, 8);
}

- (void)test_dodge_iFramesBlockHazard {
    World world;
    EntityID player = spawnPlayer(world, 0, 0);
    world.add_component<DodgeComponent>(player);
    EntityID snake = HazardSystem_spawn_snake(world, 0, 0, 300, 0);
    world.remove_component<PathFollowComponent>(snake);

    advance(world, 1.0f);

    XCTAssertEqual(world.get_component<HealthComponent>(player).current, 10);
}

- (void)test_lifetime_despawns {
    World world;
    EntityID snake = HazardSystem_spawn_snake(world, 0, 0, 300, 0);
    XCTAssertTrue(world.hazards().present(snake) ||
                  world.has_component<PositionComponent>(snake));

    advance(world, 6.5f); // default lifetime 6s

    XCTAssertFalse(world.has_component<PositionComponent>(snake),
                   @"snake must despawn after its lifetime");
}

- (void)test_bossChargeEnd_spawnsSnakes {
    World world;
    spawnPlayer(world, 0, -100);
    EntityID boss = world.defer_create();
    world.add_component<PositionComponent>(boss)       = {0, 300, 0};
    world.add_component<VelocityComponent>(boss)       = {0, 0, 0};
    world.add_component<FactionComponent>(boss).type   = FactionComponent::Enemy;
    world.add_component<HealthComponent>(boss)         = {12, 12};
    world.add_component<AnimationComponent>(boss);
    world.add_component<FacingComponent>(boss);
    world.add_component<EnemyAttackCooldownComponent>(boss);
    world.add_component<BossTagComponent>(boss);
    world.add_component<BossChargeComponent>(boss).timer = 0.01f;

    advance(world, 2.0f); // telegraph + charge + recover entry

    int snakes = 0;
    for (EntityID id = 0; id < world.entity_count(); ++id)
        if (world.hazards().present(id)) snakes++;
    XCTAssertEqual(snakes, 3, @"charge end must crack the floor into 3 snakes");
}

- (void)test_hazards_dontBlockRoomClear {
    // Hazards have no FactionComponent — _allEnemiesDefeated-style scans must
    // not see them as enemies.
    World world;
    EntityID snake = HazardSystem_spawn_snake(world, 0, 0, 300, 0);
    XCTAssertFalse(world.has_component<FactionComponent>(snake));
}

- (void)test_lavaLob_arcsLandsSpawnsStationaryPoolAndDamages {
    World world;
    EntityID player = spawnPlayer(world, 100.f, 0.f);
    EntityID lob = HazardSystem_spawn_lava_lob(world, 0.f, 0.f, 100.f, 0.f,
                                               1, 64.f, 0.35f);

    advance(world, 0.55f);
    XCTAssertTrue(world.lava_lobs().present(lob));
    XCTAssertFalse(world.hazards().present(lob));
    XCTAssertEqual(world.get_component<HealthComponent>(player).current, 10,
                   @"airborne lobs must not deal contact damage");
    XCTAssertEqualWithAccuracy(world.get_component<PositionComponent>(lob).x, 50.f, 2.f);

    int spawnedEvents = 0;
    for (int i = 0; i < 90 && world.lava_lobs().present(lob); ++i) {
        world.update(kFixedDt, kFixedDt);
        world.events().for_each(EventType::LavaPoolSpawned,
                                [&spawnedEvents](const Event&){ spawnedEvents++; });
    }
    XCTAssertEqual(spawnedEvents, 1);
    XCTAssertFalse(world.lava_lobs().present(lob));

    EntityID pool = kInvalidEntity;
    for (EntityID id = 0; id < world.entity_count(); ++id)
        if (world.hazards().present(id)) pool = id;
    XCTAssertNotEqual(pool, kInvalidEntity);
    XCTAssertFalse(world.paths().present(pool), @"lava pool must be stationary");
    XCTAssertEqualWithAccuracy(world.get_component<PositionComponent>(pool).x, 100.f, 0.01f);

    world.update(kFixedDt, kFixedDt);
    XCTAssertLessThan(world.get_component<HealthComponent>(player).current, 10);
    advance(world, 0.5f);
    XCTAssertFalse(world.hazards().present(pool), @"pool must despawn after lifetime");
}

- (void)test_autoPilotSteersAwayFromHazard {
    World world;
    EntityID player = spawnPlayer(world, 0.f, 0.f);
    (void)player;
    EntityID enemy = world.defer_create();
    world.add_component<PositionComponent>(enemy) = {200.f, 0.f, 0.f};
    world.add_component<FactionComponent>(enemy).type = FactionComponent::Enemy;
    world.add_component<HealthComponent>(enemy) = {2, 2};
    world.add_component<AnimationComponent>(enemy);
    EntityID lava = world.defer_create();
    world.add_component<PositionComponent>(lava) = {45.f, 0.f, 0.f};
    world.add_component<HazardComponent>(lava).radius = 80.f;

    AutoPilot_reset();
    InputState input = AutoPilot_input(world, 0);
    XCTAssertLessThan(input.moveX, 0.f, @"bot should steer away from lava in its next step");
}

@end
