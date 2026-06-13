#import <XCTest/XCTest.h>
#include "Simulation/World.h"
#include "Simulation/RoomBounds.h"
#include "Simulation/Systems/CombatHelpers.h"

static constexpr float kFixedDt = 1.0f / 120.0f;
static constexpr float kAttackDur = 1.03f;
static constexpr float kActiveMid = kAttackDur * 0.475f;

static void advance(World& world, int ticks) {
    for (int i = 0; i < ticks; ++i) world.update(kFixedDt, kFixedDt);
}

static EntityID spawnProjectilePlayer(World& world, float x, float y, int hp = 10) {
    EntityID e = world.defer_create();
    world.add_component<PlayerTagComponent>(e) = {true, 0};
    world.add_component<PositionComponent>(e) = {x, y, 0.f};
    world.add_component<VelocityComponent>(e) = {0.f, 0.f, 0.f};
    world.add_component<FactionComponent>(e).type = FactionComponent::Player;
    world.add_component<HealthComponent>(e) = {hp, hp};
    world.add_component<DamageCooldownComponent>(e).remaining = 0.f;
    world.add_component<AnimationComponent>(e);
    world.add_component<FacingComponent>(e);
    return e;
}

static EntityID spawnSpitter(World& world, float x, float y) {
    EntityID e = world.defer_create();
    world.add_component<PositionComponent>(e) = {x, y, 0.f};
    world.add_component<VelocityComponent>(e) = {0.f, 0.f, 0.f};
    world.add_component<FactionComponent>(e).type = FactionComponent::Enemy;
    world.add_component<HealthComponent>(e) = {2, 2};
    world.add_component<FacingComponent>(e) = {1.f, 0.f};
    world.add_component<EnemyArchetypeComponent>(e).type = (uint8_t)EnemyArchetype::Spitter;
    AnimationComponent& anim = world.add_component<AnimationComponent>(e);
    anim.currentClip = AnimClipID::Attack;
    anim.requestedClip = AnimClipID::Attack;
    anim.clipTime = kActiveMid;
    anim.looping = false;
    anim.hitApplied = false;
    return e;
}

static int projectileCount(World& world) {
    int count = 0;
    for (EntityID id = 0; id < world.entity_count(); ++id)
        if (world.projectiles().present(id)) count++;
    return count;
}

@interface ProjectileTests : XCTestCase
@end

@implementation ProjectileTests

- (void)test_rangedAttackerEmitsExactlyOneProjectilePerAttackWindow {
    World world;
    spawnProjectilePlayer(world, 300.f, 0.f);
    EntityID spitter = spawnSpitter(world, 0.f, 0.f);

    world.update(kFixedDt, kFixedDt);
    XCTAssertEqual(projectileCount(world), 1);
    world.update(kFixedDt, kFixedDt);
    XCTAssertEqual(projectileCount(world), 1);
    XCTAssertTrue(world.get_component<AnimationComponent>(spitter).hitApplied);
}

- (void)test_projectileSpeedScalesWithDifficulty {
    World world;
    world.set_difficulty(4);
    spawnProjectilePlayer(world, 300.f, 0.f);
    spawnSpitter(world, 0.f, 0.f);

    world.update(kFixedDt, kFixedDt);

    EntityID projectile = kInvalidEntity;
    for (EntityID id = 0; id < world.entity_count(); ++id)
        if (world.projectiles().present(id)) projectile = id;
    XCTAssertNotEqual(projectile, kInvalidEntity);
    XCTAssertEqualWithAccuracy(world.get_component<ProjectileComponent>(projectile).vx, 420.f * 1.14f, 0.01f);
    XCTAssertEqualWithAccuracy(world.get_component<ProjectileComponent>(projectile).vy, 0.f, 0.01f);
}

- (void)test_spitterTelegraphShortensAtObstacleAndProjectileUsesLockedAim {
    World world;
    EntityID player = spawnProjectilePlayer(world, 300.f, 0.f);
    EntityID spitter = world.defer_create();
    world.add_component<PositionComponent>(spitter) = {0.f, 0.f, 0.f};
    world.add_component<VelocityComponent>(spitter) = {0.f, 0.f, 0.f};
    world.add_component<FactionComponent>(spitter).type = FactionComponent::Enemy;
    world.add_component<HealthComponent>(spitter) = {2, 2};
    world.add_component<FacingComponent>(spitter);
    world.add_component<EnemyAttackCooldownComponent>(spitter);
    world.add_component<EnemyArchetypeComponent>(spitter).type = (uint8_t)EnemyArchetype::Spitter;
    world.add_component<AnimationComponent>(spitter);
    EntityID obstacle = world.defer_create();
    world.add_component<PositionComponent>(obstacle) = {100.f, 0.f, 0.f};
    world.add_component<ObstacleComponent>(obstacle) = {10.f, 40.f};

    world.update(kFixedDt, kFixedDt);

    XCTAssertTrue(world.telegraph_lines().present(spitter));
    TelegraphLineComponent line = world.get_component<TelegraphLineComponent>(spitter);
    XCTAssertEqualWithAccuracy(line.x2, 80.f, 0.01f);
    XCTAssertEqualWithAccuracy(line.y2, 0.f, 0.01f);
    XCTAssertEqualWithAccuracy(line.aimX, 1.f, 0.01f);
    XCTAssertEqualWithAccuracy(line.aimY, 0.f, 0.01f);

    world.get_component<PositionComponent>(player) = {0.f, 300.f, 0.f};
    AnimationComponent& anim = world.get_component<AnimationComponent>(spitter);
    anim.currentClip = AnimClipID::Attack;
    anim.requestedClip = AnimClipID::Attack;
    anim.clipTime = kActiveMid;
    anim.looping = false;
    anim.hitApplied = false;

    world.update(kFixedDt, kFixedDt);

    XCTAssertFalse(world.telegraph_lines().present(spitter));
    EntityID projectile = kInvalidEntity;
    for (EntityID id = 0; id < world.entity_count(); ++id)
        if (world.projectiles().present(id)) projectile = id;
    XCTAssertNotEqual(projectile, kInvalidEntity);
    XCTAssertEqualWithAccuracy(world.get_component<ProjectileComponent>(projectile).vx, 420.f, 0.01f);
    XCTAssertEqualWithAccuracy(world.get_component<ProjectileComponent>(projectile).vy, 0.f, 0.01f);
}

- (void)test_spitterTelegraphRemovedWhenKilledMidWindup {
    World world;
    spawnProjectilePlayer(world, 300.f, 0.f);
    EntityID spitter = world.defer_create();
    world.add_component<PositionComponent>(spitter) = {0.f, 0.f, 0.f};
    world.add_component<VelocityComponent>(spitter) = {0.f, 0.f, 0.f};
    world.add_component<FactionComponent>(spitter).type = FactionComponent::Enemy;
    world.add_component<HealthComponent>(spitter) = {2, 2};
    world.add_component<FacingComponent>(spitter);
    world.add_component<EnemyAttackCooldownComponent>(spitter);
    world.add_component<EnemyArchetypeComponent>(spitter).type = (uint8_t)EnemyArchetype::Spitter;
    world.add_component<AnimationComponent>(spitter);

    world.update(kFixedDt, kFixedDt);
    XCTAssertTrue(world.telegraph_lines().present(spitter));

    Combat_apply_death(world, spitter);

    XCTAssertFalse(world.telegraph_lines().present(spitter));
}

- (void)test_projectileTravelsDeterministicallyAndDamagesPlayer {
    World world;
    EntityID player = spawnProjectilePlayer(world, 42.f, 0.f);
    EntityID p = world.defer_create();
    world.add_component<PositionComponent>(p) = {0.f, 0.f, 0.f};
    world.add_component<ProjectileComponent>(p) = {420.f, 0.f, 1, 2.5f};

    advance(world, 12);

    XCTAssertFalse(world.projectiles().present(p));
    XCTAssertEqual(world.get_component<HealthComponent>(player).current, 9);
    XCTAssertGreaterThan(world.get_component<DamageCooldownComponent>(player).remaining, 0.f);
}

- (void)test_projectileRespectsDodgeIFramesAndDamageCooldown {
    World dodgeWorld;
    EntityID dodger = spawnProjectilePlayer(dodgeWorld, 10.f, 0.f);
    dodgeWorld.add_component<DodgeComponent>(dodger);
    EntityID p1 = dodgeWorld.defer_create();
    dodgeWorld.add_component<PositionComponent>(p1) = {0.f, 0.f, 0.f};
    dodgeWorld.add_component<ProjectileComponent>(p1) = {420.f, 0.f, 1, 2.5f};
    advance(dodgeWorld, 4);
    XCTAssertEqual(dodgeWorld.get_component<HealthComponent>(dodger).current, 10);

    World cooldownWorld;
    EntityID cooled = spawnProjectilePlayer(cooldownWorld, 10.f, 0.f);
    cooldownWorld.get_component<DamageCooldownComponent>(cooled).remaining = 0.5f;
    EntityID p2 = cooldownWorld.defer_create();
    cooldownWorld.add_component<PositionComponent>(p2) = {0.f, 0.f, 0.f};
    cooldownWorld.add_component<ProjectileComponent>(p2) = {420.f, 0.f, 1, 2.5f};
    advance(cooldownWorld, 4);
    XCTAssertEqual(cooldownWorld.get_component<HealthComponent>(cooled).current, 10);
}

- (void)test_projectileSecondWindWorks {
    World world;
    EntityID player = spawnProjectilePlayer(world, 10.f, 0.f, 1);
    world.add_component<StatsComponent>(player).secondWinds = 1;
    EntityID p = world.defer_create();
    world.add_component<PositionComponent>(p) = {0.f, 0.f, 0.f};
    world.add_component<ProjectileComponent>(p) = {420.f, 0.f, 1, 2.5f};

    advance(world, 4);

    XCTAssertEqual(world.get_component<HealthComponent>(player).current, 1);
    XCTAssertEqual(world.get_component<StatsComponent>(player).secondWinds, 0);
}

- (void)test_projectileDespawnsOnWallObstacleAndLifetime {
    World wallWorld;
    EntityID wall = wallWorld.defer_create();
    wallWorld.add_component<PositionComponent>(wall) = {kRoomMaxX - 1.f, 0.f, 0.f};
    wallWorld.add_component<ProjectileComponent>(wall) = {420.f, 0.f, 1, 2.5f};
    advance(wallWorld, 2);
    XCTAssertFalse(wallWorld.projectiles().present(wall));

    World obstacleWorld;
    EntityID obs = obstacleWorld.defer_create();
    obstacleWorld.add_component<PositionComponent>(obs) = {20.f, 0.f, 0.f};
    obstacleWorld.add_component<ObstacleComponent>(obs) = {10.f, 10.f};
    EntityID blocked = obstacleWorld.defer_create();
    obstacleWorld.add_component<PositionComponent>(blocked) = {0.f, 0.f, 0.f};
    obstacleWorld.add_component<ProjectileComponent>(blocked) = {420.f, 0.f, 1, 2.5f};
    advance(obstacleWorld, 6);
    XCTAssertFalse(obstacleWorld.projectiles().present(blocked));

    World lifetimeWorld;
    EntityID expiring = lifetimeWorld.defer_create();
    lifetimeWorld.add_component<PositionComponent>(expiring) = {0.f, 0.f, 0.f};
    lifetimeWorld.add_component<ProjectileComponent>(expiring) = {0.f, 0.f, 1, 0.01f};
    advance(lifetimeWorld, 2);
    XCTAssertFalse(lifetimeWorld.projectiles().present(expiring));
}

@end
