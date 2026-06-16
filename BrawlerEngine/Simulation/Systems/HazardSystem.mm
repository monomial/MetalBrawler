#include "HazardSystem.h"
#include "Simulation/World.h"
#include "Simulation/RoomBounds.h"
#include "Simulation/Systems/AnimationSystem.h"
#include "Simulation/Systems/CombatHelpers.h"
#include "Simulation/Systems/ScreenShakeSystem.h"
#include <math.h>

static constexpr float kHazardRehit = 0.8f; // per-victim re-hit delay

static float clampf(float v, float lo, float hi) {
    return v < lo ? lo : (v > hi ? hi : v);
}

// Position along the closed polyline at `distance` (wraps).
static void sample_path(const PathFollowComponent& path, float* outX, float* outY) {
    if (path.count < 2) { *outX = path.pts[0][0]; *outY = path.pts[0][1]; return; }

    float total = 0.f;
    float segLen[4];
    for (int i = 0; i < path.count; ++i) {
        int j = (i + 1) % path.count;
        float dx = path.pts[j][0] - path.pts[i][0];
        float dy = path.pts[j][1] - path.pts[i][1];
        segLen[i] = sqrtf(dx * dx + dy * dy);
        total += segLen[i];
    }
    if (total < 0.001f) { *outX = path.pts[0][0]; *outY = path.pts[0][1]; return; }

    float d = fmodf(path.distance, total);
    for (int i = 0; i < path.count; ++i) {
        if (d <= segLen[i] || i == path.count - 1) {
            int j = (i + 1) % path.count;
            float t = segLen[i] > 0.001f ? d / segLen[i] : 0.f;
            *outX = path.pts[i][0] + (path.pts[j][0] - path.pts[i][0]) * t;
            *outY = path.pts[i][1] + (path.pts[j][1] - path.pts[i][1]) * t;
            return;
        }
        d -= segLen[i];
    }
    *outX = path.pts[0][0]; *outY = path.pts[0][1];
}

unsigned int HazardSystem_spawn_snake(World& world, float x, float y,
                                      float outX, float outY) {
    EntityID e = world.defer_create();
    world.add_component<PositionComponent>(e) = {x, y, 0};
    world.add_component<HazardComponent>(e);

    // Diamond loop: origin → outbound point → a perpendicular waypoint →
    // back. Clamped to room bounds so snakes never leave the arena.
    float mx = (x + outX) * 0.5f, my = (y + outY) * 0.5f;
    float dx = outX - x, dy = outY - y;
    float len = sqrtf(dx * dx + dy * dy);
    float px = len > 0.001f ? -dy / len : 1.f;  // perpendicular
    float py = len > 0.001f ?  dx / len : 0.f;

    auto& path = world.add_component<PathFollowComponent>(e);
    path.count = 4;
    float pts[4][2] = {
        {x, y},
        {mx + px * 120.f, my + py * 120.f},
        {outX, outY},
        {mx - px * 120.f, my - py * 120.f},
    };
    for (int i = 0; i < 4; ++i) {
        path.pts[i][0] = clampf(pts[i][0], kRoomMinX + 40.f, kRoomMaxX - 40.f);
        path.pts[i][1] = clampf(pts[i][1], kRoomMinY + 40.f, kRoomMaxY - 40.f);
    }
    return e;
}

unsigned int HazardSystem_spawn_lava_lob(World& world, float sx, float sy,
                                         float dx, float dy, int poolDamage,
                                         float poolRadius, float poolLifetime) {
    EntityID e = world.defer_create();
    world.add_component<PositionComponent>(e) = {sx, sy, 0.f};
    LavaLobComponent& lob = world.add_component<LavaLobComponent>(e);
    lob.startX = sx;
    lob.startY = sy;
    lob.destX = clampf(dx, kRoomMinX + 40.f, kRoomMaxX - 40.f);
    lob.destY = clampf(dy, kRoomMinY + 40.f, kRoomMaxY - 40.f);
    lob.elapsed = 0.f;
    lob.duration = 1.1f;
    lob.poolDamage = poolDamage;
    lob.poolRadius = poolRadius;
    lob.poolLifetime = poolLifetime;
    return e;
}

void HazardSystem_update(World& world, float gameDt) {
    if (gameDt == 0.f) return; // frozen during HitStop

    uint32_t count = world.entity_count();
    for (EntityID id = 0; id < count; ++id) {
        if (!world.hazards().present(id)) continue;
        if (!world.has_component<PositionComponent>(id)) continue;

        HazardComponent& hz = world.get_component<HazardComponent>(id);
        hz.lifetime -= gameDt;
        if (hz.lifetime <= 0.f) {
            world.defer_destroy(id);
            continue;
        }

        PositionComponent& pos = world.get_component<PositionComponent>(id);
        if (world.has_component<PathFollowComponent>(id)) {
            PathFollowComponent& path = world.get_component<PathFollowComponent>(id);
            path.distance += path.speed * gameDt;
            sample_path(path, &pos.x, &pos.y);
        }

        // Area damage to players inside the radius.
        if (world.players_invincible()) continue; // victory window — no chip
        for (EntityID pid = 0; pid < count; ++pid) {
            if (!world.player_tags().present(pid)) continue;
            if (!world.has_component<PositionComponent>(pid)) continue;
            if (!world.has_component<HealthComponent>(pid)) continue;
            if (world.has_component<DownedComponent>(pid)) continue;
            if (world.has_component<DodgeComponent>(pid)) continue; // i-frames
            if (world.has_component<AnimationComponent>(pid) &&
                world.get_component<AnimationComponent>(pid).dying) continue;
            if (world.has_component<DamageCooldownComponent>(pid) &&
                world.get_component<DamageCooldownComponent>(pid).remaining > 0.f)
                continue;

            const auto& pp = world.get_component<PositionComponent>(pid);
            float dx = pp.x - pos.x, dy = pp.y - pos.y;
            if (dx * dx + dy * dy > hz.radius * hz.radius) continue;
            if (Combat_player_dodges_hit(world, pid)) {
                if (world.has_component<DamageCooldownComponent>(pid))
                    world.get_component<DamageCooldownComponent>(pid).remaining = kHazardRehit;
                continue;
            }

            int damage = world.curse_damage(hz.damage);
            auto& hp = world.get_component<HealthComponent>(pid);
            hp.current -= damage;
            world.events().emit_hit_contact(id, pid);
            world.events().emit_damage(pid, damage);
            ScreenShakeSystem_trigger(world, 12.f);
            if (world.has_component<DamageCooldownComponent>(pid))
                world.get_component<DamageCooldownComponent>(pid).remaining = kHazardRehit;
            if (hp.current <= 0 &&
                !Combat_try_second_wind(world, pid) &&
                world.has_component<AnimationComponent>(pid)) {
                Combat_apply_death(world, pid, id);
            }
        }
    }
}
