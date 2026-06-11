#include "CombatSystem.h"
#include "Simulation/World.h"
#include "Platform/InputState.h"
#include "Simulation/Systems/AnimationSystem.h"
#include "Simulation/Systems/CombatHelpers.h"
#include "Simulation/Systems/ScreenShakeSystem.h"
#include <math.h>

static constexpr float kAttackRange    = 130.0f;
static constexpr int   kHitStopTicks   = 4;      // ~33ms freeze on hit
// Punch arc: target must be within ±70° of the attacker's facing direction.
static constexpr float kPunchArcCosine = 0.342f; // cos(70°)
// Knockback shove on hit: enemies fly back from the attacker and decelerate
// linearly. Bosses barely budge; players are exempt (stay mobile, TMNT-style).

// Active-frame window for each clip: the fraction of clip duration where the
// hitbox is live, and the damage dealt on contact. Zero damage = not an attack.
struct AttackWindow {
    float startFrac;
    float endFrac;
    int   damage;
};

static const AttackWindow kAttackWindows[(int)AnimClipID::Count] = {
    {0.f,   0.f,   0},  // Idle    — no hitbox
    {0.f,   0.f,   0},  // Walk    — no hitbox
    {0.35f, 0.60f, 1},  // Attack  — fist extends around 35–60% of clip
    {0.f,   0.f,   0},  // Hurt    — no hitbox
    {0.f,   0.f,   0},  // Death   — no hitbox
    {0.f,   0.f,   0},  // Dodge   — no hitbox
    {0.30f, 0.60f, 2},  // Attack2 — combo finisher, double damage
    {0.f,   0.f,   0},  // Run     — no hitbox
};

// Finisher feel: the combo's second hit freezes longer and shakes harder.
// Shake is tiered by what the hit means to the player: dealt hits are a small
// bump (felt, not seen), finishers punctuate, and taking damage is loudest.
static constexpr int   kFinisherHitStopTicks = 7;
static constexpr float kHitShake             = 7.f;
static constexpr float kFinisherShake        = 30.f;
static constexpr float kPlayerHitShake       = 22.f;

void CombatSystem_update(World& world, float gameDt) {
    if (gameDt == 0.0f) return; // frozen during HitStop

    uint32_t count = world.entity_count();

    // Iterate every entity that can deal damage this frame.
    // Both player→enemy and enemy→player are handled symmetrically.
    for (EntityID attackerID = 0; attackerID < count; ++attackerID) {
        if (!world.has_component<AnimationComponent>(attackerID)) continue;
        if (!world.has_component<FactionComponent>(attackerID)) continue;
        if (!world.has_component<PositionComponent>(attackerID)) continue;
        if (world.has_component<SpawnAnimComponent>(attackerID)) continue;

        AnimationComponent& atkAnim = world.get_component<AnimationComponent>(attackerID);
        if (atkAnim.dying) continue;
        if (world.has_component<DownedComponent>(attackerID)) continue;

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
        bool hitPlayer   = false;

        for (EntityID targetID = 0; targetID < count; ++targetID) {
            if (targetID == attackerID) continue;
            if (!world.has_component<FactionComponent>(targetID)) continue;
            if (world.get_component<FactionComponent>(targetID).type != tgtFaction) continue;
            if (!world.has_component<PositionComponent>(targetID)) continue;
            if (!world.has_component<HealthComponent>(targetID)) continue;
            if (world.has_component<SpawnAnimComponent>(targetID)) continue;
            if (world.has_component<DownedComponent>(targetID)) continue;
            if (world.has_component<AnimationComponent>(targetID) &&
                world.get_component<AnimationComponent>(targetID).dying) continue;
            if (world.has_component<DodgeComponent>(targetID)) continue; // invincible during dodge

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

            // Perk-modified damage: players carry a StatsComponent with run-level bonuses.
            int damage = win.damage;
            if (world.has_component<StatsComponent>(attackerID))
                damage += world.get_component<StatsComponent>(attackerID).damageBonus;

            HealthComponent& hp = world.get_component<HealthComponent>(targetID);
            hp.current -= damage;
            hitAnything = true;
            hitPlayer  |= world.has_component<PlayerTagComponent>(targetID);

            if (world.has_component<PlayerTagComponent>(attackerID) &&
                world.has_component<SpecialMeterComponent>(attackerID)) {
                SpecialMeterComponent& meter = world.get_component<SpecialMeterComponent>(attackerID);
                float chargeGain = 0.15f;
                if (world.has_component<StatsComponent>(attackerID))
                    chargeGain *= world.get_component<StatsComponent>(attackerID).specialChargeMult;
                meter.charge += chargeGain;
                if (meter.charge > 1.f) meter.charge = 1.f;
            }

            world.events().emit_hit_contact(attackerID, targetID);
            world.events().emit_damage(targetID, damage);

            // Knockback: shove the target away from the attacker. Players are
            // exempt (no stun, no shove); heavies/bosses barely budge.
            bool tgtIsPlayer = world.has_component<PlayerTagComponent>(targetID);
            if (!tgtIsPlayer && dist > 0.001f && hp.current > 0) {
                float scale = world.has_component<BossTagComponent>(targetID)
                            ? kCombatBossKnockbackScale : 1.f;
                if (world.has_component<EnemyArchetypeComponent>(targetID))
                    scale = enemy_archetype_def(
                        world.get_component<EnemyArchetypeComponent>(targetID).type).knockbackScale;
                if (world.has_component<StatsComponent>(attackerID))
                    scale *= world.get_component<StatsComponent>(attackerID).knockbackMult;
                KnockbackComponent& kb = world.has_component<KnockbackComponent>(targetID)
                    ? world.get_component<KnockbackComponent>(targetID)
                    : world.add_component<KnockbackComponent>(targetID);
                kb.velX     = (dx / dist) * kCombatKnockbackSpeed * scale;
                kb.velY     = (dy / dist) * kCombatKnockbackSpeed * scale;
                kb.elapsed  = 0.f;
                kb.duration = kCombatKnockbackDuration;
            }

            if (hp.current <= 0) {
                if (!Combat_try_second_wind(world, targetID))
                    Combat_apply_death(world, targetID);
            } else if (world.has_component<AnimationComponent>(targetID)) {
                // Players stay mobile when hit (no stun) — TMNT-style.
                // Enemies react unless they're a boss; bosses react ~10% of the time.
                bool isPlayer = world.has_component<PlayerTagComponent>(targetID);
                bool isBoss   = world.has_component<BossTagComponent>(targetID);
                if (!isPlayer && (!isBoss || world.rand_range(10) == 0))
                    AnimationSystem_request_clip(world, targetID, AnimClipID::Hurt);
            }
        }

        if (hitAnything) {
            atkAnim.hitApplied = true;
            bool finisher = (atkAnim.currentClip == AnimClipID::Attack2);
            world.trigger_hit_stop(finisher ? kFinisherHitStopTicks : kHitStopTicks);
            float shake = hitPlayer ? kPlayerHitShake
                        : finisher  ? kFinisherShake : kHitShake;
            ScreenShakeSystem_trigger(world, shake);
        }
    }
}
