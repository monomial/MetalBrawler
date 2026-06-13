#include "WaveSystem.h"
#include "Simulation/Difficulty.h"
#include "Simulation/Systems/EnemyFactory.h"
#include "Simulation/Systems/ScreenShakeSystem.h"
#include <math.h>

static constexpr float kSpawnObstacleRadius = 40.f;

uint8_t WaveSystem_spawn_style(uint8_t archetype) {
    return (archetype == (uint8_t)EnemyArchetype::Heavy ||
            archetype == (uint8_t)EnemyArchetype::Boss)
        ? (uint8_t)SpawnStyleGroundRise
        : (uint8_t)SpawnStyleSkyDrop;
}

static bool is_living_enemy(World& world, EntityID id) {
    if (!world.has_component<FactionComponent>(id)) return false;
    if (world.get_component<FactionComponent>(id).type != FactionComponent::Enemy) return false;
    if (!world.has_component<HealthComponent>(id)) return false;
    if (world.get_component<HealthComponent>(id).current <= 0) return false;
    if (world.has_component<AnimationComponent>(id) &&
        world.get_component<AnimationComponent>(id).dying) return false;
    return true;
}

static bool boss_alive(World& world) {
    for (EntityID id = 0; id < world.entity_count(); ++id) {
        if (!world.boss_tags().present(id)) continue;
        if (is_living_enemy(world, id)) return true;
    }
    return false;
}

static int living_minion_count(World& world) {
    int count = 0;
    for (EntityID id = 0; id < world.entity_count(); ++id) {
        if (!is_living_enemy(world, id)) continue;
        if (world.boss_tags().present(id)) continue;
        ++count;
    }
    return count;
}

static bool any_living_enemy(World& world) {
    for (EntityID id = 0; id < world.entity_count(); ++id) {
        if (is_living_enemy(world, id)) return true;
    }
    return false;
}

static int marker_count(World& world) {
    int count = 0;
    for (EntityID id = 0; id < world.entity_count(); ++id) {
        if (world.spawn_markers().present(id)) ++count;
    }
    return count;
}

static float clampf(float v, float lo, float hi) {
    if (v < lo) return lo;
    if (v > hi) return hi;
    return v;
}

static void nudge_spawn_out_of_obstacles(World& world, float& x, float& y) {
    for (EntityID oid = 0; oid < world.entity_count(); ++oid) {
        if (!world.obstacles().present(oid)) continue;
        if (!world.has_component<PositionComponent>(oid)) continue;

        const PositionComponent& opos = world.get_component<PositionComponent>(oid);
        const ObstacleComponent& obs = world.get_component<ObstacleComponent>(oid);
        float minX = opos.x - obs.halfW;
        float maxX = opos.x + obs.halfW;
        float minY = opos.y - obs.halfH;
        float maxY = opos.y + obs.halfH;
        float cx = clampf(x, minX, maxX);
        float cy = clampf(y, minY, maxY);
        float dx = x - cx;
        float dy = y - cy;
        float d2 = dx * dx + dy * dy;
        float r2 = kSpawnObstacleRadius * kSpawnObstacleRadius;
        if (d2 >= r2) continue;

        if (d2 > 1e-6f) {
            float d = sqrtf(d2);
            x = cx + (dx / d) * kSpawnObstacleRadius;
            y = cy + (dy / d) * kSpawnObstacleRadius;
            continue;
        }

        float fromCenterX = x - opos.x;
        float fromCenterY = y - opos.y;
        if (fabsf(fromCenterX) <= 1e-6f && fabsf(fromCenterY) <= 1e-6f) {
            x = opos.x;
            y = opos.y + obs.halfH + kSpawnObstacleRadius;
            continue;
        }

        float inflatedHalfW = obs.halfW + kSpawnObstacleRadius;
        float inflatedHalfH = obs.halfH + kSpawnObstacleRadius;
        float scaleX = (fabsf(fromCenterX) > 1e-6f) ? inflatedHalfW / fabsf(fromCenterX) : INFINITY;
        float scaleY = (fabsf(fromCenterY) > 1e-6f) ? inflatedHalfH / fabsf(fromCenterY) : INFINITY;
        float scale = fminf(scaleX, scaleY);
        x = opos.x + fromCenterX * scale;
        y = opos.y + fromCenterY * scale;
    }
}

static void spawn_marker(World& world, uint8_t archetype, float x, float y) {
    nudge_spawn_out_of_obstacles(world, x, y);
    EntityID marker = world.defer_create();
    world.add_component<PositionComponent>(marker) = {x, y, 0.f};
    SpawnMarkerComponent& sm = world.add_component<SpawnMarkerComponent>(marker);
    sm.archetype = archetype;
    sm.countdown = kMarkerTelegraph;
    sm.style = WaveSystem_spawn_style(archetype);
}

static void emit_plan_markers(World& world, WaveControllerComponent& ctrl, int wave) {
    for (int i = 0; i < ctrl.spawnCount; ++i) {
        const PendingSpawn& spawn = ctrl.spawns[i];
        if (spawn.wave != wave) continue;
        spawn_marker(world, spawn.archetype, spawn.x, spawn.y);
    }
    ctrl.currentWave = wave;
    ctrl.phase = WavePhaseTelegraph;
    ctrl.timer = 0.f;
    world.events().emit_wave_started((uint8_t)wave);
}

static void emit_reinforcement_markers(World& world, WaveControllerComponent& ctrl) {
    if (ctrl.reinforceCount <= 0) return;
    int sequence = ctrl.currentWave - ctrl.waveCount + 1;
    if (sequence < 0) sequence = 0;
    for (int i = 0; i < 2; ++i) {
        const PendingSpawn& spawn = ctrl.reinforcements[(sequence * 2 + i) % ctrl.reinforceCount];
        spawn_marker(world, spawn.archetype, spawn.x, spawn.y);
    }
    ctrl.currentWave += 1;
    ctrl.phase = WavePhaseTelegraph;
    ctrl.timer = 0.f;
    world.events().emit_wave_started((uint8_t)ctrl.currentWave);
}

static void tick_spawn_anims(World& world, float gameDt) {
    if (gameDt == 0.f) return;
    for (EntityID id = 0; id < world.entity_count(); ++id) {
        if (!world.spawn_anims().present(id)) continue;
        SpawnAnimComponent& anim = world.get_component<SpawnAnimComponent>(id);
        anim.progress += gameDt / kSpawnAnimDuration;
        if (anim.progress >= 1.f) {
            uint8_t style = anim.style;
            world.remove_component<SpawnAnimComponent>(id);
            world.events().emit_spawn_landed(id, style);
            if (style == SpawnStyleSkyDrop)
                ScreenShakeSystem_trigger(world, 4.f);
        }
    }
}

static void tick_markers(World& world, float gameDt) {
    if (gameDt == 0.f) return;
    for (EntityID id = 0; id < world.entity_count(); ++id) {
        if (!world.spawn_markers().present(id)) continue;
        if (!world.has_component<PositionComponent>(id)) continue;
        SpawnMarkerComponent& marker = world.get_component<SpawnMarkerComponent>(id);
        marker.countdown -= gameDt;
        if (marker.countdown > 0.f) continue;

        const PositionComponent& pos = world.get_component<PositionComponent>(id);
        EntityID enemy = Enemy_spawn(world, marker.archetype, pos.x, pos.y);
        SpawnAnimComponent& spawnAnim = world.add_component<SpawnAnimComponent>(enemy);
        spawnAnim.progress = 0.f;
        spawnAnim.style = marker.style;
        world.defer_destroy(id);
    }
}

void WaveSystem_update(World& world, float gameDt) {
    tick_spawn_anims(world, gameDt);
    tick_markers(world, gameDt);
    if (gameDt == 0.f) return;

    for (EntityID id = 0; id < world.entity_count(); ++id) {
        if (!world.wave_controllers().present(id)) continue;
        WaveControllerComponent& ctrl = world.get_component<WaveControllerComponent>(id);
        if (ctrl.phase == WavePhaseDone) continue;

        switch (ctrl.phase) {
            case WavePhaseInitialDelay:
                ctrl.timer -= gameDt;
                if (ctrl.timer <= 0.f)
                    emit_plan_markers(world, ctrl, 0);
                break;

            case WavePhaseTelegraph:
                if (marker_count(world) == 0) {
                    ctrl.phase = WavePhaseFighting;
                    ctrl.timer = (ctrl.bossMode && ctrl.currentWave + 1 >= ctrl.waveCount)
                        ? kBossReinforceInterval * Difficulty_reinforce_mult(world.difficulty()) : 0.f;
                }
                break;

            case WavePhaseFighting: {
                if (ctrl.bossMode && !boss_alive(world)) {
                    WaveSystem_force_done(world);
                    break;
                }

                if (ctrl.currentWave + 1 < ctrl.waveCount) {
                    if (!any_living_enemy(world)) {
                        if (ctrl.timer <= 0.f) {
                            ctrl.timer = kInterWaveDelay;
                        } else {
                            ctrl.timer -= gameDt;
                            if (ctrl.timer <= 0.f)
                                emit_plan_markers(world, ctrl, ctrl.currentWave + 1);
                        }
                    }
                    break;
                }

                if (!ctrl.bossMode) {
                    if (!any_living_enemy(world))
                        ctrl.phase = WavePhaseDone;
                    break;
                }

                if (living_minion_count(world) >= ctrl.bossMinionCap) {
                    ctrl.timer = kBossReinforceInterval * Difficulty_reinforce_mult(world.difficulty());
                    break;
                }
                ctrl.timer -= gameDt;
                if (ctrl.timer <= 0.f)
                    emit_reinforcement_markers(world, ctrl);
                break;
            }

            case WavePhaseDone:
            default:
                break;
        }
    }
}

bool WaveSystem_room_finished(World& world) {
    bool hasController = false;
    for (EntityID id = 0; id < world.entity_count(); ++id) {
        if (!world.wave_controllers().present(id)) continue;
        hasController = true;
        if (world.get_component<WaveControllerComponent>(id).phase != WavePhaseDone)
            return false;
    }
    if (!hasController) return true;
    return marker_count(world) == 0;
}

void WaveSystem_force_done(World& world) {
    for (EntityID id = 0; id < world.entity_count(); ++id) {
        if (world.wave_controllers().present(id)) {
            WaveControllerComponent& ctrl = world.get_component<WaveControllerComponent>(id);
            ctrl.phase = WavePhaseDone;
            ctrl.timer = 0.f;
        }
        if (world.spawn_markers().present(id))
            world.defer_destroy(id);
    }
}
