#include "LeaperSystem.h"
#include "Simulation/Difficulty.h"
#include "Simulation/RoomBounds.h"
#include "Simulation/Systems/AnimationSystem.h"
#include "Simulation/Systems/CombatHelpers.h"
#include "Simulation/Systems/ScreenShakeSystem.h"
#include <math.h>

static constexpr uint8_t kLeaperWalk = 0;
static constexpr uint8_t kLeaperTelegraph = 1;
static constexpr uint8_t kLeaperLeap = 2;
static constexpr uint8_t kLeaperRecover = 3;
static constexpr float kRecoverDuration = 0.6f;
static constexpr float kRetryCooldown = 0.5f;
static constexpr float kLeapMin = 180.f;
static constexpr float kLeapMax = 460.f;
static constexpr float kLandingInset = 60.f;
static constexpr float kLandingRadius = 40.f;
static constexpr float kHitRadius = 55.f;
static constexpr float kLeaperRehit = 0.8f;

static float clampf(float v, float lo, float hi) {
    return v < lo ? lo : (v > hi ? hi : v);
}

static float smoothstep(float t) {
    t = clampf(t, 0.f, 1.f);
    return t * t * (3.f - 2.f * t);
}

static bool living_player(World& world, EntityID id) {
    if (!world.player_tags().present(id)) return false;
    if (!world.has_component<PositionComponent>(id)) return false;
    if (!world.has_component<HealthComponent>(id)) return false;
    if (world.get_component<HealthComponent>(id).current <= 0) return false;
    if (world.has_component<DownedComponent>(id)) return false;
    if (world.has_component<AnimationComponent>(id) &&
        world.get_component<AnimationComponent>(id).dying) return false;
    return true;
}

static EntityID nearest_living_player(World& world, const PositionComponent& origin, float* outDist) {
    EntityID best = kInvalidEntity;
    float bestD2 = 0.f;
    for (EntityID id = 0; id < world.entity_count(); ++id) {
        if (!living_player(world, id)) continue;
        const PositionComponent& p = world.get_component<PositionComponent>(id);
        float dx = p.x - origin.x;
        float dy = p.y - origin.y;
        float d2 = dx * dx + dy * dy;
        if (best == kInvalidEntity || d2 < bestD2) {
            best = id;
            bestD2 = d2;
        }
    }
    if (outDist) *outDist = (best == kInvalidEntity) ? 0.f : sqrtf(bestD2);
    return best;
}

static bool landing_clear(World& world, float x, float y) {
    for (EntityID id = 0; id < world.entity_count(); ++id) {
        if (!world.obstacles().present(id)) continue;
        if (!world.has_component<PositionComponent>(id)) continue;
        const PositionComponent& pos = world.get_component<PositionComponent>(id);
        const ObstacleComponent& obs = world.get_component<ObstacleComponent>(id);
        if (fabsf(x - pos.x) <= obs.halfW + kLandingRadius &&
            fabsf(y - pos.y) <= obs.halfH + kLandingRadius)
            return false;
    }
    return true;
}

static bool pick_destination(World& world, const PositionComponent& start,
                             const PositionComponent& target, float dist,
                             float* outX, float* outY) {
    if (dist < 0.001f) return false;
    float dirX = (target.x - start.x) / dist;
    float dirY = (target.y - start.y) / dist;
    float leapLen = fminf(dist + 80.f, kLeapMax);
    for (; leapLen >= kLeapMin; leapLen -= 40.f) {
        float x = clampf(start.x + dirX * leapLen, kRoomMinX + kLandingInset, kRoomMaxX - kLandingInset);
        float y = clampf(start.y + dirY * leapLen, kRoomMinY + kLandingInset, kRoomMaxY - kLandingInset);
        if (!landing_clear(world, x, y)) continue;
        *outX = x;
        *outY = y;
        return true;
    }
    return false;
}

static void damage_players_under_leaper(World& world, EntityID leaperID, const PositionComponent& pos) {
    for (EntityID pid = 0; pid < world.entity_count(); ++pid) {
        if (!living_player(world, pid)) continue;
        if (world.has_component<DodgeComponent>(pid)) continue;
        if (world.has_component<DamageCooldownComponent>(pid) &&
            world.get_component<DamageCooldownComponent>(pid).remaining > 0.f)
            continue;
        const PositionComponent& pp = world.get_component<PositionComponent>(pid);
        float dx = pp.x - pos.x;
        float dy = pp.y - pos.y;
        if (dx * dx + dy * dy > kHitRadius * kHitRadius) continue;

        HealthComponent& hp = world.get_component<HealthComponent>(pid);
        hp.current -= 3;
        world.events().emit_hit_contact(leaperID, pid);
        world.events().emit_damage(pid, 3);
        ScreenShakeSystem_trigger(world, 12.f);
        if (world.has_component<DamageCooldownComponent>(pid))
            world.get_component<DamageCooldownComponent>(pid).remaining = kLeaperRehit;
        if (hp.current <= 0 &&
            !Combat_try_second_wind(world, pid) &&
            world.has_component<AnimationComponent>(pid)) {
            Combat_apply_death(world, pid, leaperID);
        }
    }
}

void LeaperSystem_update(World& world, float gameDt) {
    if (gameDt == 0.f) return;

    for (EntityID id = 0; id < world.entity_count(); ++id) {
        if (!world.leapers().present(id)) continue;
        if (!world.has_component<PositionComponent>(id)) continue;
        if (world.has_component<SpawnAnimComponent>(id)) continue;
        if (world.has_component<AnimationComponent>(id) &&
            world.get_component<AnimationComponent>(id).dying) continue;

        LeaperComponent& leap = world.get_component<LeaperComponent>(id);
        PositionComponent& pos = world.get_component<PositionComponent>(id);
        if (!world.has_component<VelocityComponent>(id))
            world.add_component<VelocityComponent>(id) = {};
        VelocityComponent& vel = world.get_component<VelocityComponent>(id);

        if (leap.state == kLeaperWalk) {
            if (leap.cooldown > 0.f) {
                leap.cooldown -= gameDt;
                if (leap.cooldown < 0.f) leap.cooldown = 0.f;
                continue;
            }

            float dist = 0.f;
            EntityID target = nearest_living_player(world, pos, &dist);
            if (target == kInvalidEntity || dist < 120.f || dist > 600.f)
                continue;

            const PositionComponent& targetPos = world.get_component<PositionComponent>(target);
            float destX = 0.f, destY = 0.f;
            if (!pick_destination(world, pos, targetPos, dist, &destX, &destY)) {
                leap.cooldown = kRetryCooldown;
                continue;
            }

            leap.state = kLeaperTelegraph;
            leap.timer = Difficulty_leaper_telegraph(world.difficulty());
            leap.startX = pos.x;
            leap.startY = pos.y;
            leap.destX = destX;
            leap.destY = destY;
            vel = {0.f, 0.f, 0.f};
            TelegraphLineComponent& line = world.has_component<TelegraphLineComponent>(id)
                ? world.get_component<TelegraphLineComponent>(id)
                : world.add_component<TelegraphLineComponent>(id);
            float dx = destX - pos.x;
            float dy = destY - pos.y;
            float len = sqrtf(dx * dx + dy * dy);
            line.x2 = destX;
            line.y2 = destY;
            line.width = 80.f;
            line.aimX = len > 0.001f ? dx / len : 0.f;
            line.aimY = len > 0.001f ? dy / len : 1.f;
            continue;
        }

        if (leap.state == kLeaperTelegraph) {
            vel = {0.f, 0.f, 0.f};
            leap.timer -= gameDt;
            if (leap.timer <= 0.2f && world.has_component<AnimationComponent>(id))
                AnimationSystem_request_clip(world, id, AnimClipID::Attack);
            if (leap.timer <= 0.f) {
                leap.state = kLeaperLeap;
                leap.timer = 0.f;
                leap.startX = pos.x;
                leap.startY = pos.y;
                world.remove_component<TelegraphLineComponent>(id);
            }
            continue;
        }

        if (leap.state == kLeaperLeap) {
            leap.timer += gameDt;
            float t = clampf(leap.timer / Difficulty_leap_duration(world.difficulty()), 0.f, 1.f);
            float eased = smoothstep(t);
            pos.x = leap.startX + (leap.destX - leap.startX) * eased;
            pos.y = leap.startY + (leap.destY - leap.startY) * eased;
            vel = {0.f, 0.f, 0.f};
            damage_players_under_leaper(world, id, pos);
            if (t >= 1.f) {
                pos.x = leap.destX;
                pos.y = leap.destY;
                leap.state = kLeaperRecover;
                leap.timer = kRecoverDuration;
            }
            continue;
        }

        if (leap.state == kLeaperRecover) {
            vel = {0.f, 0.f, 0.f};
            leap.timer -= gameDt;
            if (leap.timer <= 0.f) {
                leap.state = kLeaperWalk;
                leap.timer = 0.f;
                leap.cooldown = enemy_archetype_def((uint8_t)EnemyArchetype::Leaper).attackCooldown *
                                Difficulty_cooldown_mult(world.difficulty());
            }
        }
    }
}
