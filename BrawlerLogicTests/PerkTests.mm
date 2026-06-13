#import <XCTest/XCTest.h>
#include "Simulation/World.h"
#include "Platform/InputState.h"

static constexpr float kFixedDt   = 1.0f / 120.0f;
static constexpr float kAttackDur = 1.03f;
static constexpr float kActiveMid = kAttackDur * 0.475f;

static EntityID spawnPlayer(World& world, float x = 0.f, float y = 0.f,
                            float facingDx = 1.f, float facingDy = 0.f) {
    EntityID e = world.defer_create();
    world.add_component<PlayerTagComponent>(e) = {true, 0};
    world.add_component<PositionComponent>(e) = {x, y, 0.f};
    world.add_component<VelocityComponent>(e) = {0.f, 0.f, 0.f};
    world.add_component<FactionComponent>(e).type = FactionComponent::Player;
    world.add_component<HealthComponent>(e) = {10, 10};
    world.add_component<DamageCooldownComponent>(e).remaining = 0.f;
    world.add_component<FacingComponent>(e) = {facingDx, facingDy};
    world.add_component<AnimationComponent>(e);
    return e;
}

static EntityID spawnEnemy(World& world, float x, float y, int hp = 5,
                           float facingDx = -1.f, float facingDy = 0.f) {
    EntityID e = world.defer_create();
    world.add_component<PositionComponent>(e) = {x, y, 0.f};
    world.add_component<VelocityComponent>(e) = {0.f, 0.f, 0.f};
    world.add_component<FactionComponent>(e).type = FactionComponent::Enemy;
    world.add_component<HealthComponent>(e) = {hp, hp};
    world.add_component<FacingComponent>(e) = {facingDx, facingDy};
    world.add_component<AnimationComponent>(e);
    return e;
}

static void setAttacking(World& world, EntityID e) {
    auto& anim = world.get_component<AnimationComponent>(e);
    anim.currentClip = AnimClipID::Attack;
    anim.requestedClip = AnimClipID::Attack;
    anim.clipTime = kActiveMid;
    anim.looping = false;
    anim.hitApplied = false;
}

static int countEvents(World& world, EventType type) {
    int count = 0;
    world.events().for_each(type, [&count](const Event&){ ++count; });
    return count;
}

@interface PerkTests : XCTestCase
@end

@implementation PerkTests

- (void)test_knockbackMult_scalesPunchKnockback {
    World world;
    EntityID player = spawnPlayer(world);
    world.add_component<StatsComponent>(player).knockbackMult = 1.3f;
    EntityID enemy = spawnEnemy(world, 50.f, 0.f, 5);
    setAttacking(world, player);

    world.update(kFixedDt, kFixedDt);

    XCTAssertTrue(world.has_component<KnockbackComponent>(enemy));
    XCTAssertEqualWithAccuracy(world.get_component<KnockbackComponent>(enemy).velX,
                               480.f * 1.3f, 0.01f);
}

- (void)test_specialChargeMult_scalesMeterGain {
    World world;
    EntityID player = spawnPlayer(world);
    world.add_component<SpecialMeterComponent>(player).charge = 0.f;
    world.add_component<StatsComponent>(player).specialChargeMult = 1.5f;
    spawnEnemy(world, 50.f, 0.f, 5);
    setAttacking(world, player);

    world.update(kFixedDt, kFixedDt);

    XCTAssertEqualWithAccuracy(world.get_component<SpecialMeterComponent>(player).charge,
                               0.225f, 0.001f);
}

- (void)test_lifesteal_healsAfterConfiguredHitCount {
    World world;
    EntityID player = spawnPlayer(world);
    world.get_component<HealthComponent>(player) = {5, 10};
    world.add_component<StatsComponent>(player).lifestealPerHits = 3;
    spawnEnemy(world, 50.f, 0.f, 20);

    for (int hit = 0; hit < 3; ++hit) {
        setAttacking(world, player);
        world.update(kFixedDt, kFixedDt);
        for (int i = 0; i < 5; ++i) world.update(kFixedDt, kFixedDt);
    }

    XCTAssertEqual(world.get_component<HealthComponent>(player).current, 6);
    XCTAssertEqual(world.get_component<StatsComponent>(player).hitsSinceHeal, 0);
}

- (void)test_thorns_damagesMeleeAttacker {
    World world;
    EntityID player = spawnPlayer(world, 50.f, 0.f);
    world.add_component<StatsComponent>(player).thorns = true;
    EntityID enemy = spawnEnemy(world, 0.f, 0.f, 5, 1.f, 0.f);
    setAttacking(world, enemy);

    world.update(kFixedDt, kFixedDt);

    XCTAssertEqual(world.get_component<HealthComponent>(enemy).current, 4);
}

- (void)test_whirlwind_hitsEnemyBehindPlayer {
    World world;
    EntityID player = spawnPlayer(world, 0.f, 0.f, 1.f, 0.f);
    world.add_component<StatsComponent>(player).whirlwind = true;
    EntityID enemy = spawnEnemy(world, -50.f, 0.f, 5);
    setAttacking(world, player);

    world.update(kFixedDt, kFixedDt);

    XCTAssertEqual(world.get_component<HealthComponent>(enemy).current, 4);
}

- (void)test_passiveSpecial_risesWithoutHits {
    World world;
    EntityID player = spawnPlayer(world);
    world.add_component<SpecialMeterComponent>(player).charge = 0.f;
    world.add_component<StatsComponent>(player).passiveSpecial = true;

    for (int i = 0; i < 60; ++i)
        world.update(kFixedDt, kFixedDt);

    XCTAssertGreaterThan(world.get_component<SpecialMeterComponent>(player).charge, 0.025f);
}

- (void)test_dodgeCooldownMult_shortensDodgeRecovery {
    auto ticksUntilDodgeEnds = [](float cooldownMult) {
        World world;
        EntityID player = spawnPlayer(world);
        if (cooldownMult != 1.f)
            world.add_component<StatsComponent>(player).dodgeCooldownMult = cooldownMult;

        InputState dodge{};
        dodge.dodge = true;
        world.set_input(dodge, 0);
        world.update(kFixedDt, kFixedDt);
        world.set_input(InputState{}, 0);

        for (int i = 0; i < 240; ++i) {
            world.update(kFixedDt, kFixedDt);
            const auto& anim = world.get_component<AnimationComponent>(player);
            if (anim.currentClip != AnimClipID::Dodge &&
                !world.has_component<DodgeComponent>(player))
                return i;
        }
        return 240;
    };

    int baseTicks = ticksUntilDodgeEnds(1.f);
    int quickTicks = ticksUntilDodgeEnds(0.7f);
    XCTAssertLessThan(quickTicks, baseTicks);
    XCTAssertEqualWithAccuracy((float)quickTicks / (float)baseTicks, 0.7f, 0.12f);
}

- (void)test_secondWind_savesFromMeleeOnce {
    World world;
    EntityID player = spawnPlayer(world, 50.f, 0.f);
    world.get_component<HealthComponent>(player) = {1, 10};
    world.add_component<StatsComponent>(player).secondWinds = 1;
    EntityID enemy = spawnEnemy(world, 0.f, 0.f, 5, 1.f, 0.f);
    setAttacking(world, enemy);

    world.update(kFixedDt, kFixedDt);

    XCTAssertEqual(world.get_component<HealthComponent>(player).current, 1);
    XCTAssertEqual(world.get_component<StatsComponent>(player).secondWinds, 0);
    XCTAssertFalse(world.get_component<AnimationComponent>(player).dying);
    XCTAssertEqual(countEvents(world, EventType::SecondWindUsed), 1);

    for (int i = 0; i < 5; ++i)
        world.update(kFixedDt, kFixedDt);
    setAttacking(world, enemy);
    world.update(kFixedDt, kFixedDt);

    XCTAssertTrue(world.get_component<AnimationComponent>(player).dying);
    XCTAssertEqual(countEvents(world, EventType::EntityDied), 1);
}

- (void)test_secondWind_savesFromHazardDamage {
    World world;
    EntityID player = spawnPlayer(world);
    world.get_component<HealthComponent>(player) = {1, 10};
    world.add_component<StatsComponent>(player).secondWinds = 1;
    EntityID lava = world.defer_create();
    world.add_component<PositionComponent>(lava) = {0.f, 0.f, 0.f};
    world.add_component<HazardComponent>(lava).radius = 80.f;

    world.update(kFixedDt, kFixedDt);

    XCTAssertEqual(world.get_component<HealthComponent>(player).current, 1);
    XCTAssertEqual(world.get_component<StatsComponent>(player).secondWinds, 0);
    XCTAssertFalse(world.get_component<AnimationComponent>(player).dying);
    XCTAssertEqual(countEvents(world, EventType::SecondWindUsed), 1);
}

@end
