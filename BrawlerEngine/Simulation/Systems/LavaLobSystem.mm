#include "LavaLobSystem.h"
#include "Simulation/World.h"
#include "Simulation/Systems/ScreenShakeSystem.h"

static float clampf(float v, float lo, float hi) {
    return v < lo ? lo : (v > hi ? hi : v);
}

void LavaLobSystem_update(World& world, float gameDt) {
    if (gameDt == 0.f) return;

    uint32_t count = world.entity_count();
    for (EntityID id = 0; id < count; ++id) {
        if (!world.lava_lobs().present(id)) continue;
        if (!world.has_component<PositionComponent>(id)) continue;

        LavaLobComponent& lob = world.get_component<LavaLobComponent>(id);
        PositionComponent& pos = world.get_component<PositionComponent>(id);
        lob.elapsed += gameDt;
        float t = clampf(lob.elapsed / lob.duration, 0.f, 1.f);
        pos.x = lob.startX + (lob.destX - lob.startX) * t;
        pos.y = lob.startY + (lob.destY - lob.startY) * t;
        pos.z = 0.f;

        if (t >= 1.f) {
            EntityID pool = world.defer_create();
            world.add_component<PositionComponent>(pool) = {lob.destX, lob.destY, 0.f};
            HazardComponent& hz = world.add_component<HazardComponent>(pool);
            hz.radius = lob.poolRadius;
            hz.damage = lob.poolDamage;
            hz.lifetime = lob.poolLifetime;
            world.events().emit_lava_pool_spawned(lob.destX, lob.destY);
            ScreenShakeSystem_trigger(world, 14.f);
            world.defer_destroy(id);
        }
    }
}
