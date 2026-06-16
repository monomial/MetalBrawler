#import <XCTest/XCTest.h>
#import "BrawlerGameDelegate.h"
#include "Simulation/World.h"
#include "Simulation/Systems/CombatHelpers.h"
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

- (void)test_whirlwindWidensArcButDoesNotHitBehindPlayer {
    World world;
    EntityID player = spawnPlayer(world, 0.f, 0.f, 1.f, 0.f);
    world.add_component<StatsComponent>(player).whirlwind = true;
    EntityID widenedArc = spawnEnemy(world, -20.f, 113.f, 5);
    EntityID behind = spawnEnemy(world, -50.f, 0.f, 5);
    setAttacking(world, player);

    world.update(kFixedDt, kFixedDt);

    XCTAssertEqual(world.get_component<HealthComponent>(widenedArc).current, 4);
    XCTAssertEqual(world.get_component<HealthComponent>(behind).current, 5);
}

- (void)test_passiveSpecial_risesWithoutHits {
    World world;
    EntityID player = spawnPlayer(world);
    world.add_component<SpecialMeterComponent>(player).charge = 0.f;
    world.add_component<StatsComponent>(player).passiveSpecial = true;

    for (int i = 0; i < 60; ++i)
        world.update(kFixedDt, kFixedDt);

    XCTAssertGreaterThan(world.get_component<SpecialMeterComponent>(player).charge, 0.012f);
    XCTAssertLessThan(world.get_component<SpecialMeterComponent>(player).charge, 0.020f);
}

- (void)test_dodgeCooldownMult_speedsDodgeChargeRegen {
    auto ticksUntilChargeRegens = [](float cooldownMult) {
        World world;
        EntityID player = spawnPlayer(world);
        world.add_component<StatsComponent>(player).dodgeCooldownMult = cooldownMult;
        DodgeChargesComponent& charges = world.add_component<DodgeChargesComponent>(player);
        charges.charges = 1;
        charges.maxCharges = 2;
        charges.regenTimer = 1.5f * cooldownMult;

        for (int i = 0; i < 240; ++i) {
            world.update(kFixedDt, kFixedDt);
            if (world.get_component<DodgeChargesComponent>(player).charges == 2)
                return i;
        }
        return 240;
    };

    int baseTicks = ticksUntilChargeRegens(1.f);
    int quickTicks = ticksUntilChargeRegens(0.7f);
    XCTAssertLessThan(quickTicks, baseTicks);
    XCTAssertEqualWithAccuracy((float)quickTicks / (float)baseTicks, 0.7f, 0.12f);
}

- (void)test_passiveDodgeChanceZeroDoesNotConsumeRNG {
    World control;
    World world;
    control.set_seed(12345);
    world.set_seed(12345);
    EntityID player = spawnPlayer(world);
    world.add_component<StatsComponent>(player).dodgeChance = 0.f;

    XCTAssertFalse(Combat_player_dodges_hit(world, player));
    XCTAssertEqual(world.rand_u32(), control.rand_u32());
}

- (void)test_passiveDodgeChanceUsesSeededRollAndCapsChance {
    uint32_t successSeed = 1;
    for (; successSeed < 1000; ++successSeed) {
        World probe;
        probe.set_seed(successSeed);
        if (probe.rand_float01() < 0.3f) break;
    }
    World successWorld;
    successWorld.set_seed(successSeed);
    EntityID successPlayer = spawnPlayer(successWorld);
    successWorld.add_component<StatsComponent>(successPlayer).dodgeChance = 0.3f;
    XCTAssertTrue(Combat_player_dodges_hit(successWorld, successPlayer));
    XCTAssertEqual(countEvents(successWorld, EventType::Evaded), 1);

    uint32_t cappedFailSeed = 1;
    for (; cappedFailSeed < 20000; ++cappedFailSeed) {
        World probe;
        probe.set_seed(cappedFailSeed);
        if (probe.rand_float01() >= 0.3f) break;
    }
    World cappedWorld;
    cappedWorld.set_seed(cappedFailSeed);
    EntityID cappedPlayer = spawnPlayer(cappedWorld);
    cappedWorld.add_component<StatsComponent>(cappedPlayer).dodgeChance = 1.0f;
    XCTAssertFalse(Combat_player_dodges_hit(cappedWorld, cappedPlayer));
    XCTAssertEqual(countEvents(cappedWorld, EventType::Evaded), 0);
}

- (void)test_passiveDodgeChanceBlocksProjectileHazardAndMeleeDamage {
    auto seedForDodge = []() {
        for (uint32_t seed = 1; seed < 1000; ++seed) {
            World probe;
            probe.set_seed(seed);
            if (probe.rand_float01() < 0.3f) return seed;
        }
        return (uint32_t)1;
    };

    World projectileWorld;
    projectileWorld.set_seed(seedForDodge());
    EntityID projectilePlayer = spawnPlayer(projectileWorld);
    projectileWorld.add_component<StatsComponent>(projectilePlayer).dodgeChance = 1.0f;
    EntityID projectile = projectileWorld.defer_create();
    projectileWorld.add_component<PositionComponent>(projectile) = {0.f, 0.f, 0.f};
    projectileWorld.add_component<ProjectileComponent>(projectile).damage = 3;
    projectileWorld.update(kFixedDt, kFixedDt);
    XCTAssertEqual(projectileWorld.get_component<HealthComponent>(projectilePlayer).current, 10);
    XCTAssertEqual(countEvents(projectileWorld, EventType::Evaded), 1);

    World hazardWorld;
    hazardWorld.set_seed(seedForDodge());
    EntityID hazardPlayer = spawnPlayer(hazardWorld);
    hazardWorld.add_component<StatsComponent>(hazardPlayer).dodgeChance = 1.0f;
    EntityID lava = hazardWorld.defer_create();
    hazardWorld.add_component<PositionComponent>(lava) = {0.f, 0.f, 0.f};
    hazardWorld.add_component<HazardComponent>(lava).damage = 3;
    hazardWorld.update(kFixedDt, kFixedDt);
    XCTAssertEqual(hazardWorld.get_component<HealthComponent>(hazardPlayer).current, 10);
    XCTAssertEqual(countEvents(hazardWorld, EventType::Evaded), 1);

    World meleeWorld;
    meleeWorld.set_seed(seedForDodge());
    EntityID meleePlayer = spawnPlayer(meleeWorld, 50.f, 0.f);
    meleeWorld.add_component<StatsComponent>(meleePlayer).dodgeChance = 1.0f;
    EntityID enemy = spawnEnemy(meleeWorld, 0.f, 0.f, 5, 1.f, 0.f);
    setAttacking(meleeWorld, enemy);
    meleeWorld.update(kFixedDt, kFixedDt);
    XCTAssertEqual(meleeWorld.get_component<HealthComponent>(meleePlayer).current, 10);
    XCTAssertEqual(countEvents(meleeWorld, EventType::Evaded), 1);
}

- (void)test_passiveDodgeChanceZeroTakesNormalDamage {
    World world;
    EntityID player = spawnPlayer(world);
    world.add_component<StatsComponent>(player).dodgeChance = 0.f;
    EntityID lava = world.defer_create();
    world.add_component<PositionComponent>(lava) = {0.f, 0.f, 0.f};
    world.add_component<HazardComponent>(lava).damage = 2;

    world.update(kFixedDt, kFixedDt);

    XCTAssertEqual(world.get_component<HealthComponent>(player).current, 8);
    XCTAssertEqual(countEvents(world, EventType::Evaded), 0);
}

- (void)test_dodgeChancePerkAndRelabels {
    BrawlerGameDelegate *d = [[BrawlerGameDelegate alloc] initHeadless];
    [d debugApplyPerkID:16 toPlayer:0];

    XCTAssertEqualWithAccuracy([d debugPerkDodgeChanceForPlayer:0], 0.05f, 0.001f);
    XCTAssertEqualObjects([d debugPerkLabelForID:5], @"Quick Dash");
    XCTAssertEqualObjects([d debugPerkLabelForID:15], @"Extra Dash");
    XCTAssertEqualObjects([d debugPerkLabelForID:16], @"Dodge");
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
