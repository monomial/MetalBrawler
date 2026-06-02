#include "ContactDamageSystem.h"
#include "Simulation/World.h"
#include <math.h>

static constexpr float kContactRange   = 35.f; // world units — ~= enemy stop radius
static constexpr float kContactCooldown = 0.75f; // seconds between hits
static constexpr int   kContactDamage  = 1;

void ContactDamageSystem_update(World& world, float gameDt) {
    if (gameDt == 0.f) return; // frozen during HitStop

    // Find player.
    EntityID playerID = kInvalidEntity;
    for (EntityID id = 0; id < world.entity_count(); ++id) {
        if (world.player_tags().present(id)) { playerID = id; break; }
    }
    if (playerID == kInvalidEntity) return;
    if (!world.has_component<PositionComponent>(playerID)) return;
    if (!world.has_component<HealthComponent>(playerID)) return;

    // Tick down player's damage cooldown.
    if (world.has_component<DamageCooldownComponent>(playerID)) {
        auto& cd = world.get_component<DamageCooldownComponent>(playerID);
        cd.remaining -= gameDt;
        if (cd.remaining < 0.f) cd.remaining = 0.f;
    }

    // Check for enemy contact.
    const PositionComponent playerPos = world.get_component<PositionComponent>(playerID);
    bool contacted = false;

    for (EntityID id = 0; id < world.entity_count(); ++id) {
        if (!world.has_component<FactionComponent>(id)) continue;
        if (world.get_component<FactionComponent>(id).type != FactionComponent::Enemy) continue;
        if (!world.has_component<PositionComponent>(id)) continue;

        const PositionComponent& ePos = world.get_component<PositionComponent>(id);
        float dx   = ePos.x - playerPos.x;
        float dy   = ePos.y - playerPos.y;
        float dist = sqrtf(dx*dx + dy*dy);
        if (dist <= kContactRange) { contacted = true; break; }
    }

    if (!contacted) return;

    // Check cooldown — create component on first contact.
    if (!world.has_component<DamageCooldownComponent>(playerID)) {
        world.add_component<DamageCooldownComponent>(playerID).remaining = 0.f;
    }
    auto& cd = world.get_component<DamageCooldownComponent>(playerID);
    if (cd.remaining > 0.f) return;

    // Deal damage.
    auto& hp = world.get_component<HealthComponent>(playerID);
    hp.current -= kContactDamage;
    cd.remaining = kContactCooldown;
    world.events().emit_damage(playerID, kContactDamage);

    if (hp.current <= 0) {
        world.events().emit_died(playerID);
        // Player death is handled by the game loop (BrawlerDelegate), not by defer_destroy.
        // The game loop reads the EntityDied event and transitions to game-over state.
    }
}
