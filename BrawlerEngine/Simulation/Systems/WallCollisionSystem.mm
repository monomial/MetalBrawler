#include "WallCollisionSystem.h"
#include "Simulation/World.h"
#include "Simulation/RoomBounds.h"
#include <math.h>

static constexpr float kCharacterRadius = 40.f;

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
            float inflatedHalfW = obs.halfW + kCharacterRadius;
            float inflatedHalfH = obs.halfH + kCharacterRadius;
            float dx = pos.x - opos.x;
            float dy = pos.y - opos.y;
            float overlapX = inflatedHalfW - fabsf(dx);
            float overlapY = inflatedHalfH - fabsf(dy);
            if (overlapX <= 0.f || overlapY <= 0.f) continue;

            if (overlapX < overlapY) {
                pos.x += (dx >= 0.f) ? overlapX : -overlapX;
                vel.vx = 0.f;
            } else {
                pos.y += (dy >= 0.f) ? overlapY : -overlapY;
                vel.vy = 0.f;
            }
        }
    }
}
