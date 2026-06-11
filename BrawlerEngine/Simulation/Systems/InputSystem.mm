#include "InputSystem.h"
#include "Simulation/World.h"
#include "Platform/InputState.h"
#include "Simulation/Systems/AnimationSystem.h"
#include <math.h>

static constexpr float kPlayerSpeed = 300.0f; // units per second

void InputSystem_update(World& world) {
    uint32_t count = world.entity_count();
    auto& tags = world.player_tags();

    // Process every player entity independently using its playerIndex.
    for (EntityID id = 0; id < count; ++id) {
        if (!tags.present(id)) continue;

        const PlayerTagComponent& tag = world.get_component<PlayerTagComponent>(id);

        // Ignore input while downed or dying.
        if (world.has_component<DownedComponent>(id) ||
            (world.has_component<AnimationComponent>(id) &&
             world.get_component<AnimationComponent>(id).dying)) {
            if (world.has_component<VelocityComponent>(id)) {
                VelocityComponent& vel = world.get_component<VelocityComponent>(id);
                vel.vx = vel.vy = vel.vz = 0.0f;
            }
            continue;
        }

        // Lock input while dodge is active — DodgeSystem owns velocity for this duration.
        if (world.has_component<DodgeComponent>(id)) continue;

        const InputState input = world.current_input(tag.playerIndex);

        float mx = input.moveX;
        float my = input.moveY;
        float len = sqrtf(mx * mx + my * my);
        if (len > 1.0f) { mx /= len; my /= len; }

        if (!world.has_component<VelocityComponent>(id))
            world.add_component<VelocityComponent>(id) = {};

        float speed = kPlayerSpeed;
        if (world.has_component<StatsComponent>(id))
            speed *= world.get_component<StatsComponent>(id).speedMult;

        VelocityComponent& vel = world.get_component<VelocityComponent>(id);
        vel.vx = mx * speed;
        vel.vy = my * speed;
        vel.vz = 0.0f;

        // Update facing whenever the player is actually moving.
        if ((mx * mx + my * my) > 0.01f && world.has_component<FacingComponent>(id)) {
            FacingComponent& facing = world.get_component<FacingComponent>(id);
            facing.dx = mx;
            facing.dy = my;
        }

        if (world.has_component<AnimationComponent>(id)) {
            bool moving = (mx * mx + my * my) > 0.01f;
            AnimationComponent& anim = world.get_component<AnimationComponent>(id);

            // Combo: an attack press while the first punch is past 35% of its
            // clip queues the finisher — AnimationSystem chains into Attack2
            // when the Attack clip completes.
            if (input.attack && anim.currentClip == AnimClipID::Attack) {
                float dur = AnimationSystem_clip_duration(world, id, AnimClipID::Attack);
                if (anim.clipTime > 0.35f * dur)
                    anim.comboQueued = true;
            }

            // Dodge: allowed from Idle or Walk (not mid-attack, hurt, death, or another dodge).
            bool canDodge = input.dodge &&
                            (anim.currentClip == AnimClipID::Idle ||
                             anim.currentClip == AnimClipID::Walk);
            AnimClipID want = canDodge      ? AnimClipID::Dodge
                            : input.attack  ? AnimClipID::Attack
                            : moving        ? AnimClipID::Walk
                                            : AnimClipID::Idle;
            AnimationSystem_request_clip(world, id, want);
        }
    }
}
