#include "CombatHelpers.h"
#include "Simulation/Systems/AnimationSystem.h"

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

void Combat_apply_death(World& world, EntityID victimID) {
    world.events().emit_died(victimID);
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
}
