#include "CombatSystem.h"
#include "Simulation/World.h"
#include "Platform/InputState.h"
#include "Simulation/Systems/AnimationSystem.h"
#include "Simulation/Systems/ScreenShakeSystem.h"
#include <math.h>

static constexpr float kAttackRange    = 130.0f;
static constexpr int   kHitStopTicks   = 4;      // ~33ms freeze on hit
// Punch arc: target must be within ±70° of the attacker's facing direction.
static constexpr float kPunchArcCosine = 0.342f; // cos(70°)

// Active-frame window for each clip: the fraction of clip duration where the
// hitbox is live, and the damage dealt on contact. Zero damage = not an attack.
struct AttackWindow {
    float startFrac;
    float endFrac;
    int   damage;
};

static const AttackWindow kAttackWindows[(int)AnimClipID::Count] = {
    {0.f,   0.f,   0},  // Idle   — no hitbox
    {0.f,   0.f,   0},  // Walk   — no hitbox
    {0.35f, 0.60f, 1},  // Attack — fist extends around 35–60% of clip
    {0.f,   0.f,   0},  // Hurt   — no hitbox
    {0.f,   0.f,   0},  // Death  — no hitbox
};

void CombatSystem_update(World& world, float gameDt) {
    if (gameDt == 0.0f) return; // frozen during HitStop

    uint32_t count = world.entity_count();

    // Iterate every entity that can deal damage this frame.
    // Both player→enemy and enemy→player are handled symmetrically.
    for (EntityID attackerID = 0; attackerID < count; ++attackerID) {
        if (!world.has_component<AnimationComponent>(attackerID)) continue;
        if (!world.has_component<FactionComponent>(attackerID)) continue;
        if (!world.has_component<PositionComponent>(attackerID)) continue;

        AnimationComponent& atkAnim = world.get_component<AnimationComponent>(attackerID);
        if (atkAnim.dying) continue;

        const AttackWindow& win = kAttackWindows[(int)atkAnim.currentClip];
        if (win.damage == 0) continue;
        if (atkAnim.hitApplied) continue;

        float clipDur  = AnimationSystem_clip_duration(world, attackerID, atkAnim.currentClip);
        float winStart = clipDur * win.startFrac;
        float winEnd   = clipDur * win.endFrac;
        if (atkAnim.clipTime < winStart || atkAnim.clipTime > winEnd) continue;

        const PositionComponent& atkPos = world.get_component<PositionComponent>(attackerID);
        FactionComponent::Type atkFaction = world.get_component<FactionComponent>(attackerID).type;
        FactionComponent::Type tgtFaction = (atkFaction == FactionComponent::Player)
                                            ? FactionComponent::Enemy
                                            : FactionComponent::Player;

        // Facing direction for arc check — fall back to +Y if absent.
        float facingDx = 0.f, facingDy = 1.f;
        if (world.has_component<FacingComponent>(attackerID)) {
            const FacingComponent& f = world.get_component<FacingComponent>(attackerID);
            facingDx = f.dx; facingDy = f.dy;
        }

        bool hitAnything = false;

        for (EntityID targetID = 0; targetID < count; ++targetID) {
            if (targetID == attackerID) continue;
            if (!world.has_component<FactionComponent>(targetID)) continue;
            if (world.get_component<FactionComponent>(targetID).type != tgtFaction) continue;
            if (!world.has_component<PositionComponent>(targetID)) continue;
            if (!world.has_component<HealthComponent>(targetID)) continue;
            if (world.has_component<AnimationComponent>(targetID) &&
                world.get_component<AnimationComponent>(targetID).dying) continue;

            const PositionComponent& tPos = world.get_component<PositionComponent>(targetID);
            float dx   = tPos.x - atkPos.x;
            float dy   = tPos.y - atkPos.y;
            float dist = sqrtf(dx * dx + dy * dy);
            if (dist > kAttackRange) continue;

            // Arc check: target must be within ±70° of attacker's facing direction.
            if (dist > 0.001f) {
                float dot = (dx / dist) * facingDx + (dy / dist) * facingDy;
                if (dot < kPunchArcCosine) continue;
            }

            HealthComponent& hp = world.get_component<HealthComponent>(targetID);
            hp.current -= win.damage;
            hitAnything = true;

            world.events().emit_hit_contact(attackerID, targetID);
            world.events().emit_damage(targetID, win.damage);

            if (hp.current <= 0) {
                world.events().emit_died(targetID);
                if (world.has_component<AnimationComponent>(targetID)) {
                    world.get_component<AnimationComponent>(targetID).dying = true;
                    AnimationSystem_request_clip(world, targetID, AnimClipID::Death);
                } else {
                    world.defer_destroy(targetID);
                }
            } else if (world.has_component<AnimationComponent>(targetID)) {
                AnimationSystem_request_clip(world, targetID, AnimClipID::Hurt);
            }
        }

        if (hitAnything) {
            atkAnim.hitApplied = true;
            world.trigger_hit_stop(kHitStopTicks);
            ScreenShakeSystem_trigger(world, 18.f);
        }
    }
}
