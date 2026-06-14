#include "SpecialSystem.h"
#include "Simulation/World.h"
#include "Simulation/Systems/AnimationSystem.h"
#include "Simulation/Systems/CombatHelpers.h"
#include "Simulation/Systems/ScreenShakeSystem.h"
#include <math.h>

static constexpr float kSpecialRadius       = 220.0f;
static constexpr int   kSpecialHitStopTicks = 7;
static constexpr float kSpecialShake        = 30.0f;
static constexpr float kPassiveSpecialPerSecond = 0.03f;

void SpecialSystem_update(World& world, float gameDt) {
    if (gameDt == 0.0f) return;

    uint32_t count = world.entity_count();
    auto& tags = world.player_tags();
    for (EntityID playerID = 0; playerID < count; ++playerID) {
        if (!tags.present(playerID)) continue;
        if (!world.has_component<PositionComponent>(playerID)) continue;
        if (!world.has_component<SpecialMeterComponent>(playerID)) continue;
        if (world.has_component<DownedComponent>(playerID)) continue;
        if (world.has_component<DodgeComponent>(playerID)) continue;
        if (world.has_component<AnimationComponent>(playerID) &&
            world.get_component<AnimationComponent>(playerID).dying) continue;

        const PlayerTagComponent& tag = world.get_component<PlayerTagComponent>(playerID);
        InputState input = world.current_input(tag.playerIndex);
        SpecialMeterComponent& meter = world.get_component<SpecialMeterComponent>(playerID);
        if (world.has_component<StatsComponent>(playerID) &&
            world.get_component<StatsComponent>(playerID).passiveSpecial) {
            meter.charge += kPassiveSpecialPerSecond * gameDt;
            if (meter.charge > 1.f) meter.charge = 1.f;
        }
        if (!input.special || meter.charge < 1.f) continue;

        meter.charge = 0.f;
        if (world.has_component<AnimationComponent>(playerID))
            AnimationSystem_request_clip(world, playerID, AnimClipID::Attack2);
        world.events().emit_special_used(playerID);

        const PositionComponent& ppos = world.get_component<PositionComponent>(playerID);
        int damage = 2;
        float knockbackMult = 1.f;
        if (world.has_component<StatsComponent>(playerID)) {
            damage += world.get_component<StatsComponent>(playerID).damageBonus;
            knockbackMult = world.get_component<StatsComponent>(playerID).knockbackMult;
        }

        bool hitAnything = false;
        for (EntityID targetID = 0; targetID < count; ++targetID) {
            if (targetID == playerID) continue;
            if (!world.has_component<FactionComponent>(targetID)) continue;
            if (world.get_component<FactionComponent>(targetID).type != FactionComponent::Enemy) continue;
            if (!world.has_component<PositionComponent>(targetID)) continue;
            if (!world.has_component<HealthComponent>(targetID)) continue;
            if (world.has_component<SpawnAnimComponent>(targetID)) continue;
            if (world.has_component<AnimationComponent>(targetID) &&
                world.get_component<AnimationComponent>(targetID).dying) continue;

            const PositionComponent& tpos = world.get_component<PositionComponent>(targetID);
            float dx = tpos.x - ppos.x;
            float dy = tpos.y - ppos.y;
            float dist = sqrtf(dx * dx + dy * dy);
            if (dist > kSpecialRadius) continue;

            HealthComponent& hp = world.get_component<HealthComponent>(targetID);
            hp.current -= damage;
            hitAnything = true;
            world.events().emit_damage(targetID, damage);

            if (hp.current <= 0) {
                if (!Combat_try_second_wind(world, targetID))
                    Combat_apply_death(world, targetID, playerID);
                continue;
            }

            if (dist > 0.001f) {
                float scale = world.has_component<BossTagComponent>(targetID)
                            ? kCombatBossKnockbackScale : 1.f;
                if (world.has_component<EnemyArchetypeComponent>(targetID))
                    scale = enemy_archetype_def(
                        world.get_component<EnemyArchetypeComponent>(targetID).type).knockbackScale;
                KnockbackComponent& kb = world.has_component<KnockbackComponent>(targetID)
                    ? world.get_component<KnockbackComponent>(targetID)
                    : world.add_component<KnockbackComponent>(targetID);
                kb.velX     = (dx / dist) * kCombatKnockbackSpeed * 1.5f * scale * knockbackMult;
                kb.velY     = (dy / dist) * kCombatKnockbackSpeed * 1.5f * scale * knockbackMult;
                kb.elapsed  = 0.f;
                kb.duration = kCombatKnockbackDuration;
            }

            if (world.has_component<AnimationComponent>(targetID)) {
                bool isBoss = world.has_component<BossTagComponent>(targetID);
                if (!isBoss || world.rand_range(10) == 0)
                    AnimationSystem_request_clip(world, targetID, AnimClipID::Hurt);
            }
        }

        if (hitAnything) {
            world.trigger_hit_stop(kSpecialHitStopTicks);
            ScreenShakeSystem_trigger(world, kSpecialShake);
        }
    }
}
