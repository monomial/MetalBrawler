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

// Tag — marks a player-controlled entity.
// playerIndex (0–3) maps to World::_inputs[playerIndex] for input routing.
struct PlayerTagComponent {
    bool    active;      // padding; presence in storage is the real signal
    uint8_t playerIndex; // 0 = P1, 1 = P2, 2 = P3, 3 = P4
};

// Last non-zero movement direction, kept as a normalized 2D vector.
// Updated by InputSystem whenever the player moves; used by CombatSystem
// to restrict the punch hitbox to a forward arc.
// Default (0, 1) matches the renderer's default facing (+Y = up the screen).
struct FacingComponent {
    float dx = 0.f, dy = 1.f;
};

// ---------------------------------------------------------------------------
// Animation
// ---------------------------------------------------------------------------

static constexpr int kMaxBones = 64;

// Which animation clip is playing. Matches the clip names exported from Mixamo.
enum class AnimClipID : uint8_t {
    Idle    = 0,
    Walk    = 1,
    Attack  = 2,
    Hurt    = 3,
    Death   = 4,
    Count
};

// Drives AnimationSystem. Holds per-entity clip state + GPU bone matrices.
// float4x4 bone matrices are written by AnimationSystem and uploaded to the
// GPU skinning uniform buffer each frame.
struct AnimationComponent {
    AnimClipID currentClip   = AnimClipID::Idle;
    AnimClipID requestedClip = AnimClipID::Idle; // set by other systems to request a transition
    float      clipTime  = 0.f;  // seconds since clip start
    bool       looping   = true;
    bool       clipDone  = false; // true on last frame of a non-looping clip
    bool       dying      = false; // entity is playing death animation; pending destruction
    bool       hitApplied = false; // damage already dealt this swing; cleared on new attack
    float      boneMatrices[kMaxBones][16]; // column-major float4x4 per bone
};

// ---------------------------------------------------------------------------
// Damage cooldown (contact/hazard sources)
// ---------------------------------------------------------------------------

// Prevents rapid-fire damage from area/contact sources.
// HazardSystem and ContactDamageSystem skip the entity while remaining > 0.
struct DamageCooldownComponent {
    float remaining; // seconds until next hit is allowed
};

// Per-enemy cooldown between attack initiations. Decremented by EnemyAISystem
// each tick; when it reaches 0 the enemy may begin a new Attack clip.
struct EnemyAttackCooldownComponent {
    float remaining = 0.f; // seconds until next attack is allowed (0 = ready)
};
