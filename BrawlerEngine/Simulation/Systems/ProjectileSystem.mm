#include "ProjectileSystem.h"
#include "Simulation/RoomBounds.h"
#include "Simulation/Systems/AnimationSystem.h"
#include "Simulation/Systems/CombatHelpers.h"
#include "Simulation/Systems/ScreenShakeSystem.h"
#include <math.h>

static constexpr float kProjectileRehit = 0.8f;

static EntityID nearest_living_player(World& world, const PositionComponent& origin) {
    EntityID best = kInvalidEntity;
    float bestD2 = 0.f;
    for (EntityID id = 0; id < world.entity_count(); ++id) {
        if (!world.player_tags().present(id)) continue;
        if (!world.has_component<PositionComponent>(id)) continue;
        if (!world.has_component<HealthComponent>(id)) continue;
        if (world.get_component<HealthComponent>(id).current <= 0) continue;
        if (world.has_component<DownedComponent>(id)) continue;
        if (world.has_component<AnimationComponent>(id) &&
            world.get_component<AnimationComponent>(id).dying) continue;
        const PositionComponent& p = world.get_component<PositionComponent>(id);
        float dx = p.x - origin.x;
        float dy = p.y - origin.y;
        float d2 = dx * dx + dy * dy;
        if (best == kInvalidEntity || d2 < bestD2) {
            best = id;
            bestD2 = d2;
        }
    }
    return best;
}

static float clampf_local(float v, float lo, float hi) {
    return v < lo ? lo : (v > hi ? hi : v);
}

static void steer_projectile_toward_player(World& world, ProjectileComponent& proj,
                                           const PositionComponent& pos,
                                           float gameDt) {
    if (proj.homing <= 0.f || proj.homingTime <= 0.f) return;
    float speed = sqrtf(proj.vx * proj.vx + proj.vy * proj.vy);
    if (speed <= 0.001f) return;
    EntityID target = nearest_living_player(world, pos);
    if (target == kInvalidEntity) return;
    const PositionComponent& tp = world.get_component<PositionComponent>(target);
    float dx = tp.x - pos.x;
    float dy = tp.y - pos.y;
    if (dx * dx + dy * dy <= 0.001f) return;
    float current = atan2f(proj.vy, proj.vx);
    float desired = atan2f(dy, dx);
    float delta = desired - current;
    while (delta > (float)M_PI) delta -= (float)M_PI * 2.f;
    while (delta < -(float)M_PI) delta += (float)M_PI * 2.f;
    float maxTurn = proj.homing * gameDt;
    float next = current + clampf_local(delta, -maxTurn, maxTurn);
    proj.vx = cosf(next) * speed;
    proj.vy = sinf(next) * speed;
}

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
        if (proj.homingTime > 0.f) {
            proj.homingTime -= gameDt;
            if (proj.homingTime < 0.f) proj.homingTime = 0.f;
        }
        steer_projectile_toward_player(world, proj, pos, gameDt);
        pos.x += proj.vx * gameDt;
        pos.y += proj.vy * gameDt;

        if (proj.lifetime <= 0.f ||
            pos.x < kRoomMinX || pos.x > kRoomMaxX ||
            pos.y < kRoomMinY || pos.y > kRoomMaxY ||
            point_in_obstacle(world, pos)) {
            world.defer_destroy(id);
            continue;
        }

        if (world.players_invincible()) break; // victory window — no chip
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
            if (Combat_player_dodges_hit(world, pid)) {
                if (world.has_component<DamageCooldownComponent>(pid))
                    world.get_component<DamageCooldownComponent>(pid).remaining = kProjectileRehit;
                world.defer_destroy(id);
                break;
            }

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
