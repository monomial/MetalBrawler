#include "WallCollisionSystem.h"
#include "Simulation/World.h"
#include "Simulation/RoomBounds.h"

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
    }
}
