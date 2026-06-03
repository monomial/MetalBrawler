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

        // Ignore input while dying.
        if (world.has_component<AnimationComponent>(id) &&
            world.get_component<AnimationComponent>(id).dying) {
            if (world.has_component<VelocityComponent>(id)) {
                VelocityComponent& vel = world.get_component<VelocityComponent>(id);
                vel.vx = vel.vy = vel.vz = 0.0f;
            }
            continue;
        }

        const InputState input = world.current_input(tag.playerIndex);

        float mx = input.moveX;
        float my = input.moveY;
        float len = sqrtf(mx * mx + my * my);
        if (len > 1.0f) { mx /= len; my /= len; }

        if (!world.has_component<VelocityComponent>(id))
            world.add_component<VelocityComponent>(id) = {};

        VelocityComponent& vel = world.get_component<VelocityComponent>(id);
        vel.vx = mx * kPlayerSpeed;
        vel.vy = my * kPlayerSpeed;
        vel.vz = 0.0f;

        // Update facing whenever the player is actually moving.
        if ((mx * mx + my * my) > 0.01f && world.has_component<FacingComponent>(id)) {
            FacingComponent& facing = world.get_component<FacingComponent>(id);
            facing.dx = mx;
            facing.dy = my;
        }

        if (world.has_component<AnimationComponent>(id)) {
            bool moving = (mx * mx + my * my) > 0.01f;
            AnimClipID want = input.attack ? AnimClipID::Attack
                            : moving       ? AnimClipID::Walk
                                           : AnimClipID::Idle;
            AnimationSystem_request_clip(world, id, want);
        }
    }
}
