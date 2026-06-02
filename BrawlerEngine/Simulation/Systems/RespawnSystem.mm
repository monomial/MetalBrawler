#include "RespawnSystem.h"
#include "Simulation/World.h"
#include "Simulation/RoomBounds.h"
#include "Simulation/EventBus.h"
#include <stdlib.h>

static constexpr float kRespawnDelay = 1.5f; // seconds after all enemies die
static constexpr int   kEnemyHP      = 3;

static float s_respawnTimer = -1.f;  // -1 = not counting
static bool  s_deathPending = false; // true for one tick after a death event

void RespawnSystem_reset() { s_respawnTimer = -1.f; s_deathPending = false; }

static bool has_living_enemies(World& world) {
    for (EntityID id = 0; id < world.entity_count(); ++id) {
        if (!world.has_component<FactionComponent>(id)) continue;
        if (world.get_component<FactionComponent>(id).type == FactionComponent::Enemy)
            return true;
    }
    return false;
}

static float random_room_coord(float lo, float hi) {
    float margin = 60.f; // keep away from walls
    float range  = (hi - margin) - (lo + margin);
    return (lo + margin) + ((float)rand() / (float)RAND_MAX) * range;
}

void RespawnSystem_update(World& world, float physicalDt) {
    // RespawnSystem runs before World::flush(), so a killed entity still has
    // components this tick. Use a one-tick delay: set s_deathPending when a
    // death event fires, then check has_living_enemies on the NEXT tick (after
    // flush has removed the dead entity's components).
    if (s_deathPending && s_respawnTimer < 0.f && !has_living_enemies(world)) {
        s_respawnTimer = kRespawnDelay;
        s_deathPending = false;
    }
    world.events().for_each(EventType::EntityDied, [](const Event&) {
        s_deathPending = true;
    });

    if (s_respawnTimer > 0.f) {
        s_respawnTimer -= physicalDt;
        if (s_respawnTimer <= 0.f) {
            s_respawnTimer = -1.f;

            // Spawn a new enemy at a random room position.
            EntityID enemy = world.defer_create();
            world.add_component<PositionComponent>(enemy) = {
                random_room_coord(kRoomMinX, kRoomMaxX),
                random_room_coord(kRoomMinY, kRoomMaxY),
                0.f
            };
            world.add_component<VelocityComponent>(enemy) = {0, 0, 0};
            world.add_component<FactionComponent>(enemy).type = FactionComponent::Enemy;
            world.add_component<HealthComponent>(enemy) = {kEnemyHP, kEnemyHP};
        }
    }
}
