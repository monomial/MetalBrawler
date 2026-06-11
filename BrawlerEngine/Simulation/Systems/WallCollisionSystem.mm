#include "WallCollisionSystem.h"
#include "Simulation/World.h"
#include "Simulation/RoomBounds.h"
#include <math.h>

static constexpr float kCharacterRadius = 40.f;

static float clampf(float v, float lo, float hi) {
    if (v < lo) return lo;
    if (v > hi) return hi;
    return v;
}

void WallCollisionSystem_update(World& world, float gameDt) {
    if (gameDt == 0.f) return; // frozen during HitStop

    uint32_t count = world.entity_count();
    for (EntityID id = 0; id < count; ++id) {
        if (!world.has_component<PositionComponent>(id)) continue;

        PositionComponent& pos = world.get_component<PositionComponent>(id);
        bool hitX = false, hitY = false;

        if (pos.x < kRoomMinX) { pos.x = kRoomMinX; hitX = true; }
        if (pos.x > kRoomMaxX) { pos.x = kRoomMaxX; hitX = true; }
        if (pos.y < kRoomMinY) { pos.y = kRoomMinY; hitY = true; }
        if (pos.y > kRoomMaxY) { pos.y = kRoomMaxY; hitY = true; }

        if ((hitX || hitY) && world.has_component<VelocityComponent>(id)) {
            VelocityComponent& vel = world.get_component<VelocityComponent>(id);
            if (hitX) vel.vx = 0.f;
            if (hitY) vel.vy = 0.f;
        }

        if (!world.has_component<VelocityComponent>(id)) continue;
        if (world.hazards().present(id)) continue;
        if (world.heart_pickups().present(id)) continue;
        if (world.obstacles().present(id)) continue;

        VelocityComponent& vel = world.get_component<VelocityComponent>(id);
        for (EntityID oid = 0; oid < count; ++oid) {
            if (!world.obstacles().present(oid)) continue;
            if (!world.has_component<PositionComponent>(oid)) continue;

            const PositionComponent& opos = world.get_component<PositionComponent>(oid);
            const ObstacleComponent& obs = world.get_component<ObstacleComponent>(oid);
            float minX = opos.x - obs.halfW;
            float maxX = opos.x + obs.halfW;
            float minY = opos.y - obs.halfH;
            float maxY = opos.y + obs.halfH;
            float cx = clampf(pos.x, minX, maxX);
            float cy = clampf(pos.y, minY, maxY);
            float dx = pos.x - cx;
            float dy = pos.y - cy;
            float d2 = dx * dx + dy * dy;
            float r2 = kCharacterRadius * kCharacterRadius;
            if (d2 >= r2) continue;

            if (d2 > 1e-6f) {
                float d = sqrtf(d2);
                float push = kCharacterRadius - d;
                pos.x += (dx / d) * push;
                pos.y += (dy / d) * push;

                if (fabsf(dx) > 1e-6f && fabsf(dy) <= 1e-6f) vel.vx = 0.f;
                if (fabsf(dy) > 1e-6f && fabsf(dx) <= 1e-6f) vel.vy = 0.f;
            } else {
                float inflatedHalfW = obs.halfW + kCharacterRadius;
                float inflatedHalfH = obs.halfH + kCharacterRadius;
                float centerDx = pos.x - opos.x;
                float centerDy = pos.y - opos.y;
                float overlapX = inflatedHalfW - fabsf(centerDx);
                float overlapY = inflatedHalfH - fabsf(centerDy);
                if (overlapX <= 0.f || overlapY <= 0.f) continue;

                if (overlapX < overlapY) {
                    pos.x += (centerDx >= 0.f) ? overlapX : -overlapX;
                    vel.vx = 0.f;
                } else {
                    pos.y += (centerDy >= 0.f) ? overlapY : -overlapY;
                    vel.vy = 0.f;
                }
            }
        }
    }
}
