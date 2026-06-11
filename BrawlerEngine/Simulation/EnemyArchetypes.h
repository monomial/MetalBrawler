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
    Spitter = 4, // ranged back-line projectile thrower
    Count
};

struct EnemyArchetypeDef {
    float moveSpeed;       // units/sec
    float stopRadius;      // stop chasing inside this distance
    float attackCooldown;  // seconds between attack initiations
    int   maxHP;
    float scale;           // render scale multiplier
    float knockbackScale;  // multiplier on hit shove
    bool  ranged;          // true means attack clip throws a projectile
};

constexpr EnemyArchetypeDef kEnemyArchetypes[(int)EnemyArchetype::Count] = {
    // speed  stop   cooldn  HP  scale  knock  ranged
    {  150.f, 110.f, 2.0f,    3, 1.00f, 1.0f,  false }, // Grunt — original constants
    {  260.f, 100.f, 1.2f,    2, 0.85f, 1.3f,  false }, // Rusher
    {   90.f, 115.f, 3.0f,    8, 1.30f, 0.3f,  false }, // Heavy
    {  110.f, 120.f, 2.0f,   12, 2.00f, 0.25f, false }, // Boss
    {  120.f, 350.f, 2.6f,    2, 0.90f, 1.2f,  true  }, // Spitter
};

struct EnemyArchetypeComponent {
    uint8_t type = (uint8_t)EnemyArchetype::Grunt;
};

inline const EnemyArchetypeDef& enemy_archetype_def(uint8_t type) {
    if (type >= (uint8_t)EnemyArchetype::Count) type = 0;
    return kEnemyArchetypes[type];
}
