#import <XCTest/XCTest.h>
#include "Simulation/World.h"

static constexpr float kFixedDt   = 1.0f / 120.0f;
static constexpr float kAttackDur = 1.03f;
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

static EntityID spawnEnemy(World& world, float x, float y, int hp = 1) {
    EntityID e = world.defer_create();
    world.add_component<PositionComponent>(e)       = {x, y, 0};
    world.add_component<VelocityComponent>(e)       = {0, 0, 0};
    world.add_component<FactionComponent>(e).type   = FactionComponent::Enemy;
    world.add_component<HealthComponent>(e)         = {hp, hp};
    return e;
}

static EntityID spawnHeart(World& world, float x, float y) {
    EntityID e = world.defer_create();
    world.add_component<PositionComponent>(e) = {x, y, 0};
    world.add_component<HeartPickupComponent>(e);
    return e;
}

static int heartCount(World& world) {
    int count = 0;
    uint32_t entityCount = world.entity_count();
    for (EntityID id = 0; id < entityCount; ++id) {
        if (world.heart_pickups().present(id)) ++count;
    }
    return count;
}

@interface PickupTests : XCTestCase
@end

@implementation PickupTests

- (void)test_heartSpawnOnEnemyDeathIsDeterministicWithFixedSeed {
    auto killEnemyAndCountHearts = [](uint32_t seed) {
        World world;
        world.set_seed(seed);
        EntityID player = spawnPlayer(world, 0, 0, 1.f, 0.f);
        setPlayerAttacking(world, player);
        spawnEnemy(world, 50, 0, 1);

        world.update(kFixedDt, kFixedDt);

        return heartCount(world);
    };

    XCTAssertEqual(killEnemyAndCountHearts(1), 1);
    XCTAssertEqual(killEnemyAndCountHearts(4096), 0);
    XCTAssertEqual(killEnemyAndCountHearts(1), 1);
    XCTAssertEqual(killEnemyAndCountHearts(4096), 0);
}

- (void)test_injuredPlayerWithinRadiusHealsClampedAndDestroysHeart {
    World world;
    EntityID player = spawnPlayer(world, 0, 0);
    world.get_component<HealthComponent>(player) = {8, 10};
    EntityID heart = spawnHeart(world, 54, 0);

    world.update(kFixedDt, kFixedDt);

    XCTAssertEqual(world.get_component<HealthComponent>(player).current, 10);
    XCTAssertFalse(world.has_component<HeartPickupComponent>(heart));
    XCTAssertFalse(world.has_component<PositionComponent>(heart));
}

- (void)test_fullHealthPlayerDoesNotCollectHeart {
    World world;
    spawnPlayer(world, 0, 0);
    EntityID heart = spawnHeart(world, 0, 0);

    world.update(kFixedDt, kFixedDt);

    XCTAssertTrue(world.has_component<HeartPickupComponent>(heart));
    XCTAssertTrue(world.has_component<PositionComponent>(heart));
}

- (void)test_heartExpiresAfterEightSeconds {
    World world;
    EntityID heart = spawnHeart(world, 0, 0);

    for (int i = 0; i < 961; ++i) world.update(kFixedDt, kFixedDt);

    XCTAssertFalse(world.has_component<HeartPickupComponent>(heart));
    XCTAssertFalse(world.has_component<PositionComponent>(heart));
}

- (void)test_collectionEmitsPickupCollectedWithPlayerID {
    World world;
    EntityID player = spawnPlayer(world, 0, 0);
    world.get_component<HealthComponent>(player) = {5, 10};
    spawnHeart(world, 0, 0);

    world.update(kFixedDt, kFixedDt);

    int seen = 0;
    world.events().for_each(EventType::PickupCollected, [&seen, player](const Event& ev) {
        ++seen;
        XCTAssertEqual(ev.pickupCollected.playerID, player);
    });
    XCTAssertEqual(seen, 1);
}

@end
