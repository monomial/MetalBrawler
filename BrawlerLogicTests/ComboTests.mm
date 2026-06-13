#import <XCTest/XCTest.h>
#include "Simulation/World.h"
#include "Simulation/Systems/AnimationSystem.h"
#include "Platform/InputState.h"

static constexpr float kFixedDt   = 1.0f / 120.0f;
static constexpr float kAttackDur = 1.03f; // kClipDurationFallback[Attack] == [Attack2]
// Attack plays at 4× speed: wall-clock to finish ≈ 1.03/4 ≈ 0.26s ≈ 31 ticks.
static constexpr int   kAttackTicks = (int)(kAttackDur / 4.f / kFixedDt) + 2;

static EntityID spawnPlayer(World& world) {
    EntityID e = world.defer_create();
    world.add_component<PlayerTagComponent>(e) = {true, 0};
    world.add_component<PositionComponent>(e)  = {0, 0, 0};
    world.add_component<VelocityComponent>(e)  = {0, 0, 0};
    world.add_component<FactionComponent>(e).type = FactionComponent::Player;
    world.add_component<HealthComponent>(e)    = {10, 10};
    world.add_component<FacingComponent>(e)    = {1.f, 0.f};
    world.add_component<AnimationComponent>(e);
    world.add_component<ChargeAttackComponent>(e);
    return e;
}

static EntityID spawnEnemy(World& world, float x, float y, int hp) {
    EntityID e = world.defer_create();
    world.add_component<PositionComponent>(e)       = {x, y, 0};
    world.add_component<VelocityComponent>(e)       = {0, 0, 0};
    world.add_component<FactionComponent>(e).type   = FactionComponent::Enemy;
    world.add_component<HealthComponent>(e)         = {hp, hp};
    world.add_component<AnimationComponent>(e);
    return e;
}

static void setAttack(World& world, bool down) {
    InputState s = {};
    s.attack = down;
    world.set_input(s, 0);
}

static int countEvents(World& world, EventType type) {
    int count = 0;
    world.events().for_each(type, [&count](const Event&){ ++count; });
    return count;
}

@interface ComboTests : XCTestCase
@end

@implementation ComboTests

- (void)test_heldAttack_chainsIntoAttack2 {
    World world;
    EntityID player = spawnPlayer(world);

    setAttack(world, true);
    bool sawAttack2 = false;
    for (int i = 0; i < kAttackTicks * 2 && !sawAttack2; ++i) {
        world.update(kFixedDt, kFixedDt);
        sawAttack2 = world.get_component<AnimationComponent>(player).currentClip
                     == AnimClipID::Attack2;
    }
    XCTAssertTrue(sawAttack2, @"holding attack must chain Attack → Attack2");
}

- (void)test_singleTap_noChain {
    World world;
    EntityID player = spawnPlayer(world);

    // One-frame tap, then release.
    setAttack(world, true);
    world.update(kFixedDt, kFixedDt);
    setAttack(world, false);

    for (int i = 0; i < kAttackTicks * 2; ++i) {
        world.update(kFixedDt, kFixedDt);
        XCTAssertNotEqual((int)world.get_component<AnimationComponent>(player).currentClip,
                          (int)AnimClipID::Attack2,
                          @"a single early tap must not trigger the finisher");
    }
    XCTAssertEqual((int)world.get_component<AnimationComponent>(player).currentClip,
                   (int)AnimClipID::Idle, @"swing should settle back to Idle");
}

- (void)test_earlyPress_doesNotQueue {
    World world;
    EntityID player = spawnPlayer(world);

    // Press at clip start (inside the first 35%), release before the window.
    setAttack(world, true);
    world.update(kFixedDt, kFixedDt); // enters Attack, clipTime ~0
    world.update(kFixedDt, kFixedDt); // still well under 35% (~0.36s of clip time)
    setAttack(world, false);

    XCTAssertFalse(world.get_component<AnimationComponent>(player).comboQueued,
                   @"press before 35%% of the clip must not queue the combo");
}

- (void)test_finisher_dealsDoubleDamage {
    World world;
    EntityID player = spawnPlayer(world);
    EntityID enemy  = spawnEnemy(world, 50, 0, /*hp=*/9);

    // Hold attack through first swing + finisher.
    setAttack(world, true);
    int hpAfterFirst = -1;
    bool finisherDone = false;
    for (int i = 0; i < kAttackTicks * 6 && !finisherDone; ++i) {
        world.update(kFixedDt, kFixedDt);
        const auto& anim = world.get_component<AnimationComponent>(player);
        if (anim.currentClip == AnimClipID::Attack2 && hpAfterFirst < 0)
            hpAfterFirst = world.get_component<HealthComponent>(enemy).current;
        if (hpAfterFirst >= 0 && anim.currentClip != AnimClipID::Attack2)
            finisherDone = true;
    }

    XCTAssertEqual(hpAfterFirst, 8, @"first punch deals 1");
    XCTAssertEqual(world.get_component<HealthComponent>(enemy).current, 6,
                   @"finisher deals 2 (8 → 6)");
}

- (void)test_heldAttack_reachesChargeAfterPriorClipFinishes {
    World world;
    EntityID player = spawnPlayer(world);

    setAttack(world, true);
    bool ready = false;
    for (int i = 0; i < 240 && !ready; ++i) {
        world.update(kFixedDt, kFixedDt);
        ready = world.get_component<ChargeAttackComponent>(player).charging;
    }

    XCTAssertTrue(ready, @"held attack should become charged after the tap attack flow returns to idle");
    XCTAssertGreaterThanOrEqual(countEvents(world, EventType::ChargeReady), 1);
}

- (void)test_chargedRelease_hitsEnemyBehindPlayer {
    World world;
    EntityID player = spawnPlayer(world);
    EntityID enemy = spawnEnemy(world, -90.f, 0.f, 8);

    setAttack(world, true);
    for (int i = 0; i < 240 && !world.get_component<ChargeAttackComponent>(player).charging; ++i)
        world.update(kFixedDt, kFixedDt);
    setAttack(world, false);
    world.update(kFixedDt, kFixedDt);

    XCTAssertEqual(world.get_component<HealthComponent>(enemy).current, 5);
    XCTAssertGreaterThanOrEqual(countEvents(world, EventType::ChargedSlam), 1);
}

- (void)test_releaseBeforeThreshold_doesNothingSpecial {
    World world;
    EntityID player = spawnPlayer(world);
    EntityID enemy = spawnEnemy(world, -90.f, 0.f, 8);

    setAttack(world, true);
    for (int i = 0; i < 20; ++i) world.update(kFixedDt, kFixedDt);
    setAttack(world, false);
    world.update(kFixedDt, kFixedDt);

    XCTAssertEqual(world.get_component<HealthComponent>(enemy).current, 8);
    XCTAssertEqual(countEvents(world, EventType::ChargedSlam), 0);
}

- (void)test_movingMidCharge_cancels {
    World world;
    EntityID player = spawnPlayer(world);

    setAttack(world, true);
    for (int i = 0; i < 180 && !world.get_component<ChargeAttackComponent>(player).charging; ++i)
        world.update(kFixedDt, kFixedDt);
    XCTAssertTrue(world.get_component<ChargeAttackComponent>(player).charging);

    InputState moving{};
    moving.attack = true;
    moving.moveX = 1.f;
    world.set_input(moving, 0);
    world.update(kFixedDt, kFixedDt);

    XCTAssertFalse(world.get_component<ChargeAttackComponent>(player).charging);
    XCTAssertEqualWithAccuracy(world.get_component<ChargeAttackComponent>(player).held, 0.f, 0.001f);
}

- (void)test_chargedSlam_knocksBackAndHitStops {
    World world;
    EntityID player = spawnPlayer(world);
    EntityID enemy = spawnEnemy(world, 90.f, 0.f, 20);

    setAttack(world, true);
    for (int i = 0; i < 240 && !world.get_component<ChargeAttackComponent>(player).charging; ++i)
        world.update(kFixedDt, kFixedDt);
    setAttack(world, false);
    world.update(kFixedDt, kFixedDt);

    XCTAssertTrue(world.has_component<KnockbackComponent>(enemy));
    XCTAssertGreaterThan(world.get_component<KnockbackComponent>(enemy).velX, 700.f);
    int hp = world.get_component<HealthComponent>(enemy).current;
    auto& anim = world.get_component<AnimationComponent>(player);
    anim.currentClip = AnimClipID::Attack;
    anim.clipTime = kAttackDur * 0.475f;
    anim.hitApplied = false;
    world.update(kFixedDt, kFixedDt);
    XCTAssertEqual(world.get_component<HealthComponent>(enemy).current, hp,
                   @"the tick immediately after charged slam should be hit-stopped");
}

// --- StatsComponent (perk effects) -------------------------------------------

- (void)test_damageBonus_increasesPunchDamage {
    World world;
    EntityID player = spawnPlayer(world);
    world.add_component<StatsComponent>(player).damageBonus = 2;
    EntityID enemy = spawnEnemy(world, 50, 0, /*hp=*/9);

    setAttack(world, true);
    // Advance until the first punch lands (a held button would chain into the
    // finisher and double-dip, so stop at the first damage tick).
    int hp = 9;
    for (int i = 0; i < kAttackTicks * 2 && hp == 9; ++i) {
        world.update(kFixedDt, kFixedDt);
        hp = world.get_component<HealthComponent>(enemy).current;
    }

    XCTAssertEqual(hp, 9 - 3, @"1 base + 2 bonus damage per landed punch");
}

- (void)test_speedMult_movesFaster {
    World world;
    EntityID slow = spawnPlayer(world);
    World world2;
    EntityID fast = spawnPlayer(world2);
    world2.add_component<StatsComponent>(fast).speedMult = 1.4f;

    InputState right = {}; right.moveX = 1.f;
    world.set_input(right, 0);
    world2.set_input(right, 0);
    for (int i = 0; i < 60; ++i) { world.update(kFixedDt, kFixedDt); world2.update(kFixedDt, kFixedDt); }

    XCTAssertGreaterThan(world2.get_component<PositionComponent>(fast).x,
                         world.get_component<PositionComponent>(slow).x,
                         @"+40%% speed must out-distance base speed");
}

- (void)test_attack2WindowTable_nonZero {
    // Guard against the silent-zero clip-table trap: Attack2 must have a real
    // duration fallback (a zero-length clip would complete instantly).
    World world;
    EntityID player = spawnPlayer(world);
    float dur = AnimationSystem_clip_duration(world, player, AnimClipID::Attack2);
    XCTAssertGreaterThan(dur, 0.5f, @"Attack2 fallback duration missing from kClipDurationFallback");
}

@end
