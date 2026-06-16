#include "DodgeSystem.h"
#include "Simulation/World.h"
#include "Simulation/Components.h"
#include "Platform/InputState.h"
#include "Simulation/Systems/AnimationSystem.h"
#include <math.h>

static constexpr float kDodgeMinDuration = 0.15f;
static constexpr float kDodgeMaxDuration = 0.40f;
static constexpr float kDodgeRegenPerCharge = 1.5f;
static constexpr float kDodgeSpeed = 650.0f; // units/sec at start of roll

static float dodge_regen_duration(World& world, EntityID id) {
    float mult = 1.f;
    if (world.has_component<StatsComponent>(id))
        mult = world.get_component<StatsComponent>(id).dodgeCooldownMult;
    return kDodgeRegenPerCharge * mult;
}

static void capture_dodge_velocity(World& world, EntityID id, DodgeComponent& dodge) {
    float dx = 0.f, dy = 1.f;
    const PlayerTagComponent& tag = world.get_component<PlayerTagComponent>(id);
    const InputState input = world.current_input(tag.playerIndex);
    float len = sqrtf(input.moveX * input.moveX + input.moveY * input.moveY);
    if (len > 0.01f) {
        dx = input.moveX / len;
        dy = input.moveY / len;
    } else if (world.has_component<FacingComponent>(id)) {
        const FacingComponent& f = world.get_component<FacingComponent>(id);
        dx = f.dx;
        dy = f.dy;
    }
    dodge.velX = dx * kDodgeSpeed;
    dodge.velY = dy * kDodgeSpeed;
    dodge.active = true;
    dodge.elapsed = 0.f;
}

void DodgeSystem_update(World& world, float gameDt) {
    if (gameDt == 0.f) return; // frozen during HitStop

    uint32_t count = world.entity_count();
    for (EntityID id = 0; id < count; ++id) {
        if (!world.has_component<PlayerTagComponent>(id)) continue;

        bool dodging = world.has_component<DodgeComponent>(id);
        if (world.has_component<DodgeChargesComponent>(id) && !dodging) {
            DodgeChargesComponent& charges = world.get_component<DodgeChargesComponent>(id);
            if (charges.charges < charges.maxCharges) {
                if (charges.regenTimer <= 0.f)
                    charges.regenTimer = dodge_regen_duration(world, id);
                charges.regenTimer -= gameDt;
                while (charges.regenTimer <= 0.f && charges.charges < charges.maxCharges) {
                    charges.charges += 1;
                    if (charges.charges < charges.maxCharges)
                        charges.regenTimer += dodge_regen_duration(world, id);
                    else
                        charges.regenTimer = 0.f;
                }
            } else {
                charges.regenTimer = 0.f;
            }
        }

        if (!world.has_component<AnimationComponent>(id)) continue;

        AnimationComponent& anim = world.get_component<AnimationComponent>(id);

        // Dodge clip just started → arm invincibility, capture roll direction.
        if (anim.currentClip == AnimClipID::Dodge &&
            !anim.clipDone &&
            !world.has_component<DodgeComponent>(id)) {

            DodgeComponent& dodge = world.add_component<DodgeComponent>(id);
            capture_dodge_velocity(world, id, dodge);
        }

        if (!world.has_component<DodgeComponent>(id)) continue;
        DodgeComponent& dodge = world.get_component<DodgeComponent>(id);
        if (!dodge.active && anim.currentClip != AnimClipID::Dodge) continue;
        const PlayerTagComponent& tag = world.get_component<PlayerTagComponent>(id);
        const InputState input = world.current_input(tag.playerIndex);
        dodge.elapsed += gameDt;

        // Decelerate velocity over the system-owned dodge window.
        if (dodge.active && world.has_component<VelocityComponent>(id)) {
            float progress = fminf(dodge.elapsed / kDodgeMaxDuration, 1.f);
            float scale = fmaxf(1.f - progress, 0.f);

            VelocityComponent& vel = world.get_component<VelocityComponent>(id);
            vel.vx = dodge.velX * scale;
            vel.vy = dodge.velY * scale;
        }

        bool endDodge = dodge.elapsed >= kDodgeMaxDuration ||
                        (dodge.elapsed >= kDodgeMinDuration && !input.dodge);
        if (!endDodge) continue;

        if (input.dodge &&
            world.has_component<DodgeChargesComponent>(id) &&
            world.get_component<DodgeChargesComponent>(id).charges > 0) {
            DodgeChargesComponent& charges = world.get_component<DodgeChargesComponent>(id);
            bool wasFull = charges.charges >= charges.maxCharges;
            charges.charges -= 1;
            if (wasFull || charges.regenTimer <= 0.f)
                charges.regenTimer = dodge_regen_duration(world, id);
            capture_dodge_velocity(world, id, dodge);
            anim.currentClip = AnimClipID::Dodge;
            anim.requestedClip = AnimClipID::Dodge;
            anim.clipTime = 0.f;
            anim.clipDone = false;
            anim.looping = false;
            AnimationSystem_request_clip(world, id, AnimClipID::Dodge);
            continue;
        }

        if (world.has_component<VelocityComponent>(id)) {
            VelocityComponent& vel = world.get_component<VelocityComponent>(id);
            vel.vx = vel.vy = 0.f;
        }
        world.remove_component<DodgeComponent>(id);
        anim.currentClip = AnimClipID::Idle;
        anim.requestedClip = AnimClipID::Idle;
        anim.clipTime = 0.f;
        anim.clipDone = false;
        anim.looping = true;
        AnimationSystem_request_clip(world, id, AnimClipID::Idle);
    }
}
