#import <XCTest/XCTest.h>
#include "Simulation/World.h"
#include "Platform/InputState.h"

static constexpr float kFixedDt   = 1.0f / 120.0f;
static constexpr float kAttackDur = 1.03f;  // matches kClipDurationFallback[Attack]
static constexpr float kActiveMid = kAttackDur * 0.475f;

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

static void setAttacking(World& world, EntityID e) {
    if (!world.has_component<AnimationComponent>(e))
        world.add_component<AnimationComponent>(e);
    auto& anim = world.get_component<AnimationComponent>(e);
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

@interface KnockbackTests : XCTestCase
@end

@implementation KnockbackTests

- (void)test_hit_pushesEnemyAwayFromAttacker {
    World world;
    EntityID player = spawnPlayer(world, 0, 0, /*facing*/ 1.f, 0.f);
    setAttacking(world, player);
    EntityID enemy = spawnEnemy(world, 50, 0);
    float startX = world.get_component<PositionComponent>(enemy).x;

    world.update(kFixedDt, kFixedDt);

    XCTAssertTrue(world.has_component<KnockbackComponent>(enemy));
    const auto& kb = world.get_component<KnockbackComponent>(enemy);
    XCTAssertGreaterThan(kb.velX, 0.f, @"shove direction must point away from attacker (+X)");
    XCTAssertEqualWithAccuracy(kb.velY, 0.f, 0.001f);

    // Hit-stop freezes gameDt for a few ticks; run past it and confirm the
    // enemy actually moved away.
    for (int i = 0; i < 12; ++i) world.update(kFixedDt, kFixedDt);
    XCTAssertGreaterThan(world.get_component<PositionComponent>(enemy).x, startX);
}

- (void)test_knockback_decaysAndRemoves {
    World world;
    EntityID enemy = spawnEnemy(world, 0, 0);
    auto& kb = world.add_component<KnockbackComponent>(enemy);
    kb.velX = 480.f; kb.velY = 0.f; kb.elapsed = 0.f; kb.duration = 0.18f;

    // 0.18s at 120Hz ≈ 22 ticks; give it 30.
    for (int i = 0; i < 30; ++i) world.update(kFixedDt, kFixedDt);

    XCTAssertFalse(world.has_component<KnockbackComponent>(enemy),
                   @"component must remove itself after duration");
    const auto& vel = world.get_component<VelocityComponent>(enemy);
    XCTAssertEqualWithAccuracy(vel.vx, 0.f, 0.001f, @"velocity released to zero");
}

- (void)test_velocityDecaysOverDuration {
    World world;
    EntityID enemy = spawnEnemy(world, 0, 0);
    auto& kb = world.add_component<KnockbackComponent>(enemy);
    kb.velX = 480.f; kb.velY = 0.f; kb.elapsed = 0.f; kb.duration = 0.18f;

    world.update(kFixedDt, kFixedDt);
    float vEarly = world.get_component<VelocityComponent>(enemy).vx;
    for (int i = 0; i < 10; ++i) world.update(kFixedDt, kFixedDt);
    float vLate = world.get_component<VelocityComponent>(enemy).vx;

    XCTAssertGreaterThan(vEarly, 0.f);
    XCTAssertLessThan(vLate, vEarly, @"shove must decelerate over time");
}

- (void)test_boss_getsReducedKnockback {
    World world;
    EntityID player = spawnPlayer(world, 0, 0, 1.f, 0.f);
    setAttacking(world, player);
    EntityID boss = spawnEnemy(world, 50, 0, /*hp=*/12);
    world.add_component<BossTagComponent>(boss);

    world.update(kFixedDt, kFixedDt);

    XCTAssertTrue(world.has_component<KnockbackComponent>(boss));
    const auto& kb = world.get_component<KnockbackComponent>(boss);
    XCTAssertEqualWithAccuracy(kb.velX, 480.f * 0.25f, 0.5f,
                               @"boss shove is 25%% of normal");
}

- (void)test_player_neverKnockedBack {
    World world;
    // Enemy attacks the player.
    EntityID enemy = spawnEnemy(world, 0, 0);
    world.add_component<FacingComponent>(enemy) = {1.f, 0.f};
    setAttacking(world, enemy);
    EntityID player = spawnPlayer(world, 50, 0);

    world.update(kFixedDt, kFixedDt);

    XCTAssertLessThan(world.get_component<HealthComponent>(player).current, 10,
                      @"sanity: the enemy's attack must actually land");
    XCTAssertFalse(world.has_component<KnockbackComponent>(player),
                   @"players stay mobile — no knockback");
}

- (void)test_killingBlow_noSlideDuringDeathAnim {
    World world;
    EntityID player = spawnPlayer(world, 0, 0, 1.f, 0.f);
    setAttacking(world, player);
    EntityID enemy = spawnEnemy(world, 50, 0, /*hp=*/1); // killing blow

    world.update(kFixedDt, kFixedDt);
    XCTAssertTrue(world.get_component<AnimationComponent>(enemy).dying);
    float xAtDeath = world.get_component<PositionComponent>(enemy).x;

    for (int i = 0; i < 60; ++i) world.update(kFixedDt, kFixedDt);

    XCTAssertEqualWithAccuracy(world.get_component<PositionComponent>(enemy).x,
                               xAtDeath, 0.01f,
                               @"corpse must not slide during death animation");
}

- (void)test_wallClamp_holdsDuringKnockback {
    World world;
    EntityID enemy = spawnEnemy(world, 480, 0); // near +X wall (kRoomMaxX = 500)
    auto& kb = world.add_component<KnockbackComponent>(enemy);
    kb.velX = 480.f; kb.velY = 0.f; kb.elapsed = 0.f; kb.duration = 0.18f;

    for (int i = 0; i < 30; ++i) world.update(kFixedDt, kFixedDt);

    XCTAssertLessThanOrEqual(world.get_component<PositionComponent>(enemy).x, 500.f,
                             @"wall clamp must hold while being shoved");
}

@end
