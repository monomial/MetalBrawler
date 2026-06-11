#include "ExitSystem.h"
#include <math.h>

void ExitSystem_update(World& world, float gameDt) {
    if (gameDt == 0.f) return;

    for (EntityID exitID = 0; exitID < world.entity_count(); ++exitID) {
        if (!world.exits().present(exitID)) continue;
        if (!world.has_component<PositionComponent>(exitID)) continue;
        const PositionComponent& exitPos = world.get_component<PositionComponent>(exitID);

        for (EntityID pid = 0; pid < world.entity_count(); ++pid) {
            if (!world.player_tags().present(pid)) continue;
            if (!world.has_component<PositionComponent>(pid)) continue;
            if (!world.has_component<HealthComponent>(pid)) continue;
            if (world.get_component<HealthComponent>(pid).current <= 0) continue;
            if (world.has_component<DownedComponent>(pid)) continue;
            if (world.has_component<AnimationComponent>(pid) &&
                world.get_component<AnimationComponent>(pid).dying) continue;

            const PositionComponent& p = world.get_component<PositionComponent>(pid);
            float dx = p.x - exitPos.x;
            float dy = p.y - exitPos.y;
            if (dx * dx + dy * dy > kExitRadius * kExitRadius) continue;

            world.events().emit_exit_reached(exitID);
            world.defer_destroy(exitID);
            return;
        }
    }
}
