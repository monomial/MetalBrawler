#import <XCTest/XCTest.h>
#include "Simulation/Difficulty.h"
#include "Simulation/World.h"
#include "Simulation/Systems/AnimationSystem.h"
#include <math.h>

static constexpr float kFixedDt  = 1.0f / 120.0f;
static constexpr float kEps      = 1e-3f;
static constexpr float kStopRadius = 30.0f;

static EntityID spawnPlayer(World& world, float x, float y) {
    EntityID e = world.defer_create();
    world.add_component<PlayerTagComponent>(e) = {true, 0};
    world.add_component<PositionComponent>(e)         = {x, y, 0};
    world.add_component<FactionComponent>(e).type     = FactionComponent::Player;
    world.add_component<HealthComponent>(e)           = {10, 10};
    return e;
}

static EntityID spawnEnemy(World& world, float x, float y) {
    EntityID e = world.defer_create();
    world.add_component<PositionComponent>(e)        = {x, y, 0};
    world.add_component<VelocityComponent>(e)        = {0, 0, 0};
    world.add_component<FactionComponent>(e).type    = FactionComponent::Enemy;
    world.add_component<HealthComponent>(e)          = {3, 3};
    return e;
}

@interface EnemyAITests : XCTestCase
@end

@implementation EnemyAITests

- (void)test_difficultyHelpers_matchDesignValuesAndClamps {
    XCTAssertEqualWithAccuracy(Difficulty_cooldown_mult(0), 1.f, kEps);
    XCTAssertEqualWithAccuracy(Difficulty_speed_mult(0), 1.f, kEps);
    XCTAssertEqualWithAccuracy(Difficulty_projectile_mult(0), 1.f, kEps);
    XCTAssertEqualWithAccuracy(Difficulty_leaper_telegraph(0), 0.9f, kEps);
    XCTAssertEqualWithAccuracy(Difficulty_leap_duration(0), 0.4f, kEps);
    XCTAssertEqualWithAccuracy(Difficulty_reinforce_mult(0), 1.f, kEps);

    XCTAssertEqualWithAccuracy(Difficulty_cooldown_mult(4), 0.72f, kEps);
    XCTAssertEqualWithAccuracy(Difficulty_speed_mult(4), 1.12f, kEps);
    XCTAssertEqualWithAccuracy(Difficulty_projectile_mult(4), 1.14f, kEps);
    XCTAssertEqualWithAccuracy(Difficulty_leaper_telegraph(4), 0.72f, kEps);
    XCTAssertEqualWithAccuracy(Difficulty_leap_duration(4), 0.34f, kEps);
    XCTAssertEqualWithAccuracy(Difficulty_reinforce_mult(4), 0.80f, kEps);

    XCTAssertEqualWithAccuracy(Difficulty_cooldown_mult(100), 0.45f, kEps);
    XCTAssertEqualWithAccuracy(Difficulty_speed_mult(100), 1.25f, kEps);
    XCTAssertEqualWithAccuracy(Difficulty_projectile_mult(100), 1.30f, kEps);
    XCTAssertEqualWithAccuracy(Difficulty_leaper_telegraph(100), 0.55f, kEps);
    XCTAssertEqualWithAccuracy(Difficulty_leap_duration(100), 0.30f, kEps);
    XCTAssertEqualWithAccuracy(Difficulty_reinforce_mult(100), 0.60f, kEps);
}

- (void)test_enemy_movesCloserToPlayer {
    World world;
    spawnPlayer(world, 0, 0);
    EntityID enemy = spawnEnemy(world, 400, 0);

    float startX = world.get_component<PositionComponent>(enemy).x;
    world.update(kFixedDt, kFixedDt);
    float endX = world.get_component<PositionComponent>(enemy).x;

    XCTAssertLessThan(endX, startX); // moved left toward player at origin
}

- (void)test_enemy_approachesAlongCorrectAxis {
    World world;
    spawnPlayer(world, 0, 0);
    EntityID enemy = spawnEnemy(world, 0, 300); // directly above player

    world.update(kFixedDt, kFixedDt);

    PositionComponent pos = world.get_component<PositionComponent>(enemy);
    // Should move in -Y direction; X should be nearly unchanged.
    XCTAssertLessThan(pos.y, 300.f);
    XCTAssertEqualWithAccuracy(pos.x, 0.f, kEps);
}

- (void)test_enemy_stopsWithinStopRadius {
    World world;
    spawnPlayer(world, 0, 0);
    // Place enemy exactly at stop radius — it should not move.
    EntityID enemy = spawnEnemy(world, kStopRadius, 0);

    world.update(kFixedDt, kFixedDt);

    // Velocity should be zero (stopped at contact range).
    VelocityComponent vel = world.get_component<VelocityComponent>(enemy);
    XCTAssertEqualWithAccuracy(vel.vx, 0.f, kEps);
    XCTAssertEqualWithAccuracy(vel.vy, 0.f, kEps);
}

- (void)test_noPlayer_doesNotCrash {
    World world;
    spawnEnemy(world, 400, 0);
    XCTAssertNoThrow(world.update(kFixedDt, kFixedDt));
}

- (void)test_multipleEnemies_allMoveTowardPlayer {
    World world;
    spawnPlayer(world, 0, 0);
    EntityID e1 = spawnEnemy(world,  400,    0);
    EntityID e2 = spawnEnemy(world, -400,    0);
    EntityID e3 = spawnEnemy(world,    0,  400);

    world.update(kFixedDt, kFixedDt);

    XCTAssertLessThan(world.get_component<PositionComponent>(e1).x,  400.f); // moved left
    XCTAssertGreaterThan(world.get_component<PositionComponent>(e2).x, -400.f); // moved right
    XCTAssertLessThan(world.get_component<PositionComponent>(e3).y,  400.f); // moved down
}

- (void)test_hitStop_enemyDoesNotMove {
    World world;
    spawnPlayer(world, 0, 0);
    EntityID enemy = spawnEnemy(world, 400, 0);

    world.trigger_hit_stop(4);
    world.update(4 * kFixedDt, kFixedDt);

    // All 4 ticks had gameDt=0 — enemy should not have moved.
    float x = world.get_component<PositionComponent>(enemy).x;
    XCTAssertEqualWithAccuracy(x, 400.f, kEps);
}

// --- Archetypes ---------------------------------------------------------------

- (void)test_archetypeTable_sane {
    for (int i = 0; i < (int)EnemyArchetype::Count; ++i) {
        const EnemyArchetypeDef& d = kEnemyArchetypes[i];
        XCTAssertGreaterThan(d.moveSpeed, 0.f);
        XCTAssertGreaterThan(d.stopRadius, 0.f);
        XCTAssertGreaterThan(d.attackCooldown, 0.f);
        XCTAssertGreaterThan(d.maxHP, 0);
        XCTAssertGreaterThan(d.scale, 0.f);
        XCTAssertGreaterThanOrEqual(d.knockbackScale, 0.f);
    }
    // Grunt row must equal the EnemyAISystem fallback constants so entities
    // without the component behave identically.
    XCTAssertEqual(kEnemyArchetypes[0].moveSpeed, 150.f);
    XCTAssertEqual(kEnemyArchetypes[0].stopRadius, 110.f);
    XCTAssertEqual(kEnemyArchetypes[0].attackCooldown, 2.f);
    XCTAssertEqual(kEnemyArchetypes[(int)EnemyArchetype::Grunt].maxHP, 4);
    XCTAssertEqual(kEnemyArchetypes[(int)EnemyArchetype::Rusher].maxHP, 3);
    XCTAssertEqual(kEnemyArchetypes[(int)EnemyArchetype::Heavy].maxHP, 10);
    XCTAssertEqual(kEnemyArchetypes[(int)EnemyArchetype::Boss].maxHP, 30);
    XCTAssertEqual(kEnemyArchetypes[(int)EnemyArchetype::Spitter].maxHP, 4);
    XCTAssertEqual(kEnemyArchetypes[(int)EnemyArchetype::Leaper].maxHP, 4);
}

- (void)test_rusher_closesFasterThanGrunt {
    World world;
    spawnPlayer(world, 0, 0);
    EntityID grunt  = spawnEnemy(world, 400,  200);
    EntityID rusher = spawnEnemy(world, 400, -200);
    world.add_component<EnemyArchetypeComponent>(grunt).type  = (uint8_t)EnemyArchetype::Grunt;
    world.add_component<EnemyArchetypeComponent>(rusher).type = (uint8_t)EnemyArchetype::Rusher;

    for (int i = 0; i < 60; ++i) world.update(kFixedDt, kFixedDt); // 0.5s

    float gruntX  = world.get_component<PositionComponent>(grunt).x;
    float rusherX = world.get_component<PositionComponent>(rusher).x;
    XCTAssertLessThan(rusherX, gruntX, @"rusher (260 u/s) must outrun grunt (150 u/s)");
}

- (void)test_movingRusherRequestsRunClip {
    World world;
    spawnPlayer(world, 0, 0);
    EntityID rusher = spawnEnemy(world, 400, 0);
    world.add_component<AnimationComponent>(rusher);
    world.add_component<EnemyArchetypeComponent>(rusher).type = (uint8_t)EnemyArchetype::Rusher;

    world.update(kFixedDt, kFixedDt);

    XCTAssertEqual(world.get_component<AnimationComponent>(rusher).requestedClip, AnimClipID::Run);
    XCTAssertEqual(world.get_component<AnimationComponent>(rusher).currentClip, AnimClipID::Run);
}

- (void)test_movingGruntRequestsWalkClip {
    World world;
    spawnPlayer(world, 0, 0);
    EntityID grunt = spawnEnemy(world, 400, 0);
    world.add_component<AnimationComponent>(grunt);
    world.add_component<EnemyArchetypeComponent>(grunt).type = (uint8_t)EnemyArchetype::Grunt;

    world.update(kFixedDt, kFixedDt);

    XCTAssertEqual(world.get_component<AnimationComponent>(grunt).requestedClip, AnimClipID::Walk);
    XCTAssertEqual(world.get_component<AnimationComponent>(grunt).currentClip, AnimClipID::Walk);
}

- (void)test_heavy_barelyKnockedBack {
    World world;
    EntityID player = spawnPlayer(world, 0, 0);
    if (!world.has_component<FacingComponent>(player))
        world.add_component<FacingComponent>(player) = {1.f, 0.f};
    else
        world.get_component<FacingComponent>(player) = {1.f, 0.f};
    if (!world.has_component<AnimationComponent>(player))
        world.add_component<AnimationComponent>(player);
    auto& anim = world.get_component<AnimationComponent>(player);
    anim.currentClip = anim.requestedClip = AnimClipID::Attack;
    anim.clipTime    = 1.03f * 0.475f;
    anim.looping     = false;
    anim.hitApplied  = false;

    EntityID heavy = spawnEnemy(world, 50, 0);
    world.add_component<HealthComponent>(heavy) = {10, 10};
    world.add_component<EnemyArchetypeComponent>(heavy).type = (uint8_t)EnemyArchetype::Heavy;

    world.update(kFixedDt, kFixedDt);

    XCTAssertTrue(world.has_component<KnockbackComponent>(heavy));
    const auto& kb = world.get_component<KnockbackComponent>(heavy);
    XCTAssertEqualWithAccuracy(kb.velX, 480.f * 0.3f, 0.5f,
                               @"heavy takes 30%% knockback per the archetype table");
}

- (void)test_enemyInRangeReadyCooldownStartsWindupBeforeAttackClip {
    World world;
    spawnPlayer(world, 0, 0);
    EntityID enemy = spawnEnemy(world, 50, 0);
    world.add_component<AnimationComponent>(enemy);
    world.add_component<EnemyAttackCooldownComponent>(enemy) = {0.f, 0.f};

    world.update(kFixedDt, kFixedDt);

    const auto& cd = world.get_component<EnemyAttackCooldownComponent>(enemy);
    XCTAssertGreaterThan(cd.windup, 0.f);
    XCTAssertEqual(world.get_component<AnimationComponent>(enemy).currentClip,
                   AnimClipID::Idle);
    XCTAssertEqual(world.get_component<AnimationComponent>(enemy).requestedClip,
                   AnimClipID::Idle);
}

- (void)test_difficultyScalesEnemyCooldownAndMoveSpeed {
    World world;
    world.set_difficulty(4);
    spawnPlayer(world, 0, 0);
    EntityID enemy = spawnEnemy(world, 50, 0);
    world.add_component<AnimationComponent>(enemy);
    world.add_component<EnemyAttackCooldownComponent>(enemy) = {0.f, 0.f};
    world.add_component<EnemyArchetypeComponent>(enemy).type = (uint8_t)EnemyArchetype::Grunt;

    world.update(kFixedDt, kFixedDt);

    const auto& cd = world.get_component<EnemyAttackCooldownComponent>(enemy);
    XCTAssertEqualWithAccuracy(cd.remaining,
                               enemy_archetype_def((uint8_t)EnemyArchetype::Grunt).attackCooldown * 0.72f,
                               kEps);

    World speedWorld;
    speedWorld.set_difficulty(4);
    spawnPlayer(speedWorld, 0, 0);
    EntityID mover = spawnEnemy(speedWorld, 400, 0);
    speedWorld.add_component<EnemyArchetypeComponent>(mover).type = (uint8_t)EnemyArchetype::Grunt;
    speedWorld.update(kFixedDt, kFixedDt);
    XCTAssertEqualWithAccuracy(speedWorld.get_component<VelocityComponent>(mover).vx, -168.f, kEps);
}

- (void)test_difficultyScalesLeaperTelegraphLeapAndCooldownWithTelegraphFloor {
    World world;
    world.set_difficulty(4);
    spawnPlayer(world, 0, 0);
    EntityID leaper = spawnEnemy(world, 0, 300);
    world.add_component<AnimationComponent>(leaper);
    world.add_component<EnemyArchetypeComponent>(leaper).type = (uint8_t)EnemyArchetype::Leaper;
    world.add_component<LeaperComponent>(leaper);

    world.update(kFixedDt, kFixedDt);
    LeaperComponent& leap = world.get_component<LeaperComponent>(leaper);
    XCTAssertEqual(leap.state, 1);
    XCTAssertEqualWithAccuracy(leap.timer, Difficulty_leaper_telegraph(4), kEps);

    leap.timer = 0.f;
    world.update(kFixedDt, kFixedDt);
    XCTAssertEqual(leap.state, 2);
    float startY = world.get_component<PositionComponent>(leaper).y;
    float destX = leap.destX;
    float destY = leap.destY;
    for (int i = 0; i < 42; ++i) world.update(kFixedDt, kFixedDt);
    XCTAssertEqual(leap.state, 3);
    XCTAssertEqualWithAccuracy(world.get_component<PositionComponent>(leaper).x, destX, 0.01f);
    XCTAssertEqualWithAccuracy(world.get_component<PositionComponent>(leaper).y, destY, 0.01f);
    XCTAssertGreaterThan(fabsf(startY - destY), 0.01f);

    leap.timer = 0.f;
    world.update(kFixedDt, kFixedDt);
    XCTAssertEqual(leap.state, 0);
    XCTAssertEqualWithAccuracy(leap.cooldown, 4.f * Difficulty_cooldown_mult(4), kEps);
    XCTAssertGreaterThanOrEqual(Difficulty_leaper_telegraph(100), 0.55f);
}

- (void)test_enemyStandsStillDuringWindup {
    World world;
    spawnPlayer(world, 0, 0);
    EntityID enemy = spawnEnemy(world, 50, 0);
    world.add_component<AnimationComponent>(enemy);
    world.add_component<EnemyAttackCooldownComponent>(enemy) = {1.5f, 0.2f};

    world.update(kFixedDt, kFixedDt);

    VelocityComponent vel = world.get_component<VelocityComponent>(enemy);
    XCTAssertEqualWithAccuracy(vel.vx, 0.f, kEps);
    XCTAssertEqualWithAccuracy(vel.vy, 0.f, kEps);
}

- (void)test_enemyRequestsAttackAfterWindup {
    World world;
    spawnPlayer(world, 0, 0);
    EntityID enemy = spawnEnemy(world, 50, 0);
    world.add_component<AnimationComponent>(enemy);
    world.add_component<EnemyAttackCooldownComponent>(enemy) = {1.5f, 0.35f};

    for (int i = 0; i < 42; ++i) world.update(kFixedDt, kFixedDt);

    XCTAssertEqual(world.get_component<EnemyAttackCooldownComponent>(enemy).windup, 0.f);
    XCTAssertEqual(world.get_component<AnimationComponent>(enemy).requestedClip,
                   AnimClipID::Attack);
    XCTAssertEqual(world.get_component<AnimationComponent>(enemy).currentClip,
                   AnimClipID::Attack);
}

- (void)test_enemyAttackCooldownStillEnforcedBetweenAttacks {
    World world;
    spawnPlayer(world, 0, 0);
    EntityID enemy = spawnEnemy(world, 50, 0);
    auto& anim = world.add_component<AnimationComponent>(enemy);
    auto& cd = world.add_component<EnemyAttackCooldownComponent>(enemy);
    cd.remaining = 0.f;
    cd.windup = 0.f;

    world.update(kFixedDt, kFixedDt);
    XCTAssertGreaterThan(cd.windup, 0.f);
    XCTAssertGreaterThan(cd.remaining, 0.f);

    cd.windup = 0.f;
    anim.requestedClip = AnimClipID::Idle;
    anim.currentClip = AnimClipID::Idle;

    world.update(kFixedDt, kFixedDt);

    XCTAssertEqual(cd.windup, 0.f);
    XCTAssertEqual(anim.requestedClip, AnimClipID::Idle);
    XCTAssertGreaterThan(cd.remaining, 0.f);
}

@end
