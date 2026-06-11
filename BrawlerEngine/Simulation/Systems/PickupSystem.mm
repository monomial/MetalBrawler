#include "PickupSystem.h"
#include "Simulation/World.h"
#include <math.h>

static constexpr float kPickupRadius = 55.0f;

void PickupSystem_update(World& world, float gameDt) {
    if (gameDt == 0.0f) return;

    uint32_t count = world.entity_count();
    for (EntityID heartID = 0; heartID < count; ++heartID) {
        if (!world.heart_pickups().present(heartID)) continue;
        if (!world.has_component<PositionComponent>(heartID)) continue;

        HeartPickupComponent& heart = world.get_component<HeartPickupComponent>(heartID);
        heart.lifetime -= gameDt;
        if (heart.lifetime <= 0.f) {
            world.defer_destroy(heartID);
            continue;
        }

        const PositionComponent& hpos = world.get_component<PositionComponent>(heartID);
        bool collected = false;
        for (EntityID playerID = 0; playerID < count; ++playerID) {
            if (!world.player_tags().present(playerID)) continue;
            if (!world.has_component<PositionComponent>(playerID)) continue;
            if (!world.has_component<HealthComponent>(playerID)) continue;
            if (world.has_component<DownedComponent>(playerID)) continue;
            if (world.has_component<AnimationComponent>(playerID) &&
                world.get_component<AnimationComponent>(playerID).dying) continue;

            HealthComponent& hp = world.get_component<HealthComponent>(playerID);
            if (hp.current >= hp.max) continue;

            const PositionComponent& ppos = world.get_component<PositionComponent>(playerID);
            float dx = ppos.x - hpos.x;
            float dy = ppos.y - hpos.y;
            if (dx * dx + dy * dy > kPickupRadius * kPickupRadius) continue;

            hp.current += 3;
            if (hp.current > hp.max) hp.current = hp.max;
            world.defer_destroy(heartID);
            world.events().emit_pickup_collected(playerID);
            collected = true;
            break;
        }
        if (collected) continue;
    }
}
