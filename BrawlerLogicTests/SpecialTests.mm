#import <XCTest/XCTest.h>
#include "Simulation/World.h"
#include "Platform/InputState.h"

static constexpr float kFixedDt     = 1.0f / 120.0f;
static constexpr float kAttackDur   = 1.03f;
static constexpr float kActiveMid   = kAttackDur * 0.475f;

static EntityID spawnPlayer(World& world, float x = 0, float y = 0,
                            float facingDx = 1.f, float facingDy = 0.f) {
    EntityID e = world.defer_create();
    world.add_component<PlayerTagComponent>(e) = {true, 0};
    world.add_component<PositionComponent>(e)         = {x, y, 0};
    world.add_component<FactionComponent>(e).type     = FactionComponent::Player;
    world.add_component<HealthComponent>(e)           = {10, 10};
    world.add_component<FacingComponent>(e)           = {facingDx, facingDy};
    return e;
}

static void setPlayerAttacking(World& world, EntityID player) {
    if (!world.has_component<AnimationComponent>(player))
        world.add_component<AnimationComponent>(player);
    auto& anim = world.get_component<AnimationComponent>(player);
    anim.currentClip   = AnimClipID::Attack;
    anim.requestedClip = AnimClipID::Attack;
    anim.clipTime      = kActiveMid;
    anim.looping       = false;
    anim.hitApplied    = false;
}

static EntityID spawnEnemy(World& world, float x, float y, int hp = 3) {
    EntityID e = world.defer_create();
    world.add_component<PositionComponent>(e)       = {x, y, 0};
    world.add_component<VelocityComponent>(e)       = {0, 0, 0};
    world.add_component<FactionComponent>(e).type   = FactionComponent::Enemy;
    world.add_component<HealthComponent>(e)         = {hp, hp};
    world.add_component<AnimationComponent>(e);
    return e;
}

static void pressSpecial(World& world) {
    InputState input{};
    input.special = true;
    world.set_input(input, 0);
}

@interface SpecialTests : XCTestCase
@end

@implementation SpecialTests

- (void)test_meterChargesPerLandedPlayerHitAndClamps {
    World world;
    EntityID player = spawnPlayer(world, 0, 0, 1.f, 0.f);
    world.add_component<SpecialMeterComponent>(player).charge = 0.f;
    setPlayerAttacking(world, player);
    spawnEnemy(world, 50, 0, 5);

    world.update(kFixedDt, kFixedDt);

    XCTAssertEqualWithAccuracy(world.get_component<SpecialMeterComponent>(player).charge,
                               0.15f, 0.001f);

    World clampWorld;
    EntityID clampPlayer = spawnPlayer(clampWorld, 0, 0, 1.f, 0.f);
    clampWorld.add_component<SpecialMeterComponent>(clampPlayer).charge = 0.9f;
    setPlayerAttacking(clampWorld, clampPlayer);
    spawnEnemy(clampWorld, 50, 20, 5);
    spawnEnemy(clampWorld, 50, -20, 5);

    clampWorld.update(kFixedDt, kFixedDt);

    XCTAssertEqualWithAccuracy(clampWorld.get_component<SpecialMeterComponent>(clampPlayer).charge,
                               1.f, 0.001f);
}

- (void)test_specialBelowFullChargeDoesNothing {
    World world;
    EntityID player = spawnPlayer(world, 0, 0);
    world.add_component<AnimationComponent>(player);
    world.add_component<SpecialMeterComponent>(player).charge = 0.99f;
    EntityID enemy = spawnEnemy(world, 50, 0, 5);
    pressSpecial(world);

    world.update(kFixedDt, kFixedDt);

    XCTAssertEqual(world.get_component<HealthComponent>(enemy).current, 5);
    XCTAssertEqualWithAccuracy(world.get_component<SpecialMeterComponent>(player).charge,
                               0.99f, 0.001f);
}

- (void)test_fullSpecialZeroesMeterAndDamagesEnemiesWithinRadius {
    World world;
    EntityID player = spawnPlayer(world, 0, 0);
    world.add_component<AnimationComponent>(player);
    world.add_component<SpecialMeterComponent>(player).charge = 1.f;
    EntityID nearA = spawnEnemy(world, 100, 0, 5);
    EntityID nearB = spawnEnemy(world, 0, -220, 5);
    EntityID far = spawnEnemy(world, 230, 0, 5);
    pressSpecial(world);

    world.update(kFixedDt, kFixedDt);

    XCTAssertEqualWithAccuracy(world.get_component<SpecialMeterComponent>(player).charge,
                               0.f, 0.001f);
    XCTAssertEqual(world.get_component<HealthComponent>(nearA).current, 3);
    XCTAssertEqual(world.get_component<HealthComponent>(nearB).current, 3);
    XCTAssertEqual(world.get_component<HealthComponent>(far).current, 5);
}

- (void)test_fullSpecialKnocksBackSurvivorsButNotKilledEnemies {
    World world;
    world.set_seed(4096);
    EntityID player = spawnPlayer(world, 0, 0);
    world.add_component<AnimationComponent>(player);
    world.add_component<SpecialMeterComponent>(player).charge = 1.f;
    EntityID survivor = spawnEnemy(world, 100, 0, 5);
    EntityID killed = spawnEnemy(world, -100, 0, 2);
    pressSpecial(world);

    world.update(kFixedDt, kFixedDt);

    XCTAssertTrue(world.has_component<KnockbackComponent>(survivor));
    XCTAssertFalse(world.has_component<KnockbackComponent>(killed));
    XCTAssertTrue(world.get_component<AnimationComponent>(killed).dying);
    XCTAssertEqual(world.get_component<AnimationComponent>(killed).requestedClip,
                   AnimClipID::Death);
}

- (void)test_damageBonusAddsToSlamDamage {
    World world;
    EntityID player = spawnPlayer(world, 0, 0);
    world.add_component<AnimationComponent>(player);
    world.add_component<SpecialMeterComponent>(player).charge = 1.f;
    world.add_component<StatsComponent>(player).damageBonus = 3;
    EntityID enemy = spawnEnemy(world, 100, 0, 8);
    pressSpecial(world);

    world.update(kFixedDt, kFixedDt);

    XCTAssertEqual(world.get_component<HealthComponent>(enemy).current, 3);
}

@end
