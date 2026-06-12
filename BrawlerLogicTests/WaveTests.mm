#import <XCTest/XCTest.h>
#include "Simulation/World.h"
#include "Simulation/Systems/AnimationSystem.h"
#include "Simulation/Systems/CombatHelpers.h"
#include "Simulation/Systems/EnemyFactory.h"
#include "Simulation/Systems/WaveSystem.h"
#include <string>
#include <vector>

static constexpr float kFrameDt = 1.0f / 60.0f;

static void advance(World& world, float seconds) {
    int frames = (int)(seconds / kFrameDt + 0.5f);
    for (int i = 0; i < frames; ++i)
        world.update(kFrameDt, kFrameDt);
}

static EntityID spawnPlayer(World& world, float x = 0.f, float y = 0.f) {
    EntityID e = world.defer_create();
    world.add_component<PlayerTagComponent>(e) = {true, 0};
    world.add_component<PositionComponent>(e) = {x, y, 0.f};
    world.add_component<FactionComponent>(e).type = FactionComponent::Player;
    world.add_component<HealthComponent>(e) = {10, 10};
    world.add_component<FacingComponent>(e) = {1.f, 0.f};
    return e;
}

static EntityID addController(World& world, const PendingSpawn* spawns, int spawnCount,
                              int waveCount, bool bossMode = false) {
    EntityID e = world.defer_create();
    WaveControllerComponent& ctrl = world.add_component<WaveControllerComponent>(e);
    ctrl.spawnCount = spawnCount;
    ctrl.waveCount = waveCount;
    ctrl.currentWave = 0;
    ctrl.timer = kInitialWaveDelay;
    ctrl.phase = WavePhaseInitialDelay;
    ctrl.bossMode = bossMode;
    for (int i = 0; i < spawnCount; ++i)
        ctrl.spawns[i] = spawns[i];
    if (bossMode) {
        ctrl.reinforceCount = 2;
        ctrl.reinforcements[0] = {(uint8_t)EnemyArchetype::Grunt, 0, -160.f, 260.f};
        ctrl.reinforcements[1] = {(uint8_t)EnemyArchetype::Rusher, 0, 160.f, 260.f};
    }
    return e;
}

static int markerCount(World& world) {
    int count = 0;
    for (EntityID id = 0; id < world.entity_count(); ++id)
        if (world.spawn_markers().present(id)) ++count;
    return count;
}

static int enemyCount(World& world) {
    int count = 0;
    for (EntityID id = 0; id < world.entity_count(); ++id) {
        if (!world.has_component<FactionComponent>(id)) continue;
        if (world.get_component<FactionComponent>(id).type == FactionComponent::Enemy)
            ++count;
    }
    return count;
}

static int livingMinionCount(World& world) {
    int count = 0;
    for (EntityID id = 0; id < world.entity_count(); ++id) {
        if (!world.has_component<FactionComponent>(id)) continue;
        if (world.get_component<FactionComponent>(id).type != FactionComponent::Enemy) continue;
        if (world.boss_tags().present(id)) continue;
        if (!world.has_component<HealthComponent>(id)) continue;
        if (world.get_component<HealthComponent>(id).current <= 0) continue;
        if (world.has_component<AnimationComponent>(id) &&
            world.get_component<AnimationComponent>(id).dying) continue;
        ++count;
    }
    return count;
}

static EntityID firstEnemy(World& world) {
    for (EntityID id = 0; id < world.entity_count(); ++id) {
        if (!world.has_component<FactionComponent>(id)) continue;
        if (world.get_component<FactionComponent>(id).type == FactionComponent::Enemy)
            return id;
    }
    return kInvalidEntity;
}

static EntityID firstMarker(World& world) {
    for (EntityID id = 0; id < world.entity_count(); ++id) {
        if (world.spawn_markers().present(id))
            return id;
    }
    return kInvalidEntity;
}

static EntityID firstBoss(World& world) {
    for (EntityID id = 0; id < world.entity_count(); ++id)
        if (world.boss_tags().present(id)) return id;
    return kInvalidEntity;
}

static EntityID addObstacle(World& world, float x, float y, float halfW, float halfH) {
    EntityID e = world.defer_create();
    world.add_component<PositionComponent>(e) = {x, y, 0.f};
    world.add_component<ObstacleComponent>(e) = {halfW, halfH};
    return e;
}

static void markEnemyDeadForWave(World& world, EntityID id) {
    world.get_component<HealthComponent>(id).current = 0;
    if (world.has_component<AnimationComponent>(id))
        world.get_component<AnimationComponent>(id).dying = true;
}

static void setPlayerAttacking(World& world, EntityID player) {
    AnimationComponent& anim = world.has_component<AnimationComponent>(player)
        ? world.get_component<AnimationComponent>(player)
        : world.add_component<AnimationComponent>(player);
    anim.currentClip = AnimClipID::Attack;
    anim.requestedClip = AnimClipID::Attack;
    anim.clipTime = 1.03f * 0.475f;
    anim.looping = false;
    anim.hitApplied = false;
}

@interface WaveTests : XCTestCase
@end

@implementation WaveTests

- (void)test_initialDelayBeforeMarkers {
    World world;
    PendingSpawn spawns[] = {{(uint8_t)EnemyArchetype::Grunt, 0, 0.f, 300.f}};
    addController(world, spawns, 1, 1);

    advance(world, kInitialWaveDelay - 0.2f);
    XCTAssertEqual(enemyCount(world), 0);
    XCTAssertEqual(markerCount(world), 0);

    advance(world, 0.3f);
    XCTAssertEqual(enemyCount(world), 0);
    XCTAssertEqual(markerCount(world), 1);
}

- (void)test_markersPrecedeEnemiesAndPreserveArchetype {
    World world;
    PendingSpawn spawns[] = {{(uint8_t)EnemyArchetype::Rusher, 0, 40.f, 300.f}};
    addController(world, spawns, 1, 1);

    advance(world, kInitialWaveDelay + 0.1f);
    XCTAssertEqual(markerCount(world), 1);
    EntityID marker = kInvalidEntity;
    for (EntityID id = 0; id < world.entity_count(); ++id)
        if (world.spawn_markers().present(id)) marker = id;
    XCTAssertNotEqual(marker, kInvalidEntity);
    XCTAssertEqual(world.get_component<SpawnMarkerComponent>(marker).archetype,
                   (uint8_t)EnemyArchetype::Rusher);
    XCTAssertEqual(world.get_component<SpawnMarkerComponent>(marker).style,
                   (uint8_t)SpawnStyleSkyDrop);

    advance(world, kMarkerTelegraph + 0.1f);
    XCTAssertEqual(markerCount(world), 0);
    EntityID enemy = firstEnemy(world);
    XCTAssertNotEqual(enemy, kInvalidEntity);
    XCTAssertEqual(world.get_component<EnemyArchetypeComponent>(enemy).type,
                   (uint8_t)EnemyArchetype::Rusher);
    XCTAssertTrue(world.has_component<SpawnAnimComponent>(enemy));
}

- (void)test_spawnInsideObstacleMovesMarkerAndEnemyOutsideInflatedAABB {
    World world;
    addObstacle(world, 20.f, 300.f, 30.f, 20.f);
    PendingSpawn spawns[] = {{(uint8_t)EnemyArchetype::Grunt, 0, 20.f, 300.f}};
    addController(world, spawns, 1, 1);

    advance(world, kInitialWaveDelay + 0.1f);
    EntityID marker = firstMarker(world);
    XCTAssertNotEqual(marker, kInvalidEntity);
    PositionComponent markerPos = world.get_component<PositionComponent>(marker);
    XCTAssertEqualWithAccuracy(markerPos.x, 20.f, 0.001f);
    XCTAssertEqualWithAccuracy(markerPos.y, 360.f, 0.001f);

    advance(world, kMarkerTelegraph + 0.1f);
    EntityID enemy = firstEnemy(world);
    XCTAssertNotEqual(enemy, kInvalidEntity);
    const PositionComponent& enemyPos = world.get_component<PositionComponent>(enemy);
    XCTAssertEqualWithAccuracy(enemyPos.x, markerPos.x, 0.001f);
    XCTAssertEqualWithAccuracy(enemyPos.y, markerPos.y, 0.001f);
    XCTAssertGreaterThanOrEqual(enemyPos.y, 300.f + 20.f + 40.f);
}

- (void)test_clearSpawnPositionIsUnchanged {
    World world;
    addObstacle(world, 20.f, 300.f, 30.f, 20.f);
    PendingSpawn spawns[] = {{(uint8_t)EnemyArchetype::Grunt, 0, 120.f, 300.f}};
    addController(world, spawns, 1, 1);

    advance(world, kInitialWaveDelay + 0.1f);
    EntityID marker = firstMarker(world);
    XCTAssertNotEqual(marker, kInvalidEntity);
    PositionComponent markerPos = world.get_component<PositionComponent>(marker);
    XCTAssertEqualWithAccuracy(markerPos.x, 120.f, 0.001f);
    XCTAssertEqualWithAccuracy(markerPos.y, 300.f, 0.001f);

    advance(world, kMarkerTelegraph + 0.1f);
    EntityID enemy = firstEnemy(world);
    XCTAssertNotEqual(enemy, kInvalidEntity);
    const PositionComponent& enemyPos = world.get_component<PositionComponent>(enemy);
    XCTAssertEqualWithAccuracy(enemyPos.x, 120.f, 0.001f);
    XCTAssertEqualWithAccuracy(enemyPos.y, 300.f, 0.001f);
}

- (void)test_waveOneWaitsForWaveZeroDeathAndInterWaveDelay {
    World world;
    PendingSpawn spawns[] = {
        {(uint8_t)EnemyArchetype::Grunt, 0, 0.f, 300.f},
        {(uint8_t)EnemyArchetype::Heavy, 1, 120.f, 300.f},
    };
    EntityID controller = addController(world, spawns, 2, 2);

    advance(world, kInitialWaveDelay + kMarkerTelegraph + kSpawnAnimDuration + 0.2f);
    EntityID enemy = firstEnemy(world);
    XCTAssertNotEqual(enemy, kInvalidEntity);
    XCTAssertEqual(markerCount(world), 0);

    markEnemyDeadForWave(world, enemy);
    world.update(kFrameDt, kFrameDt);
    XCTAssertEqual(world.get_component<WaveControllerComponent>(controller).phase, WavePhaseFighting);
    XCTAssertEqualWithAccuracy(world.get_component<WaveControllerComponent>(controller).timer,
                               kInterWaveDelay - 1.0f / 120.0f, 0.001f);
    XCTAssertEqual(markerCount(world), 0);

    advance(world, kInterWaveDelay - 0.2f);
    XCTAssertEqual(markerCount(world), 0);
    XCTAssertFalse(WaveSystem_room_finished(world));

    advance(world, 0.3f);
    XCTAssertEqual(markerCount(world), 1);
    EntityID marker = kInvalidEntity;
    for (EntityID id = 0; id < world.entity_count(); ++id)
        if (world.spawn_markers().present(id)) marker = id;
    XCTAssertEqual(world.get_component<SpawnMarkerComponent>(marker).style,
                   (uint8_t)SpawnStyleGroundRise);
}

- (void)test_spawnAnimatingEnemiesAreInvulnerableInertAndDoNotDealDamage {
    World world;
    EntityID player = spawnPlayer(world, 0.f, 0.f);
    world.add_component<AnimationComponent>(player);
    setPlayerAttacking(world, player);

    EntityID enemy = Enemy_spawn(world, (uint8_t)EnemyArchetype::Grunt, 50.f, 0.f);
    world.add_component<SpawnAnimComponent>(enemy).style = SpawnStyleSkyDrop;
    world.get_component<AnimationComponent>(enemy).currentClip = AnimClipID::Attack;
    world.get_component<AnimationComponent>(enemy).requestedClip = AnimClipID::Attack;
    world.get_component<AnimationComponent>(enemy).clipTime = 1.03f * 0.475f;
    world.get_component<AnimationComponent>(enemy).looping = false;
    world.get_component<VelocityComponent>(enemy) = {100.f, 0.f, 0.f};

    float startX = world.get_component<PositionComponent>(enemy).x;
    world.update(kFrameDt, kFrameDt);

    XCTAssertEqual(world.get_component<HealthComponent>(enemy).current,
                   enemy_archetype_def((uint8_t)EnemyArchetype::Grunt).maxHP);
    XCTAssertEqual(world.get_component<HealthComponent>(player).current, 10);
    XCTAssertEqualWithAccuracy(world.get_component<PositionComponent>(enemy).x, startX, 0.001f);
}

- (void)test_roomFinishedOnlyAfterAllWavesDead {
    World world;
    PendingSpawn spawns[] = {
        {(uint8_t)EnemyArchetype::Grunt, 0, 0.f, 300.f},
        {(uint8_t)EnemyArchetype::Grunt, 1, 120.f, 300.f},
    };
    addController(world, spawns, 2, 2);
    XCTAssertFalse(WaveSystem_room_finished(world));

    advance(world, kInitialWaveDelay + kMarkerTelegraph + kSpawnAnimDuration + 0.2f);
    markEnemyDeadForWave(world, firstEnemy(world));
    advance(world, kInterWaveDelay + 0.1f);
    XCTAssertFalse(WaveSystem_room_finished(world), @"between waves is not room-finished");

    advance(world, kMarkerTelegraph + kSpawnAnimDuration + 0.2f);
    EntityID second = kInvalidEntity;
    for (EntityID id = 0; id < world.entity_count(); ++id) {
        if (!world.has_component<FactionComponent>(id)) continue;
        if (world.get_component<FactionComponent>(id).type != FactionComponent::Enemy) continue;
        if (world.has_component<HealthComponent>(id) &&
            world.get_component<HealthComponent>(id).current > 0)
            second = id;
    }
    XCTAssertNotEqual(second, kInvalidEntity);
    markEnemyDeadForWave(world, second);
    advance(world, 0.1f);
    XCTAssertTrue(WaveSystem_room_finished(world));
}

- (void)test_bossReinforcementsRespectCapAndStopOnBossDeath {
    World world;
    PendingSpawn spawns[] = {{(uint8_t)EnemyArchetype::Boss, 0, 0.f, 320.f}};
    addController(world, spawns, 1, 1, true);

    advance(world, kInitialWaveDelay + kMarkerTelegraph + kSpawnAnimDuration + 0.2f);
    EntityID boss = firstBoss(world);
    XCTAssertNotEqual(boss, kInvalidEntity);

    advance(world, kBossReinforceInterval + 0.2f);
    XCTAssertEqual(markerCount(world), 2);
    advance(world, kMarkerTelegraph + kSpawnAnimDuration + 0.2f);
    XCTAssertEqual(livingMinionCount(world), 2);

    Enemy_spawn(world, (uint8_t)EnemyArchetype::Grunt, 0.f, 180.f);
    advance(world, kBossReinforceInterval + 0.2f);
    XCTAssertEqual(markerCount(world), 0, @"three live minions should hold the cap");

    Combat_apply_death(world, boss);
    world.update(kFrameDt, kFrameDt);
    XCTAssertTrue(WaveSystem_room_finished(world));
    XCTAssertEqual(markerCount(world), 0);
    XCTAssertEqual(livingMinionCount(world), 0);
}

- (void)test_bossDeathCancelsPendingMarkers {
    World world;
    PendingSpawn spawns[] = {{(uint8_t)EnemyArchetype::Boss, 0, 0.f, 320.f}};
    addController(world, spawns, 1, 1, true);
    advance(world, kInitialWaveDelay + kMarkerTelegraph + kSpawnAnimDuration + 0.2f);
    EntityID boss = firstBoss(world);
    advance(world, kBossReinforceInterval + 0.2f);
    XCTAssertGreaterThan(markerCount(world), 0);

    Combat_apply_death(world, boss);
    world.update(kFrameDt, kFrameDt);
    XCTAssertEqual(markerCount(world), 0);
    XCTAssertTrue(WaveSystem_room_finished(world));
}

- (void)test_sameSeedProducesIdenticalWaveTimeline {
    auto run = [](uint32_t seed) {
        World world;
        world.set_seed(seed);
        PendingSpawn spawns[] = {
            {(uint8_t)EnemyArchetype::Grunt, 0, -80.f, 300.f},
            {(uint8_t)EnemyArchetype::Rusher, 1, 80.f, 300.f},
        };
        addController(world, spawns, 2, 2);
        std::vector<std::string> timeline;
        for (int frame = 0; frame < 600; ++frame) {
            world.update(kFrameDt, kFrameDt);
            if (markerCount(world) > 0)
                timeline.push_back(std::to_string(frame) + ":m" + std::to_string(markerCount(world)));
            if (enemyCount(world) > 0)
                timeline.push_back(std::to_string(frame) + ":e" + std::to_string(enemyCount(world)));
            EntityID enemy = firstEnemy(world);
            if (enemy != kInvalidEntity &&
                world.has_component<HealthComponent>(enemy) &&
                world.get_component<HealthComponent>(enemy).current > 0 &&
                !world.has_component<SpawnAnimComponent>(enemy))
                markEnemyDeadForWave(world, enemy);
        }
        return timeline;
    };

    XCTAssertTrue(run(1234) == run(1234));
}

@end
