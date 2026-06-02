#pragma once
#include <stdint.h>

// All component structs for MetalBrawler.
// Rules: plain C structs only. No methods. No logic. Only data.
// Adding a new component: add struct here, add storage member to World, add
// _pool<T>() specialization in World.mm.

// --- Spatial ---

struct PositionComponent {
    float x, y, z;
};

struct VelocityComponent {
    float vx, vy, vz;
};

// --- Game state ---

struct HealthComponent {
    int current;
    int max;
};

// Which side this entity is on — used by AI and CombatSystem.
struct FactionComponent {
    enum Type : uint8_t { Player = 0, Enemy = 1 } type;
};

// Tag — marks the single player-controlled entity. No data.
struct PlayerTagComponent {
    bool active; // padding; presence in storage is the real signal
};

// Prevents rapid-fire damage from area/contact sources.
// HazardSystem and ContactDamageSystem skip the entity while remaining > 0.
struct DamageCooldownComponent {
    float remaining; // seconds until next hit is allowed
};
