#include "InputSystem.h"
#include "Simulation/World.h"
#include "Platform/InputState.h"
#include "Simulation/Systems/AnimationSystem.h"
#include <math.h>

static constexpr float kPlayerSpeed = 300.0f; // units per second

void InputSystem_update(World& world) {
    // Find the player entity — the one with PlayerTagComponent.
    EntityID playerID = kInvalidEntity;
    auto& tags = world.player_tags();
    for (EntityID id = 0; id < world.entity_count(); ++id) {
        if (tags.present(id)) { playerID = id; break; }
    }
    if (playerID == kInvalidEntity) return;
    // Ignore input while player is dying — zero velocity so they stop in place.
    if (world.has_component<AnimationComponent>(playerID) &&
        world.get_component<AnimationComponent>(playerID).dying) {
        if (world.has_component<VelocityComponent>(playerID)) {
            VelocityComponent& vel = world.get_component<VelocityComponent>(playerID);
            vel.vx = vel.vy = vel.vz = 0.0f;
        }
        return;
    }

    const InputState input = world.current_input();

    // Normalize diagonal movement so speed is constant in all directions.
    float mx = input.moveX;
    float my = input.moveY;
    float len = sqrtf(mx * mx + my * my);
    if (len > 1.0f) { mx /= len; my /= len; }

    // Ensure player has a VelocityComponent; create it on first input.
    if (!world.has_component<VelocityComponent>(playerID))
        world.add_component<VelocityComponent>(playerID) = {};

    VelocityComponent& vel = world.get_component<VelocityComponent>(playerID);
    vel.vx = mx * kPlayerSpeed;
    vel.vy = my * kPlayerSpeed;
    vel.vz = 0.0f;

    // Update facing whenever the player is actually moving.
    // Stays at last value when standing still so punching while idle faces correctly.
    if ((mx * mx + my * my) > 0.01f && world.has_component<FacingComponent>(playerID)) {
        FacingComponent& facing = world.get_component<FacingComponent>(playerID);
        facing.dx = mx; // already normalized above
        facing.dy = my;
    }

    if (world.has_component<AnimationComponent>(playerID)) {
        bool moving = (mx * mx + my * my) > 0.01f;
        AnimClipID want = input.attack ? AnimClipID::Attack
                        : moving       ? AnimClipID::Walk
                                       : AnimClipID::Idle;
        AnimationSystem_request_clip(world, playerID, want);
    }
}
