#include "EnemyAISystem.h"
#include "Simulation/World.h"
#include <math.h>

static constexpr float kEnemySpeed     = 150.0f; // units per second
static constexpr float kStopRadius     = 30.0f;  // stop steering within this distance

void EnemyAISystem_update(World& world, float gameDt) {
    if (gameDt == 0.0f) return; // HitStop — enemies freeze

    // Find the player position.
    EntityID playerID = kInvalidEntity;
    auto& tags = world.player_tags();
    uint32_t count = world.entity_count();
    for (EntityID id = 0; id < count; ++id) {
        if (tags.present(id)) { playerID = id; break; }
    }
    if (playerID == kInvalidEntity) return;
    if (!world.has_component<PositionComponent>(playerID)) return;

    const PositionComponent playerPos = world.get_component<PositionComponent>(playerID);

    // Steer each enemy toward the player.
    auto& factions = world.factions();
    for (EntityID id = 0; id < count; ++id) {
        if (!factions.present(id)) continue;
        if (factions.get(id).type != FactionComponent::Enemy) continue;
        if (!world.has_component<PositionComponent>(id)) continue;

        const PositionComponent& ePos = world.get_component<PositionComponent>(id);

        float dx   = playerPos.x - ePos.x;
        float dy   = playerPos.y - ePos.y;
        float dist = sqrtf(dx * dx + dy * dy);

        if (!world.has_component<VelocityComponent>(id))
            world.add_component<VelocityComponent>(id) = {};

        VelocityComponent& vel = world.get_component<VelocityComponent>(id);

        if (dist <= kStopRadius) {
            // Close enough — stop moving so CombatSystem can handle contact.
            vel = {0.f, 0.f, 0.f};
        } else {
            vel.vx = (dx / dist) * kEnemySpeed;
            vel.vy = (dy / dist) * kEnemySpeed;
            vel.vz = 0.f;
        }
    }
}
