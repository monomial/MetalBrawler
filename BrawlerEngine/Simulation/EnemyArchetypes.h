#pragma once
#include <stdint.h>

// Enemy archetype data table. An enemy's EnemyArchetypeComponent indexes this
// table; systems read their tuning from here instead of per-system constants.
// Entities WITHOUT the component fall back to the Grunt values, which match
// the original hard-coded constants — keeps every pre-archetype test green.

enum class EnemyArchetype : uint8_t {
    Grunt  = 0, // baseline brawler
    Rusher = 1, // fast, fragile, flies far when hit
    Heavy  = 2, // slow tank, barely budges
    Boss   = 3, // the room-4 big bad
    Count
};

struct EnemyArchetypeDef {
    float moveSpeed;       // units/sec
    float stopRadius;      // stop chasing inside this distance
    float attackCooldown;  // seconds between attack initiations
    int   maxHP;
    float scale;           // render scale multiplier
    float knockbackScale;  // multiplier on hit shove
};

constexpr EnemyArchetypeDef kEnemyArchetypes[(int)EnemyArchetype::Count] = {
    // speed  stop   cooldn  HP  scale  knock
    {  150.f, 110.f, 2.0f,    3, 1.00f, 1.0f  }, // Grunt — original constants
    {  260.f, 100.f, 1.2f,    2, 0.85f, 1.3f  }, // Rusher
    {   90.f, 115.f, 3.0f,    8, 1.30f, 0.3f  }, // Heavy
    {  110.f, 120.f, 2.0f,   12, 2.00f, 0.25f }, // Boss
};

struct EnemyArchetypeComponent {
    uint8_t type = (uint8_t)EnemyArchetype::Grunt;
};

inline const EnemyArchetypeDef& enemy_archetype_def(uint8_t type) {
    if (type >= (uint8_t)EnemyArchetype::Count) type = 0;
    return kEnemyArchetypes[type];
}
