#import <XCTest/XCTest.h>
#import "BrawlerGameDelegate.h"
#include "Simulation/World.h"

static constexpr float kFixedDt = 1.0f / 120.0f;
static constexpr float kFrameDt = 1.0f / 60.0f;
static constexpr float kAttackDur = 1.03f;
static constexpr float kAttackMid = kAttackDur * 0.475f;

static EntityID spawnRevivePlayer(World& world, int playerIndex, float x, float y, int hp = 10) {
    EntityID e = world.defer_create();
    world.add_component<PlayerTagComponent>(e) = {true, (uint8_t)playerIndex};
    world.add_component<PositionComponent>(e) = {x, y, 0};
    world.add_component<VelocityComponent>(e) = {0, 0, 0};
    world.add_component<FactionComponent>(e).type = FactionComponent::Player;
    world.add_component<HealthComponent>(e) = {hp, hp};
    world.add_component<FacingComponent>(e) = {1.f, 0.f};
    world.add_component<AnimationComponent>(e);
    return e;
}

static EntityID spawnReviveEnemy(World& world, float x, float y, int hp = 3) {
    EntityID e = world.defer_create();
    world.add_component<PositionComponent>(e) = {x, y, 0};
    world.add_component<VelocityComponent>(e) = {0, 0, 0};
    world.add_component<FactionComponent>(e).type = FactionComponent::Enemy;
    world.add_component<HealthComponent>(e) = {hp, hp};
    world.add_component<FacingComponent>(e) = {1.f, 0.f};
    world.add_component<AnimationComponent>(e);
    return e;
}

static void setEnemyAttacking(World& world, EntityID enemy) {
    AnimationComponent& anim = world.get_component<AnimationComponent>(enemy);
    anim.currentClip = AnimClipID::Attack;
    anim.requestedClip = AnimClipID::Attack;
    anim.clipTime = kAttackMid;
    anim.looping = false;
    anim.hitApplied = false;
}

static int countEvents(World& world, EventType type) {
    int count = 0;
    world.events().for_each(type, [&count](const Event&) { count++; });
    return count;
}

@interface ReviveTests : XCTestCase
@end

@implementation ReviveTests

- (void)test_twoPlayerDeathDownsInsteadOfDying {
    World world;
    EntityID p1 = spawnRevivePlayer(world, 0, 0, 0, 1);
    spawnRevivePlayer(world, 1, 250, 0, 10);
    EntityID enemy = spawnReviveEnemy(world, -50, 0);
    setEnemyAttacking(world, enemy);

    world.update(kFixedDt, kFixedDt);

    XCTAssertTrue(world.has_component<DownedComponent>(p1));
    XCTAssertFalse(world.get_component<AnimationComponent>(p1).dying);
    XCTAssertEqual(world.get_component<HealthComponent>(p1).current, 0);
    XCTAssertEqual(countEvents(world, EventType::PlayerDowned), 1);
    XCTAssertEqual(countEvents(world, EventType::EntityDied), 0);
}

- (void)test_downedPlayerUntargetableAndInputIgnored {
    World world;
    EntityID downed = spawnRevivePlayer(world, 0, 0, 0, 0);
    world.add_component<DownedComponent>(downed);
    EntityID alive = spawnRevivePlayer(world, 1, 300, 0, 10);
    (void)alive;
    EntityID enemy = spawnReviveEnemy(world, 100, 0);

    InputState input = {};
    input.moveX = 1.f;
    input.attack = true;
    world.set_input(input, 0);
    AnimationComponent& anim = world.get_component<AnimationComponent>(downed);
    anim.currentClip = AnimClipID::Attack;
    anim.requestedClip = AnimClipID::Attack;
    anim.clipTime = kAttackMid;
    anim.looping = false;
    anim.hitApplied = false;

    world.update(kFixedDt, kFixedDt);

    XCTAssertEqualWithAccuracy(world.get_component<VelocityComponent>(downed).vx, 0.f, 0.001f);
    XCTAssertEqual(world.get_component<HealthComponent>(enemy).current, 3);
    XCTAssertGreaterThan(world.get_component<VelocityComponent>(enemy).vx, 0.f,
                         @"enemy should ignore downed P1 and chase living P2");
}

- (void)test_teammateProximityRevivesAtHalfMaxHP {
    World world;
    EntityID downed = spawnRevivePlayer(world, 0, 0, 0, 0);
    world.get_component<HealthComponent>(downed).max = 9;
    world.add_component<DownedComponent>(downed);
    spawnRevivePlayer(world, 1, 80, 0, 10);

    for (int i = 0; i < (int)(2.6f / kFixedDt) && world.has_component<DownedComponent>(downed); ++i)
        world.update(kFixedDt, kFixedDt);

    XCTAssertFalse(world.has_component<DownedComponent>(downed));
    XCTAssertEqual(world.get_component<HealthComponent>(downed).current, 5);
    XCTAssertEqual(countEvents(world, EventType::PlayerRevived), 1);
}

- (void)test_reviveProgressDecaysWhenTeammateLeaves {
    World world;
    EntityID downed = spawnRevivePlayer(world, 0, 0, 0, 0);
    world.add_component<DownedComponent>(downed).reviveProgress = 1.f;
    spawnRevivePlayer(world, 1, 250, 0, 10);

    for (int i = 0; i < (int)(1.0f / kFixedDt); ++i)
        world.update(kFixedDt, kFixedDt);

    XCTAssertEqualWithAccuracy(world.get_component<DownedComponent>(downed).reviveProgress,
                               0.5f, 0.03f);
}

- (void)test_twoPlayerTeamDefeatConsumesOneLifeAndReloadsRoom {
    BrawlerGameDelegate *d = [[BrawlerGameDelegate alloc] initHeadless];
    d.rngSeedOverride = 7;
    [d startGameWithPlayers:2];

    int maxFrames = (int)(120.f / kFrameDt);
    for (int i = 0; i < maxFrames && d.livesRemaining == 3; ++i)
        [d advanceFrame:kFrameDt];

    XCTAssertEqual(d.livesRemaining, 2);
    XCTAssertEqual(d.currentRoom, 1);
    XCTAssertEqual(d.gamePhase, BrawlerGamePhasePlaying);
}

- (void)test_soloDeathStillConsumesLifeImmediately {
    BrawlerGameDelegate *d = [[BrawlerGameDelegate alloc] initHeadless];
    d.rngSeedOverride = 7;
    [d startGameWithPlayers:1];

    int maxFrames = (int)(120.f / kFrameDt);
    for (int i = 0; i < maxFrames && d.livesRemaining == 3; ++i)
        [d advanceFrame:kFrameDt];

    XCTAssertEqual(d.livesRemaining, 2);
    XCTAssertEqual(d.currentRoom, 1);
    XCTAssertEqual(d.gamePhase, BrawlerGamePhasePlaying);
}

@end
