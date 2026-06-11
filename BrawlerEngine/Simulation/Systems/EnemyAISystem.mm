#include "EnemyAISystem.h"
#include "Simulation/World.h"
#include "Simulation/Systems/AnimationSystem.h"
#include <math.h>

// Defaults for enemies without an EnemyArchetypeComponent — identical to the
// Grunt row in kEnemyArchetypes (keeps pre-archetype behavior and tests).
static constexpr float kEnemySpeed          = 150.0f; // units per second
static constexpr float kStopRadius          = 110.0f; // stop chasing within this distance
static constexpr float kEnemyAttackCooldown = 2.0f;   // seconds between attack initiations
static constexpr float kEnemyAttackWindup   = 0.35f;  // committed warning before punch

void EnemyAISystem_update(World& world, float gameDt) {
    if (gameDt == 0.0f) return; // HitStop — enemies freeze

    // Collect all alive player positions (up to 4) — each enemy targets the nearest.
    PositionComponent playerPositions[4];
    int playerCount = 0;
    {
        auto& tags = world.player_tags();
        uint32_t count = world.entity_count();
        for (EntityID id = 0; id < count && playerCount < 4; ++id) {
            if (!tags.present(id)) continue;
            if (!world.has_component<PositionComponent>(id)) continue;
            if (world.has_component<DownedComponent>(id)) continue;
            if (world.has_component<AnimationComponent>(id) &&
                world.get_component<AnimationComponent>(id).dying) continue;
            playerPositions[playerCount++] = world.get_component<PositionComponent>(id);
        }
    }
    if (playerCount == 0) return;

    uint32_t count = world.entity_count();
    auto& factions = world.factions();
    for (EntityID id = 0; id < count; ++id) {
        if (!factions.present(id)) continue;
        if (factions.get(id).type != FactionComponent::Enemy) continue;
        if (!world.has_component<PositionComponent>(id)) continue;
        if (world.has_component<AnimationComponent>(id) &&
            world.get_component<AnimationComponent>(id).dying) continue;

        const PositionComponent& ePos = world.get_component<PositionComponent>(id);

        // Per-archetype tuning, defaulting to the original grunt constants.
        float moveSpeed  = kEnemySpeed;
        float stopRadius = kStopRadius;
        float cooldown   = kEnemyAttackCooldown;
        bool isRusher = false;
        if (world.has_component<EnemyArchetypeComponent>(id)) {
            isRusher = world.get_component<EnemyArchetypeComponent>(id).type == (uint8_t)EnemyArchetype::Rusher;
            const EnemyArchetypeDef& def =
                enemy_archetype_def(world.get_component<EnemyArchetypeComponent>(id).type);
            moveSpeed  = def.moveSpeed;
            stopRadius = def.stopRadius;
            cooldown   = def.attackCooldown;
        }

        // Find nearest alive player.
        PositionComponent playerPos = playerPositions[0];
        float dist = sqrtf((playerPos.x-ePos.x)*(playerPos.x-ePos.x) +
                           (playerPos.y-ePos.y)*(playerPos.y-ePos.y));
        for (int pi = 1; pi < playerCount; ++pi) {
            float d = sqrtf((playerPositions[pi].x-ePos.x)*(playerPositions[pi].x-ePos.x) +
                            (playerPositions[pi].y-ePos.y)*(playerPositions[pi].y-ePos.y));
            if (d < dist) { dist = d; playerPos = playerPositions[pi]; }
        }

        float dx = playerPos.x - ePos.x;
        float dy = playerPos.y - ePos.y;

        // Always face toward the player.
        if (world.has_component<FacingComponent>(id) && dist > 0.001f) {
            FacingComponent& facing = world.get_component<FacingComponent>(id);
            facing.dx = dx / dist;
            facing.dy = dy / dist;
        }

        bool windupFinished = false;

        // Tick down attack cooldown and any committed wind-up.
        if (world.has_component<EnemyAttackCooldownComponent>(id)) {
            auto& cd = world.get_component<EnemyAttackCooldownComponent>(id);
            cd.remaining -= gameDt;
            if (cd.remaining < 0.f) cd.remaining = 0.f;
            if (cd.windup > 0.f) {
                cd.windup -= gameDt;
                if (cd.windup <= 0.f) {
                    cd.windup = 0.f;
                    windupFinished = true;
                }
            }
        }

        if (!world.has_component<VelocityComponent>(id))
            world.add_component<VelocityComponent>(id) = {};

        VelocityComponent& vel = world.get_component<VelocityComponent>(id);
        bool moving;

        bool windingUp = world.has_component<EnemyAttackCooldownComponent>(id) &&
                         world.get_component<EnemyAttackCooldownComponent>(id).windup > 0.f;

        if (windingUp) {
            vel = {0.f, 0.f, 0.f};
            moving = false;
        } else if (dist <= stopRadius) {
            vel = {0.f, 0.f, 0.f};
            moving = false;
        } else {
            vel.vx = (dx / dist) * moveSpeed;
            vel.vy = (dy / dist) * moveSpeed;
            vel.vz = 0.f;
            moving = true;
        }

        if (!world.has_component<AnimationComponent>(id)) continue;

        // Determine what animation to request.
        // Non-looping clips (Attack, Hurt) play through fully before this takes effect,
        // so it's safe to call every tick — the request is just queued.
        AnimClipID nextClip = moving ? (isRusher ? AnimClipID::Run : AnimClipID::Walk)
                                     : AnimClipID::Idle;

        if (windupFinished) {
            nextClip = AnimClipID::Attack;
        } else if (!moving && world.has_component<EnemyAttackCooldownComponent>(id)) {
            auto& cd = world.get_component<EnemyAttackCooldownComponent>(id);
            if (cd.windup <= 0.f && cd.remaining <= 0.f) {
                cd.windup = kEnemyAttackWindup;
                cd.remaining = cooldown;
            }
        }

        AnimationSystem_request_clip(world, id, nextClip);
    }
}
