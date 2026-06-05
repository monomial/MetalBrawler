#include "DodgeSystem.h"
#include "Simulation/World.h"
#include "Simulation/Components.h"

static constexpr float kDodgeSpeed = 650.0f; // units/sec — faster than walk (300)

void DodgeSystem_update(World& world, float gameDt) {
    if (gameDt == 0.f) return; // frozen during HitStop

    uint32_t count = world.entity_count();
    for (EntityID id = 0; id < count; ++id) {
        if (!world.has_component<AnimationComponent>(id)) continue;
        if (!world.has_component<PlayerTagComponent>(id)) continue; // players only

        AnimationComponent& anim = world.get_component<AnimationComponent>(id);

        // Dodge clip just started (no component yet, clip is live) → arm invincibility + impulse.
        if (anim.currentClip == AnimClipID::Dodge &&
            !anim.clipDone &&
            !world.has_component<DodgeComponent>(id)) {

            DodgeComponent& dodge = world.add_component<DodgeComponent>(id);

            float dx = 0.f, dy = 1.f;
            if (world.has_component<FacingComponent>(id)) {
                const FacingComponent& f = world.get_component<FacingComponent>(id);
                dx = f.dx; dy = f.dy;
            }
            if (world.has_component<VelocityComponent>(id)) {
                VelocityComponent& vel = world.get_component<VelocityComponent>(id);
                vel.vx = dx * kDodgeSpeed;
                vel.vy = dy * kDodgeSpeed;
                vel.vz = 0.f;
            }
            dodge.impulseApplied = true;
        }

        // Dodge animation finished → drop invincibility.
        if (world.has_component<DodgeComponent>(id) &&
            anim.clipDone && anim.currentClip == AnimClipID::Dodge) {
            world.remove_component<DodgeComponent>(id);
        }
    }
}
