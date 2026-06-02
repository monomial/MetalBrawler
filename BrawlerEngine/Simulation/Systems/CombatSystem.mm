#include "CombatSystem.h"
#include "Simulation/World.h"
#include "Platform/InputState.h"
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

    const PositionComponent playerPos = world.get_component<PositionComponent>(playerID);

    bool hitAnything = false;

    for (EntityID id = 0; id < count; ++id) {
        if (!world.factions().present(id)) continue;
        if (world.factions().get(id).type != FactionComponent::Enemy) continue;
        if (!world.has_component<PositionComponent>(id)) continue;
        if (!world.has_component<HealthComponent>(id)) continue;

        const PositionComponent& ePos = world.get_component<PositionComponent>(id);
        float dx   = ePos.x - playerPos.x;
        float dy   = ePos.y - playerPos.y;
        float dist = sqrtf(dx * dx + dy * dy);
        if (dist > kAttackRange) continue;

        HealthComponent& hp = world.get_component<HealthComponent>(id);
        hp.current -= kAttackDamage;
        hitAnything = true;

        if (hp.current <= 0) {
            world.defer_destroy(id);
        }
    }

    if (hitAnything) {
        world.trigger_hit_stop(kHitStopTicks);
    }
}
