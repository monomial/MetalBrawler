#import <XCTest/XCTest.h>
#include "Simulation/World.h"
#include "Platform/InputState.h"

static constexpr float kFixedDt = 1.0f / 120.0f;

static EntityID spawnDodgePlayer(World& world) {
    EntityID e = world.defer_create();
    world.add_component<PlayerTagComponent>(e) = {true, 0};
    world.add_component<PositionComponent>(e) = {0.f, 0.f, 0.f};
    world.add_component<VelocityComponent>(e) = {0.f, 0.f, 0.f};
    world.add_component<FactionComponent>(e).type = FactionComponent::Player;
    world.add_component<HealthComponent>(e) = {10, 10};
    world.add_component<DamageCooldownComponent>(e).remaining = 0.f;
    world.add_component<FacingComponent>(e) = {1.f, 0.f};
    world.add_component<AnimationComponent>(e);
    world.add_component<DodgeChargesComponent>(e);
    return e;
}

static void advanceDodge(World& world, int ticks) {
    for (int i = 0; i < ticks; ++i)
        world.update(kFixedDt, kFixedDt);
}

@interface DodgeChargeTests : XCTestCase
@end

@implementation DodgeChargeTests

- (void)test_dodgeChargesStartAtBaseAndDodgeConsumesOne {
    World world;
    EntityID player = spawnDodgePlayer(world);

    XCTAssertEqual(world.get_component<DodgeChargesComponent>(player).maxCharges, 2);
    XCTAssertEqual(world.get_component<DodgeChargesComponent>(player).charges, 2);

    InputState dodge{};
    dodge.dodge = true;
    dodge.moveX = 1.f;
    world.set_input(dodge, 0);
    world.update(kFixedDt, kFixedDt);

    XCTAssertTrue(world.has_component<DodgeComponent>(player));
    XCTAssertEqual(world.get_component<DodgeChargesComponent>(player).charges, 1);
    XCTAssertGreaterThan(world.get_component<DodgeChargesComponent>(player).regenTimer, 1.4f);
}

- (void)test_dodgeDoesNothingAtZeroCharges {
    World world;
    EntityID player = spawnDodgePlayer(world);
    world.get_component<DodgeChargesComponent>(player).charges = 0;

    InputState dodge{};
    dodge.dodge = true;
    world.set_input(dodge, 0);
    world.update(kFixedDt, kFixedDt);

    XCTAssertFalse(world.has_component<DodgeComponent>(player));
    XCTAssertNotEqual(world.get_component<AnimationComponent>(player).currentClip, AnimClipID::Dodge);
}

- (void)test_dodgeChargeRegeneratesAfterBaseDuration {
    World world;
    EntityID player = spawnDodgePlayer(world);
    DodgeChargesComponent& charges = world.get_component<DodgeChargesComponent>(player);
    charges.charges = 1;
    charges.regenTimer = 1.5f;

    advanceDodge(world, 179);
    XCTAssertEqual(charges.charges, 1);
    advanceDodge(world, 2);
    XCTAssertEqual(charges.charges, 2);
    XCTAssertEqualWithAccuracy(charges.regenTimer, 0.f, 0.001f);
}

- (void)test_quickDodgeSpeedsChargeRegeneration {
    World world;
    EntityID player = spawnDodgePlayer(world);
    world.add_component<StatsComponent>(player).dodgeCooldownMult = 0.7f;
    DodgeChargesComponent& charges = world.get_component<DodgeChargesComponent>(player);
    charges.charges = 1;
    charges.regenTimer = 1.5f * 0.7f;

    advanceDodge(world, 130);
    XCTAssertEqual(charges.charges, 2);
}

- (void)test_evasionStyleBonusRaisesMaxCharge {
    World world;
    EntityID player = spawnDodgePlayer(world);
    DodgeChargesComponent& charges = world.get_component<DodgeChargesComponent>(player);
    charges.maxCharges += 1;
    charges.charges = charges.maxCharges;

    XCTAssertEqual(charges.maxCharges, 3);
    XCTAssertEqual(charges.charges, 3);
}

- (void)test_releaseAfterMinimumEndsDodgeEarly {
    World world;
    EntityID player = spawnDodgePlayer(world);
    InputState dodge{};
    dodge.dodge = true;
    dodge.moveX = 1.f;
    world.set_input(dodge, 0);
    world.update(kFixedDt, kFixedDt);

    world.set_input(InputState{}, 0);
    advanceDodge(world, 24);

    XCTAssertFalse(world.has_component<DodgeComponent>(player));
    XCTAssertEqual(world.get_component<DodgeChargesComponent>(player).charges, 1);
}

- (void)test_holdingSingleChargeEndsAtMaxDuration {
    World world;
    EntityID player = spawnDodgePlayer(world);
    DodgeChargesComponent& charges = world.get_component<DodgeChargesComponent>(player);
    charges.maxCharges = 1;
    charges.charges = 1;

    InputState dodge{};
    dodge.dodge = true;
    dodge.moveX = 1.f;
    world.set_input(dodge, 0);
    advanceDodge(world, 30);
    XCTAssertTrue(world.has_component<DodgeComponent>(player));
    advanceDodge(world, 90); // past the 0.80s max-duration window
    XCTAssertFalse(world.has_component<DodgeComponent>(player));
    XCTAssertEqual(charges.charges, 0);
}

- (void)test_holdingDodgeChainsExactlyTwoChargesThenStops {
    World world;
    EntityID player = spawnDodgePlayer(world);
    InputState dodge{};
    dodge.dodge = true;
    dodge.moveX = 1.f;
    world.set_input(dodge, 0);

    advanceDodge(world, 30);
    XCTAssertTrue(world.has_component<DodgeComponent>(player));
    XCTAssertEqual(world.get_component<DodgeChargesComponent>(player).charges, 1);
    advanceDodge(world, 90); // dash 1 (0.80s) ends and chains into dash 2
    XCTAssertTrue(world.has_component<DodgeComponent>(player));
    XCTAssertEqual(world.get_component<DodgeChargesComponent>(player).charges, 0);
    advanceDodge(world, 110); // dash 2 ends; no charges left to chain
    XCTAssertFalse(world.has_component<DodgeComponent>(player));
    XCTAssertEqual(world.get_component<DodgeChargesComponent>(player).charges, 0);
}

- (void)test_dodgeIFramesIgnoreProjectileDamage {
    World world;
    EntityID player = spawnDodgePlayer(world);
    world.add_component<DodgeComponent>(player);
    EntityID projectile = world.defer_create();
    world.add_component<PositionComponent>(projectile) = {0.f, 0.f, 0.f};
    world.add_component<ProjectileComponent>(projectile) = {0.f, 0.f, 1, 1.3f};

    world.update(kFixedDt, kFixedDt);

    XCTAssertEqual(world.get_component<HealthComponent>(player).current, 10);
}

@end
