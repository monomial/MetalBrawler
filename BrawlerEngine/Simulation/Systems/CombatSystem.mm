#include "CombatSystem.h"
#include "Simulation/World.h"
#include "Platform/InputState.h"
#include "Simulation/Systems/AnimationSystem.h"
#include "Simulation/Systems/ScreenShakeSystem.h"
#include <math.h>

static constexpr float kAttackRange  = 80.0f; // units — larger than EnemyAI stop radius
static constexpr int   kAttackDamage = 1;
static constexpr int   kHitStopTicks = 4;     // ~33ms freeze on hit

void CombatSystem_update(World& world, float gameDt) {
    if (gameDt == 0.0f) return; // already frozen — no new hits this tick

    const InputState input = world.current_input();
    if (!input.attack) return;

    // Find the player.
    EntityID playerID = kInvalidEntity;
    uint32_t count = world.entity_count();
    for (EntityID id = 0; id < count; ++id) {
        if (world.player_tags().present(id)) { playerID = id; break; }
    }
    if (playerID == kInvalidEntity) return;
    if (!world.has_component<PositionComponent>(playerID)) return;
    // Dead players cannot attack.
    if (world.has_component<AnimationComponent>(playerID) &&
        world.get_component<AnimationComponent>(playerID).dying) return;

    const PositionComponent playerPos = world.get_component<PositionComponent>(playerID);

    bool hitAnything = false;

    for (EntityID id = 0; id < count; ++id) {
        if (!world.factions().present(id)) continue;
        if (world.factions().get(id).type != FactionComponent::Enemy) continue;
        if (!world.has_component<PositionComponent>(id)) continue;
        if (!world.has_component<HealthComponent>(id)) continue;
        // Skip entities already in their death animation.
        if (world.has_component<AnimationComponent>(id) &&
            world.get_component<AnimationComponent>(id).dying) continue;

        const PositionComponent& ePos = world.get_component<PositionComponent>(id);
        float dx   = ePos.x - playerPos.x;
        float dy   = ePos.y - playerPos.y;
        float dist = sqrtf(dx * dx + dy * dy);
        if (dist > kAttackRange) continue;

        HealthComponent& hp = world.get_component<HealthComponent>(id);
        hp.current -= kAttackDamage;
        hitAnything = true;

        world.events().emit_hit_contact(playerID, id);
        world.events().emit_damage(id, kAttackDamage);

        if (hp.current <= 0) {
            world.events().emit_died(id);
            if (world.has_component<AnimationComponent>(id)) {
                // AnimationSystem destroys the entity after the death clip finishes.
                world.get_component<AnimationComponent>(id).dying = true;
                AnimationSystem_request_clip(world, id, AnimClipID::Death);
            } else {
                world.defer_destroy(id); // no animation — destroy immediately
            }
        } else if (world.has_component<AnimationComponent>(id)) {
            AnimationSystem_request_clip(world, id, AnimClipID::Hurt);
        }
    }

    if (hitAnything) {
        world.trigger_hit_stop(kHitStopTicks);
        ScreenShakeSystem_trigger(world, 18.f);
    }
}
