#include "ProjectileSystem.h"
#include "Simulation/RoomBounds.h"
#include "Simulation/Systems/AnimationSystem.h"
#include "Simulation/Systems/CombatHelpers.h"
#include "Simulation/Systems/ScreenShakeSystem.h"
#include <math.h>

static constexpr float kProjectileRehit = 0.8f;

static bool point_in_obstacle(World& world, const PositionComponent& pos) {
    for (EntityID oid = 0; oid < world.entity_count(); ++oid) {
        if (!world.obstacles().present(oid)) continue;
        if (!world.has_component<PositionComponent>(oid)) continue;
        const PositionComponent& opos = world.get_component<PositionComponent>(oid);
        const ObstacleComponent& obs = world.get_component<ObstacleComponent>(oid);
        if (pos.x >= opos.x - obs.halfW && pos.x <= opos.x + obs.halfW &&
            pos.y >= opos.y - obs.halfH && pos.y <= opos.y + obs.halfH)
            return true;
    }
    return false;
}

void ProjectileSystem_update(World& world, float gameDt) {
    if (gameDt == 0.f) return;

    uint32_t count = world.entity_count();
    for (EntityID id = 0; id < count; ++id) {
        if (!world.projectiles().present(id)) continue;
        if (!world.has_component<PositionComponent>(id)) continue;

        ProjectileComponent& proj = world.get_component<ProjectileComponent>(id);
        PositionComponent& pos = world.get_component<PositionComponent>(id);
        proj.lifetime -= gameDt;
        pos.x += proj.vx * gameDt;
        pos.y += proj.vy * gameDt;

        if (proj.lifetime <= 0.f ||
            pos.x < kRoomMinX || pos.x > kRoomMaxX ||
            pos.y < kRoomMinY || pos.y > kRoomMaxY ||
            point_in_obstacle(world, pos)) {
            world.defer_destroy(id);
            continue;
        }

        for (EntityID pid = 0; pid < count; ++pid) {
            if (!world.player_tags().present(pid)) continue;
            if (!world.has_component<PositionComponent>(pid)) continue;
            if (!world.has_component<HealthComponent>(pid)) continue;
            if (world.has_component<DownedComponent>(pid)) continue;
            if (world.has_component<DodgeComponent>(pid)) continue;
            if (world.has_component<AnimationComponent>(pid) &&
                world.get_component<AnimationComponent>(pid).dying) continue;
            if (world.has_component<DamageCooldownComponent>(pid) &&
                world.get_component<DamageCooldownComponent>(pid).remaining > 0.f)
                continue;

            const PositionComponent& pp = world.get_component<PositionComponent>(pid);
            float dx = pp.x - pos.x;
            float dy = pp.y - pos.y;
            if (dx * dx + dy * dy > kProjectileHitRadius * kProjectileHitRadius) continue;

            HealthComponent& hp = world.get_component<HealthComponent>(pid);
            hp.current -= proj.damage;
            world.events().emit_hit_contact(id, pid);
            world.events().emit_damage(pid, proj.damage);
            ScreenShakeSystem_trigger(world, 12.f);
            if (world.has_component<DamageCooldownComponent>(pid))
                world.get_component<DamageCooldownComponent>(pid).remaining = kProjectileRehit;
            if (hp.current <= 0 &&
                !Combat_try_second_wind(world, pid) &&
                world.has_component<AnimationComponent>(pid)) {
                Combat_apply_death(world, pid, id);
            } else if (world.has_component<AnimationComponent>(pid)) {
                AnimationSystem_request_clip(world, pid, AnimClipID::Hurt);
            }
            world.defer_destroy(id);
            break;
        }
    }
}
