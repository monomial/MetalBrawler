#include "DodgeSystem.h"
#include "Simulation/World.h"
#include "Simulation/Components.h"
#include "Simulation/Systems/AnimationSystem.h"
#include <math.h>

static constexpr float kDodgeSpeed = 650.0f; // units/sec at start of roll

void DodgeSystem_update(World& world, float gameDt) {
    if (gameDt == 0.f) return; // frozen during HitStop

    uint32_t count = world.entity_count();
    for (EntityID id = 0; id < count; ++id) {
        if (!world.has_component<AnimationComponent>(id)) continue;
        if (!world.has_component<PlayerTagComponent>(id)) continue;

        AnimationComponent& anim = world.get_component<AnimationComponent>(id);

        // Dodge clip just started → arm invincibility, capture roll direction.
        if (anim.currentClip == AnimClipID::Dodge &&
            !anim.clipDone &&
            !world.has_component<DodgeComponent>(id)) {

            DodgeComponent& dodge = world.add_component<DodgeComponent>(id);

            float dx = 0.f, dy = 1.f;
            if (world.has_component<FacingComponent>(id)) {
                const FacingComponent& f = world.get_component<FacingComponent>(id);
                dx = f.dx; dy = f.dy;
            }
            dodge.velX  = dx * kDodgeSpeed;
            dodge.velY  = dy * kDodgeSpeed;
            dodge.active = true;
        }

        if (!world.has_component<DodgeComponent>(id)) continue;
        DodgeComponent& dodge = world.get_component<DodgeComponent>(id);

        // Decelerate velocity over the clip so the player stops when the
        // animation enters its recovery/stand-up phase.
        // progress = 0 at roll start → 1 at clip end; speed = full → 0.
        if (dodge.active && world.has_component<VelocityComponent>(id)) {
            float clipDur = AnimationSystem_clip_duration(world, id, AnimClipID::Dodge);
            float progress = (clipDur > 0.f) ? fminf(anim.clipTime / clipDur, 1.f) : 1.f;
            float scale = fmaxf(1.f - progress, 0.f);

            VelocityComponent& vel = world.get_component<VelocityComponent>(id);
            vel.vx = dodge.velX * scale;
            vel.vy = dodge.velY * scale;
        }

        // Clip finished → drop invincibility and ensure velocity is zeroed.
        if (anim.clipDone && anim.currentClip == AnimClipID::Dodge) {
            if (world.has_component<VelocityComponent>(id)) {
                VelocityComponent& vel = world.get_component<VelocityComponent>(id);
                vel.vx = vel.vy = 0.f;
            }
            world.remove_component<DodgeComponent>(id);
        }
    }
}
