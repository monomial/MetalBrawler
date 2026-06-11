#include "BossSystem.h"
#include "Simulation/World.h"
#include "Simulation/RoomBounds.h"
#include "Simulation/Systems/AnimationSystem.h"
#include "Simulation/Systems/CombatHelpers.h"
#include "Simulation/Systems/HazardSystem.h"
#include "Simulation/Systems/ScreenShakeSystem.h"
#include <math.h>

static constexpr float kChargeCooldown   = 4.5f;  // Idle time between charges
static constexpr float kTelegraphTime    = 0.7f;  // wind-up — the player's dodge window
static constexpr float kChargeMaxTime    = 0.9f;  // safety cap on a charge
static constexpr float kRecoverTime      = 0.8f;  // vulnerable after a charge
static constexpr float kChargeSpeed      = 700.f;
static constexpr float kEnragedTelegraphTime = 0.45f;
static constexpr float kEnragedChargeSpeedMult = 1.25f;
static constexpr float kEnragedChargeCooldownMult = 0.65f;
static constexpr float kContactRange     = 95.f;  // body-slam radius during charge
static constexpr int   kChargeDamage     = 2;
static constexpr float kContactCooldown  = 0.8f;  // per-victim re-hit delay
static constexpr float kWallMargin       = 30.f;  // ends the charge at a wall

// Nearest living player; returns false if none.
static bool nearest_player(World& world, const PositionComponent& from,
                           EntityID* outID, float* outDx, float* outDy, float* outDist) {
    bool  found = false;
    float bestD2 = 0.f;
    for (EntityID id = 0; id < world.entity_count(); ++id) {
        if (!world.player_tags().present(id)) continue;
        if (!world.has_component<PositionComponent>(id)) continue;
        if (world.has_component<AnimationComponent>(id) &&
            world.get_component<AnimationComponent>(id).dying) continue;
        const auto& p = world.get_component<PositionComponent>(id);
        float dx = p.x - from.x, dy = p.y - from.y;
        float d2 = dx * dx + dy * dy;
        if (!found || d2 < bestD2) {
            bestD2 = d2; found = true;
            *outID = id; *outDx = dx; *outDy = dy;
        }
    }
    if (found) *outDist = sqrtf(bestD2);
    return found;
}

void BossSystem_update(World& world, float gameDt) {
    if (gameDt == 0.f) return; // frozen during HitStop

    // Tick down contact-damage cooldowns (this system is their only consumer
    // since ContactDamageSystem left the loop).
    for (EntityID id = 0; id < world.entity_count(); ++id) {
        if (!world.damage_cooldowns().present(id)) continue;
        auto& cd = world.get_component<DamageCooldownComponent>(id);
        cd.remaining -= gameDt;
        if (cd.remaining < 0.f) cd.remaining = 0.f;
    }

    for (EntityID id = 0; id < world.entity_count(); ++id) {
        if (!world.has_component<BossChargeComponent>(id)) continue;
        if (!world.has_component<PositionComponent>(id)) continue;
        if (world.has_component<AnimationComponent>(id) &&
            world.get_component<AnimationComponent>(id).dying) continue;

        BossChargeComponent& charge = world.get_component<BossChargeComponent>(id);
        PositionComponent&   pos    = world.get_component<PositionComponent>(id);

        if (!charge.enraged &&
            world.has_component<HealthComponent>(id)) {
            const HealthComponent& hp = world.get_component<HealthComponent>(id);
            if (hp.max > 0 && hp.current <= hp.max / 2) {
                charge.enraged = true;
                world.events().emit_boss_enraged(id);
                ScreenShakeSystem_trigger(world, 26.f);
                if (charge.state == BossChargeComponent::Idle) {
                    float fastCooldown = kChargeCooldown * kEnragedChargeCooldownMult;
                    if (charge.timer > fastCooldown) charge.timer = fastCooldown;
                }
            }
        }

        charge.timer -= gameDt;

        switch (charge.state) {
            case BossChargeComponent::Idle: {
                // EnemyAISystem drives normal chase/attack behavior here.
                if (charge.timer <= 0.f) {
                    charge.state = BossChargeComponent::Telegraph;
                    charge.timer = charge.enraged ? kEnragedTelegraphTime : kTelegraphTime;
                    world.events().emit_boss_telegraph(id);
                }
                break;
            }

            case BossChargeComponent::Telegraph: {
                // Plant and stare the target down; direction tracks until launch.
                EntityID pid; float dx, dy, dist;
                if (nearest_player(world, pos, &pid, &dx, &dy, &dist) && dist > 0.001f) {
                    charge.dirX = dx / dist;
                    charge.dirY = dy / dist;
                    if (world.has_component<FacingComponent>(id)) {
                        auto& f = world.get_component<FacingComponent>(id);
                        f.dx = charge.dirX; f.dy = charge.dirY;
                    }
                }
                if (world.has_component<VelocityComponent>(id))
                    world.get_component<VelocityComponent>(id) = {0, 0, 0};
                AnimationSystem_request_clip(world, id, AnimClipID::Idle);

                if (charge.timer <= 0.f) {
                    charge.state = BossChargeComponent::Charge;
                    charge.timer = kChargeMaxTime;
                }
                break;
            }

            case BossChargeComponent::Charge: {
                if (!world.has_component<VelocityComponent>(id))
                    world.add_component<VelocityComponent>(id) = {};
                auto& vel = world.get_component<VelocityComponent>(id);
                float speed = kChargeSpeed * (charge.enraged ? kEnragedChargeSpeedMult : 1.f);
                vel.vx = charge.dirX * speed;
                vel.vy = charge.dirY * speed;
                vel.vz = 0.f;
                AnimationSystem_request_clip(world, id, AnimClipID::Walk);

                // Body slam: damage any player in contact range (re-hit gated
                // by the player's DamageCooldownComponent).
                for (EntityID pid = 0; pid < world.entity_count(); ++pid) {
                    if (!world.player_tags().present(pid)) continue;
                    if (!world.has_component<PositionComponent>(pid)) continue;
                    if (!world.has_component<HealthComponent>(pid)) continue;
                    if (world.has_component<DownedComponent>(pid)) continue;
                    if (world.has_component<DodgeComponent>(pid)) continue; // i-frames
                    if (world.has_component<AnimationComponent>(pid) &&
                        world.get_component<AnimationComponent>(pid).dying) continue;
                    if (world.has_component<DamageCooldownComponent>(pid) &&
                        world.get_component<DamageCooldownComponent>(pid).remaining > 0.f)
                        continue;

                    const auto& pp = world.get_component<PositionComponent>(pid);
                    float dx = pp.x - pos.x, dy = pp.y - pos.y;
                    if (dx * dx + dy * dy > kContactRange * kContactRange) continue;

                    auto& hp = world.get_component<HealthComponent>(pid);
                    hp.current -= kChargeDamage;
                    world.events().emit_hit_contact(id, pid);
                    world.events().emit_damage(pid, kChargeDamage);
                    world.trigger_hit_stop(6);
                    ScreenShakeSystem_trigger(world, 26.f);
                    if (world.has_component<DamageCooldownComponent>(pid))
                        world.get_component<DamageCooldownComponent>(pid).remaining = kContactCooldown;
                    if (hp.current <= 0 &&
                        !Combat_try_second_wind(world, pid) &&
                        world.has_component<AnimationComponent>(pid)) {
                        Combat_apply_death(world, pid);
                    }
                }

                // Stop at a wall (WallCollision clamps position next tick) or timeout.
                bool hitWall = pos.x <= kRoomMinX + kWallMargin || pos.x >= kRoomMaxX - kWallMargin ||
                               pos.y <= kRoomMinY + kWallMargin || pos.y >= kRoomMaxY - kWallMargin;
                if (hitWall || charge.timer <= 0.f) {
                    charge.state = BossChargeComponent::Recover;
                    charge.timer = kRecoverTime;
                    if (hitWall) ScreenShakeSystem_trigger(world, 22.f); // slam into the wall

                    // The slam cracks the floor: lava snakes fan out from the
                    // boss on looping paths (the design doc's ground hazard).
                    float bx = pos.x, by = pos.y;
                    float baseAng = atan2f(-charge.dirY, -charge.dirX); // back the way it came
                    int snakeCount = charge.enraged ? 4 : 3;
                    for (int s = 0; s < snakeCount; ++s) {
                        float centered = (float)s - (float)(snakeCount - 1) * 0.5f;
                        float ang = baseAng + centered * 0.7f;
                        HazardSystem_spawn_snake(world, bx, by,
                                                 bx + cosf(ang) * 380.f,
                                                 by + sinf(ang) * 380.f);
                    }
                }
                break;
            }

            case BossChargeComponent::Recover: {
                if (world.has_component<VelocityComponent>(id))
                    world.get_component<VelocityComponent>(id) = {0, 0, 0};
                AnimationSystem_request_clip(world, id, AnimClipID::Idle);
                if (charge.timer <= 0.f) {
                    charge.state = BossChargeComponent::Idle;
                    charge.timer = kChargeCooldown *
                                   (charge.enraged ? kEnragedChargeCooldownMult : 1.f);
                }
                break;
            }
        }
    }
}
