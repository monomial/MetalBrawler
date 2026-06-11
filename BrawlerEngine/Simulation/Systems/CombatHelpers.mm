#include "CombatHelpers.h"
#include "Simulation/Systems/AnimationSystem.h"
#include "Simulation/Systems/WaveSystem.h"

void Combat_spawn_heart_drop_if_needed(World& world, EntityID victimID) {
    if (!world.has_component<FactionComponent>(victimID)) return;
    if (world.get_component<FactionComponent>(victimID).type != FactionComponent::Enemy) return;
    if (!world.has_component<PositionComponent>(victimID)) return;
    if (world.rand_float01() >= 0.25f) return;

    const PositionComponent& p = world.get_component<PositionComponent>(victimID);
    EntityID heart = world.defer_create();
    world.add_component<PositionComponent>(heart) = {p.x, p.y, 0.f};
    world.add_component<HeartPickupComponent>(heart);
}

bool Combat_try_second_wind(World& world, EntityID victimID) {
    if (!world.player_tags().present(victimID)) return false;
    if (!world.has_component<HealthComponent>(victimID)) return false;
    if (!world.has_component<StatsComponent>(victimID)) return false;

    StatsComponent& stats = world.get_component<StatsComponent>(victimID);
    if (stats.secondWinds <= 0) return false;

    HealthComponent& hp = world.get_component<HealthComponent>(victimID);
    if (hp.current > 0) return false;

    stats.secondWinds -= 1;
    hp.current = 1;
    world.events().emit_second_wind_used(victimID);
    return true;
}

static bool has_living_teammate(World& world, EntityID victimID) {
    uint32_t count = world.entity_count();
    for (EntityID id = 0; id < count; ++id) {
        if (id == victimID) continue;
        if (!world.player_tags().present(id)) continue;
        if (world.has_component<DownedComponent>(id)) continue;
        if (!world.has_component<HealthComponent>(id)) continue;
        if (world.get_component<HealthComponent>(id).current <= 0) continue;
        if (world.has_component<AnimationComponent>(id) &&
            world.get_component<AnimationComponent>(id).dying) continue;
        return true;
    }
    return false;
}

static bool is_living_enemy_for_sweep(World& world, EntityID id) {
    if (!world.has_component<FactionComponent>(id)) return false;
    if (world.get_component<FactionComponent>(id).type != FactionComponent::Enemy) return false;
    if (!world.has_component<HealthComponent>(id)) return false;
    if (world.get_component<HealthComponent>(id).current <= 0) return false;
    if (world.has_component<AnimationComponent>(id) &&
        world.get_component<AnimationComponent>(id).dying) return false;
    return true;
}

static void Combat_apply_death_internal(World& world, EntityID victimID,
                                        bool allowHeartDrop, bool allowBossSweep) {
    if (world.player_tags().present(victimID) &&
        !world.has_component<DownedComponent>(victimID) &&
        has_living_teammate(world, victimID)) {
        world.add_component<DownedComponent>(victimID).reviveProgress = 0.f;
        if (world.has_component<HealthComponent>(victimID))
            world.get_component<HealthComponent>(victimID).current = 0;
        if (world.has_component<AnimationComponent>(victimID)) {
            AnimationComponent& anim = world.get_component<AnimationComponent>(victimID);
            anim.dying = false;
            anim.currentClip = AnimClipID::Death;
            anim.requestedClip = AnimClipID::Death;
            anim.clipTime = 0.f;
            anim.looping = false;
            anim.clipDone = false;
            anim.hitApplied = true;
            anim.comboQueued = false;
            AnimationSystem_request_clip(world, victimID, AnimClipID::Death);
        }
        if (world.has_component<VelocityComponent>(victimID)) {
            VelocityComponent& vel = world.get_component<VelocityComponent>(victimID);
            vel.vx = vel.vy = vel.vz = 0.f;
        }
        world.events().emit_player_downed(victimID);
        return;
    }

    world.events().emit_died(victimID);
    if (allowHeartDrop)
        Combat_spawn_heart_drop_if_needed(world, victimID);

    if (world.has_component<AnimationComponent>(victimID)) {
        world.get_component<AnimationComponent>(victimID).dying = true;
        AnimationSystem_request_clip(world, victimID, AnimClipID::Death);
    } else {
        world.defer_destroy(victimID);
    }

    if (world.has_component<VelocityComponent>(victimID)) {
        VelocityComponent& vel = world.get_component<VelocityComponent>(victimID);
        vel.vx = vel.vy = vel.vz = 0.f;
    }

    if (allowBossSweep && world.has_component<BossTagComponent>(victimID)) {
        for (EntityID id = 0; id < world.entity_count(); ++id) {
            if (id == victimID) continue;
            if (!is_living_enemy_for_sweep(world, id)) continue;
            world.get_component<HealthComponent>(id).current = 0;
            Combat_apply_death_internal(world, id, false, false);
        }
        WaveSystem_force_done(world);
    }
}

void Combat_apply_death(World& world, EntityID victimID) {
    Combat_apply_death_internal(world, victimID, true, true);
}
