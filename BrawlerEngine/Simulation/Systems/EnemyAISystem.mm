#include "EnemyAISystem.h"
#include "Simulation/World.h"
#include "Simulation/Systems/AnimationSystem.h"
#include <math.h>

static constexpr float kEnemySpeed          = 150.0f; // units per second
static constexpr float kStopRadius          = 80.0f;  // stop chasing within this distance
static constexpr float kEnemyAttackCooldown = 2.0f;   // seconds between attack initiations

void EnemyAISystem_update(World& world, float gameDt) {
    if (gameDt == 0.0f) return; // HitStop — enemies freeze

    EntityID playerID = kInvalidEntity;
    auto& tags = world.player_tags();
    uint32_t count = world.entity_count();
    for (EntityID id = 0; id < count; ++id) {
        if (tags.present(id)) { playerID = id; break; }
    }
    if (playerID == kInvalidEntity) return;
    if (!world.has_component<PositionComponent>(playerID)) return;

    const PositionComponent playerPos = world.get_component<PositionComponent>(playerID);

    auto& factions = world.factions();
    for (EntityID id = 0; id < count; ++id) {
        if (!factions.present(id)) continue;
        if (factions.get(id).type != FactionComponent::Enemy) continue;
        if (!world.has_component<PositionComponent>(id)) continue;
        if (world.has_component<AnimationComponent>(id) &&
            world.get_component<AnimationComponent>(id).dying) continue;

        const PositionComponent& ePos = world.get_component<PositionComponent>(id);
        float dx   = playerPos.x - ePos.x;
        float dy   = playerPos.y - ePos.y;
        float dist = sqrtf(dx * dx + dy * dy);

        // Always face toward the player.
        if (world.has_component<FacingComponent>(id) && dist > 0.001f) {
            FacingComponent& facing = world.get_component<FacingComponent>(id);
            facing.dx = dx / dist;
            facing.dy = dy / dist;
        }

        // Tick down attack cooldown.
        if (world.has_component<EnemyAttackCooldownComponent>(id)) {
            auto& cd = world.get_component<EnemyAttackCooldownComponent>(id);
            cd.remaining -= gameDt;
            if (cd.remaining < 0.f) cd.remaining = 0.f;
        }

        if (!world.has_component<VelocityComponent>(id))
            world.add_component<VelocityComponent>(id) = {};

        VelocityComponent& vel = world.get_component<VelocityComponent>(id);
        bool moving;

        if (dist <= kStopRadius) {
            vel = {0.f, 0.f, 0.f};
            moving = false;
        } else {
            vel.vx = (dx / dist) * kEnemySpeed;
            vel.vy = (dy / dist) * kEnemySpeed;
            vel.vz = 0.f;
            moving = true;
        }

        if (!world.has_component<AnimationComponent>(id)) continue;

        // Determine what animation to request.
        // Non-looping clips (Attack, Hurt) play through fully before this takes effect,
        // so it's safe to call every tick — the request is just queued.
        AnimClipID nextClip = moving ? AnimClipID::Walk : AnimClipID::Idle;

        if (!moving && world.has_component<EnemyAttackCooldownComponent>(id)) {
            auto& cd = world.get_component<EnemyAttackCooldownComponent>(id);
            if (cd.remaining <= 0.f) {
                nextClip = AnimClipID::Attack;
                cd.remaining = kEnemyAttackCooldown;
            }
        }

        AnimationSystem_request_clip(world, id, nextClip);
    }
}
