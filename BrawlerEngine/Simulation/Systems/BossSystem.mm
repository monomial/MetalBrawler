#include "BossSystem.h"
#include "Simulation/Difficulty.h"
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
static constexpr float kBossLobTelegraph = 0.6f;
static constexpr float kBossLobEnragedTelegraph = 0.4f;
static constexpr float kBossLeapTelegraph = 0.7f;
static constexpr float kBossLeapEnragedTelegraph = 0.55f;
static constexpr float kLeapAoeRadius = 120.f;
static constexpr uint8_t kBossPattern[] = {
    BossChargeComponent::AbilityCharge,
    BossChargeComponent::AbilityLobVolley,
    BossChargeComponent::AbilityCharge,
    BossChargeComponent::AbilityLeap,
};
static constexpr int kBossPatternLen = sizeof(kBossPattern) / sizeof(kBossPattern[0]);

static float clampf(float v, float lo, float hi) {
    return v < lo ? lo : (v > hi ? hi : v);
}

static float smoothstep(float t) {
    t = clampf(t, 0.f, 1.f);
    return t * t * (3.f - 2.f * t);
}

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

static bool living_player(World& world, EntityID id) {
    if (!world.player_tags().present(id)) return false;
    if (!world.has_component<PositionComponent>(id)) return false;
    if (!world.has_component<HealthComponent>(id)) return false;
    if (world.get_component<HealthComponent>(id).current <= 0) return false;
    if (world.has_component<DownedComponent>(id)) return false;
    if (world.has_component<AnimationComponent>(id) &&
        world.get_component<AnimationComponent>(id).dying) return false;
    return true;
}

static int collect_living_players(World& world, EntityID outIDs[4]) {
    int n = 0;
    for (EntityID id = 0; id < world.entity_count() && n < 4; ++id) {
        if (!living_player(world, id)) continue;
        outIDs[n++] = id;
    }
    return n;
}

static void damage_players_in_radius(World& world, EntityID attackerID,
                                     const PositionComponent& center,
                                     float radius, int damage, int hitStop,
                                     float shake) {
    for (EntityID pid = 0; pid < world.entity_count(); ++pid) {
        if (!living_player(world, pid)) continue;
        if (world.has_component<DodgeComponent>(pid)) continue;
        if (world.has_component<DamageCooldownComponent>(pid) &&
            world.get_component<DamageCooldownComponent>(pid).remaining > 0.f)
            continue;

        const auto& pp = world.get_component<PositionComponent>(pid);
        float dx = pp.x - center.x, dy = pp.y - center.y;
        if (dx * dx + dy * dy > radius * radius) continue;

        auto& hp = world.get_component<HealthComponent>(pid);
        hp.current -= damage;
        world.events().emit_hit_contact(attackerID, pid);
        world.events().emit_damage(pid, damage);
        world.trigger_hit_stop(hitStop);
        ScreenShakeSystem_trigger(world, shake);
        if (world.has_component<DamageCooldownComponent>(pid))
            world.get_component<DamageCooldownComponent>(pid).remaining = kContactCooldown;
        if (hp.current <= 0 &&
            !Combat_try_second_wind(world, pid) &&
            world.has_component<AnimationComponent>(pid)) {
            Combat_apply_death(world, pid, attackerID);
        }
    }
}

static void start_charge_telegraph(World& world, EntityID id, BossChargeComponent& charge) {
    charge.ability = BossChargeComponent::AbilityCharge;
    charge.state = BossChargeComponent::Telegraph;
    charge.timer = charge.enraged ? kEnragedTelegraphTime : kTelegraphTime;
    world.events().emit_boss_telegraph(id);
}

static void start_lob_telegraph(World& world, EntityID id, BossChargeComponent& charge) {
    charge.ability = BossChargeComponent::AbilityLobVolley;
    charge.state = BossChargeComponent::Telegraph;
    charge.timer = charge.enraged ? kBossLobEnragedTelegraph : kBossLobTelegraph;
    world.events().emit_boss_telegraph(id);
}

static void start_leap_telegraph(World& world, EntityID id, BossChargeComponent& charge,
                                 PositionComponent& pos) {
    charge.ability = BossChargeComponent::AbilityLeap;
    charge.state = BossChargeComponent::Telegraph;
    charge.timer = charge.enraged ? kBossLeapEnragedTelegraph : kBossLeapTelegraph;
    if (charge.timer < 0.55f) charge.timer = 0.55f;
    EntityID pid; float dx, dy, dist;
    if (!nearest_player(world, pos, &pid, &dx, &dy, &dist) || dist <= 0.001f) {
        dx = charge.dirX;
        dy = charge.dirY;
        dist = 1.f;
    }
    float dirX = dx / dist;
    float dirY = dy / dist;
    float leapLen = fminf(dist + 80.f, 520.f);
    charge.startX = pos.x;
    charge.startY = pos.y;
    charge.destX = clampf(pos.x + dirX * leapLen, kRoomMinX + 60.f, kRoomMaxX - 60.f);
    charge.destY = clampf(pos.y + dirY * leapLen, kRoomMinY + 60.f, kRoomMaxY - 60.f);
    charge.dirX = dirX;
    charge.dirY = dirY;
    TelegraphLineComponent& line = world.has_component<TelegraphLineComponent>(id)
        ? world.get_component<TelegraphLineComponent>(id)
        : world.add_component<TelegraphLineComponent>(id);
    line.x2 = charge.destX;
    line.y2 = charge.destY;
    line.width = 90.f;
    line.aimX = dirX;
    line.aimY = dirY;
    world.events().emit_boss_telegraph(id);
}

static void spawn_boss_lobs(World& world, const PositionComponent& pos, bool enraged) {
    EntityID players[4] = {};
    int playerCount = collect_living_players(world, players);
    if (playerCount <= 0) return;
    int lobCount = enraged ? 3 : 2;
    for (int i = 0; i < lobCount; ++i) {
        const PositionComponent& target = world.get_component<PositionComponent>(players[i % playerCount]);
        float dx = target.x;
        float dy = target.y;
        if (playerCount == 1 && lobCount > 1) {
            float offset = (i == 0) ? -90.f : (i == 1 ? 90.f : 0.f);
            dx += offset;
        }
        HazardSystem_spawn_lava_lob(world, pos.x, pos.y, dx, dy, 1, 90.f, 3.5f);
    }
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
        if (world.has_component<SpawnAnimComponent>(id)) continue;
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

        if (charge.state != BossChargeComponent::Leap)
            charge.timer -= gameDt;

        switch (charge.state) {
            case BossChargeComponent::Idle: {
                // EnemyAISystem drives normal chase/attack behavior here.
                if (charge.timer <= 0.f) {
                    charge.ability = kBossPattern[charge.abilityCounter % kBossPatternLen];
                    charge.abilityCounter += 1;
                    if (charge.ability == BossChargeComponent::AbilityLobVolley) {
                        start_lob_telegraph(world, id, charge);
                    } else if (charge.ability == BossChargeComponent::AbilityLeap) {
                        start_leap_telegraph(world, id, charge, pos);
                    } else {
                        start_charge_telegraph(world, id, charge);
                    }
                }
                break;
            }

            case BossChargeComponent::Telegraph: {
                // Plant and stare the target down; charge/lob direction tracks until launch.
                EntityID pid; float dx, dy, dist;
                if (charge.ability != BossChargeComponent::AbilityLeap &&
                    nearest_player(world, pos, &pid, &dx, &dy, &dist) && dist > 0.001f) {
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
                    if (charge.ability == BossChargeComponent::AbilityLobVolley) {
                        spawn_boss_lobs(world, pos, charge.enraged);
                        charge.state = BossChargeComponent::Recover;
                        charge.timer = kRecoverTime;
                    } else if (charge.ability == BossChargeComponent::AbilityLeap) {
                        charge.state = BossChargeComponent::Leap;
                        charge.timer = 0.f;
                        charge.startX = pos.x;
                        charge.startY = pos.y;
                        world.remove_component<TelegraphLineComponent>(id);
                    } else {
                        charge.state = BossChargeComponent::Charge;
                        charge.timer = kChargeMaxTime;
                    }
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

                // Body slam: damage any player in contact range.
                damage_players_in_radius(world, id, pos, kContactRange, kChargeDamage, 6, 26.f);

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

            case BossChargeComponent::Leap: {
                // Leap uses the shared timer as elapsed time (the outer
                // decrement is skipped for this state, so just accumulate).
                charge.timer += gameDt;
                float t = clampf(charge.timer / charge.leapDuration, 0.f, 1.f);
                float eased = smoothstep(t);
                pos.x = charge.startX + (charge.destX - charge.startX) * eased;
                pos.y = charge.startY + (charge.destY - charge.startY) * eased;
                if (world.has_component<VelocityComponent>(id))
                    world.get_component<VelocityComponent>(id) = {0, 0, 0};
                AnimationSystem_request_clip(world, id, AnimClipID::Walk);
                if (t >= 1.f) {
                    pos.x = charge.destX;
                    pos.y = charge.destY;
                    damage_players_in_radius(world, id, pos, kLeapAoeRadius, 2, 6, 26.f);
                    EntityID pool = world.defer_create();
                    world.add_component<PositionComponent>(pool) = {pos.x, pos.y, 0.f};
                    HazardComponent& hz = world.add_component<HazardComponent>(pool);
                    hz.radius = 100.f;
                    hz.damage = 1;
                    hz.lifetime = 3.0f;
                    world.events().emit_lava_pool_spawned(pos.x, pos.y);
                    ScreenShakeSystem_trigger(world, 26.f);
                    charge.state = BossChargeComponent::Recover;
                    charge.timer = kRecoverTime;
                }
                break;
            }

            case BossChargeComponent::Recover: {
                if (world.has_component<VelocityComponent>(id))
                    world.get_component<VelocityComponent>(id) = {0, 0, 0};
                AnimationSystem_request_clip(world, id, AnimClipID::Idle);
                if (charge.timer <= 0.f) {
                    charge.state = BossChargeComponent::Idle;
                    charge.timer = kChargeCooldown * Difficulty_cooldown_mult(world.difficulty()) *
                                   (charge.enraged ? kEnragedChargeCooldownMult : 1.f);
                }
                break;
            }
        }
    }
}
