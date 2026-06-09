#import <XCTest/XCTest.h>
#include "Simulation/World.h"
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
    return e;
}

static EntityID spawnBoss(World& world, float x, float y, float idleTimer) {
    EntityID e = world.defer_create();
    world.add_component<PositionComponent>(e)       = {x, y, 0};
    world.add_component<VelocityComponent>(e)       = {0, 0, 0};
    world.add_component<FactionComponent>(e).type   = FactionComponent::Enemy;
    world.add_component<HealthComponent>(e)         = {12, 12};
    world.add_component<AnimationComponent>(e);
    world.add_component<FacingComponent>(e);
    world.add_component<EnemyAttackCooldownComponent>(e);
    world.add_component<BossTagComponent>(e);
    auto& charge = world.add_component<BossChargeComponent>(e);
    charge.timer = idleTimer;
    return e;
}

@interface BossChargeTests : XCTestCase
@end

@implementation BossChargeTests

- (void)test_idleCooldown_thenTelegraph {
    World world;
    spawnPlayer(world, 0, -100);
    EntityID boss = spawnBoss(world, 0, 400, /*idle*/ 0.2f);

    advance(world, 0.3f);
    const auto& c = world.get_component<BossChargeComponent>(boss);
    XCTAssertEqual(c.state, (uint8_t)BossChargeComponent::Telegraph);
}

- (void)test_telegraph_emitsEventAndPlantsBoss {
    World world;
    spawnPlayer(world, 0, -100);
    EntityID boss = spawnBoss(world, 0, 400, kFixedDt * 0.5f); // telegraph on first tick

    world.update(kFixedDt, kFixedDt);
    int seen = 0;
    world.events().for_each(EventType::BossTelegraph, [&seen](const Event&){ seen++; });
    XCTAssertEqual(seen, 1);

    // Mid-telegraph the boss must not move.
    float y0 = world.get_component<PositionComponent>(boss).y;
    advance(world, 0.3f);
    XCTAssertEqualWithAccuracy(world.get_component<PositionComponent>(boss).y, y0, 0.01f);
}

- (void)test_charge_movesTowardStoredPlayerDirection {
    World world;
    spawnPlayer(world, 0, -100);
    EntityID boss = spawnBoss(world, 0, 400, 0.01f);

    advance(world, 0.8f); // 0.01 idle + 0.7 telegraph → charging
    const auto& c = world.get_component<BossChargeComponent>(boss);
    XCTAssertEqual(c.state, (uint8_t)BossChargeComponent::Charge);

    float y0 = world.get_component<PositionComponent>(boss).y;
    advance(world, 0.1f);
    XCTAssertLessThan(world.get_component<PositionComponent>(boss).y, y0,
                      @"boss must rush toward the player (-Y)");
}

- (void)test_charge_contactDamagesOnceThenCooldown {
    World world;
    EntityID player = spawnPlayer(world, 0, 200);
    EntityID boss   = spawnBoss(world, 0, 400, 0.01f);

    // Idle 0.01 + telegraph 0.7 + charge over 200 units at 700 u/s (~0.29s).
    advance(world, 1.1f);

    int hp = world.get_component<HealthComponent>(player).current;
    XCTAssertLessThan(hp, 10, @"charge must connect");
    XCTAssertGreaterThanOrEqual(hp, 10 - 2 - 2, @"re-hit gated by DamageCooldown");
    (void)boss;
}

- (void)test_charge_endsAtWall_thenRecovers_thenIdles {
    World world;
    spawnPlayer(world, 0, -240); // boss charges toward the bottom wall (kRoomMinY = -250)
    EntityID boss = spawnBoss(world, 0, 300, 0.01f);

    // Telegraph 0.7s + ~0.75s charge to the wall + 0.8s recover, plus
    // hit-stop pauses if the charge clips the player on the way down.
    advance(world, 3.0f);

    const auto& c = world.get_component<BossChargeComponent>(boss);
    XCTAssertEqual(c.state, (uint8_t)BossChargeComponent::Idle,
                   @"after wall slam + recover the boss returns to Idle");
    // And it must be parked near the wall, not through it.
    XCTAssertGreaterThanOrEqual(world.get_component<PositionComponent>(boss).y, -250.f);
}

- (void)test_dodgingPlayer_takesNoChargeDamage {
    World world;
    EntityID player = spawnPlayer(world, 0, 200);
    world.add_component<DodgeComponent>(player); // i-frames up
    spawnBoss(world, 0, 400, 0.01f);

    advance(world, 1.0f);

    XCTAssertEqual(world.get_component<HealthComponent>(player).current, 10,
                   @"dodge i-frames must block charge contact damage");
}

@end
