#include "KnockbackSystem.h"
#include "Simulation/World.h"

void KnockbackSystem_update(World& world, float gameDt) {
    if (gameDt == 0.f) return; // frozen during HitStop

    uint32_t count = world.entity_count();
    for (EntityID id = 0; id < count; ++id) {
        if (!world.knockbacks().present(id)) continue;

        // A target killed mid-shove must not slide through its death animation.
        if (world.has_component<AnimationComponent>(id) &&
            world.get_component<AnimationComponent>(id).dying) {
            if (world.has_component<VelocityComponent>(id)) {
                VelocityComponent& vel = world.get_component<VelocityComponent>(id);
                vel.vx = vel.vy = vel.vz = 0.f;
            }
            world.remove_component<KnockbackComponent>(id);
            continue;
        }

        KnockbackComponent& kb = world.get_component<KnockbackComponent>(id);
        kb.elapsed += gameDt;

        if (kb.elapsed >= kb.duration || kb.duration <= 0.f) {
            // Shove finished — release velocity back to AI/input next tick.
            if (world.has_component<VelocityComponent>(id)) {
                VelocityComponent& vel = world.get_component<VelocityComponent>(id);
                vel.vx = vel.vy = 0.f;
            }
            world.remove_component<KnockbackComponent>(id);
            continue;
        }

        if (!world.has_component<VelocityComponent>(id)) continue;
        float t = 1.f - kb.elapsed / kb.duration; // 1 → 0 linear decay
        VelocityComponent& vel = world.get_component<VelocityComponent>(id);
        vel.vx = kb.velX * t;
        vel.vy = kb.velY * t;
        vel.vz = 0.f;
    }
}
