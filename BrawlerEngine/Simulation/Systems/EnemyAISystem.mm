#include "EnemyAISystem.h"
#include "Simulation/World.h"
#include "Simulation/Difficulty.h"
#include "Simulation/RoomBounds.h"
#include "Simulation/Systems/AnimationSystem.h"
#include <math.h>

// Defaults for enemies without an EnemyArchetypeComponent — identical to the
// Grunt row in kEnemyArchetypes (keeps pre-archetype behavior and tests).
static constexpr float kEnemySpeed          = 150.0f; // units per second
static constexpr float kStopRadius          = 110.0f; // stop chasing within this distance
static constexpr float kEnemyAttackCooldown = 2.0f;   // seconds between attack initiations
static constexpr float kEnemyAttackWindup   = 0.35f;  // committed warning before punch
static constexpr float kRangedTelegraphWidth = 18.f;
static constexpr float kProjectileBaseSpeed = 420.f;
static constexpr float kProjectileLifetime = 2.5f;
static constexpr float kAimStep = 20.f;
static constexpr float kSeekWeight = 1.0f;
static constexpr float kAvoidWeight = 1.4f;
static constexpr float kSepWeight = 0.6f;
static constexpr float kCharacterRadius = 40.f;
static constexpr float kAvoidMargin = 20.f;
static constexpr float kLookahead = 70.f;
static constexpr float kSepRadius = 64.f;

static bool point_blocked_by_obstacle(World& world, float x, float y) {
    for (EntityID id = 0; id < world.entity_count(); ++id) {
        if (!world.obstacles().present(id)) continue;
        if (!world.has_component<PositionComponent>(id)) continue;
        const PositionComponent& p = world.get_component<PositionComponent>(id);
        const ObstacleComponent& o = world.get_component<ObstacleComponent>(id);
        if (x >= p.x - o.halfW && x <= p.x + o.halfW &&
            y >= p.y - o.halfH && y <= p.y + o.halfH)
            return true;
    }
    return false;
}

static float telegraph_distance_until_blocked(World& world, const PositionComponent& from,
                                              float dirX, float dirY) {
    float lastClear = 0.f;
    float maxDistance = kProjectileBaseSpeed * Difficulty_projectile_mult(world.difficulty()) *
                        kProjectileLifetime;
    for (float d = kAimStep; d <= maxDistance; d += kAimStep) {
        float x = from.x + dirX * d;
        float y = from.y + dirY * d;
        if (x < kRoomMinX || x > kRoomMaxX || y < kRoomMinY || y > kRoomMaxY)
            return lastClear;
        if (point_blocked_by_obstacle(world, x, y))
            return lastClear;
        lastClear = d;
    }
    return maxDistance;
}

static bool is_boss_enemy(World& world, EntityID id) {
    if (world.boss_tags().present(id)) return true;
    if (!world.has_component<EnemyArchetypeComponent>(id)) return false;
    return world.get_component<EnemyArchetypeComponent>(id).type == (uint8_t)EnemyArchetype::Boss;
}

static bool is_living_enemy_for_steering(World& world, EntityID id) {
    if (!world.has_component<FactionComponent>(id)) return false;
    if (world.get_component<FactionComponent>(id).type != FactionComponent::Enemy) return false;
    if (!world.has_component<HealthComponent>(id)) return false;
    if (world.get_component<HealthComponent>(id).current <= 0) return false;
    if (world.has_component<AnimationComponent>(id) &&
        world.get_component<AnimationComponent>(id).dying) return false;
    return true;
}

static bool ray_intersects_expanded_aabb(const PositionComponent& from, float dirX, float dirY,
                                         const PositionComponent& boxPos,
                                         const ObstacleComponent& box,
                                         float& hitT) {
    float halfW = box.halfW + kCharacterRadius + kAvoidMargin;
    float halfH = box.halfH + kCharacterRadius + kAvoidMargin;
    float minX = boxPos.x - halfW;
    float maxX = boxPos.x + halfW;
    float minY = boxPos.y - halfH;
    float maxY = boxPos.y + halfH;

    float tMin = 0.f;
    float tMax = kLookahead;
    if (fabsf(dirX) < 1e-6f) {
        if (from.x < minX || from.x > maxX) return false;
    } else {
        float inv = 1.f / dirX;
        float t1 = (minX - from.x) * inv;
        float t2 = (maxX - from.x) * inv;
        if (t1 > t2) { float tmp = t1; t1 = t2; t2 = tmp; }
        if (t1 > tMin) tMin = t1;
        if (t2 < tMax) tMax = t2;
        if (tMin > tMax) return false;
    }

    if (fabsf(dirY) < 1e-6f) {
        if (from.y < minY || from.y > maxY) return false;
    } else {
        float inv = 1.f / dirY;
        float t1 = (minY - from.y) * inv;
        float t2 = (maxY - from.y) * inv;
        if (t1 > t2) { float tmp = t1; t1 = t2; t2 = tmp; }
        if (t1 > tMin) tMin = t1;
        if (t2 < tMax) tMax = t2;
        if (tMin > tMax) return false;
    }

    hitT = tMin < 0.f ? 0.f : tMin;
    return hitT <= kLookahead;
}

static void obstacle_avoidance(World& world, const PositionComponent& ePos,
                               float seekX, float seekY, float& avoidX, float& avoidY) {
    avoidX = 0.f;
    avoidY = 0.f;
    float nearestT = kLookahead + 1.f;
    EntityID nearest = kInvalidEntity;

    for (EntityID oid = 0; oid < world.entity_count(); ++oid) {
        if (!world.obstacles().present(oid)) continue;
        if (!world.has_component<PositionComponent>(oid)) continue;
        float hitT = 0.f;
        if (!ray_intersects_expanded_aabb(ePos, seekX, seekY,
                                          world.get_component<PositionComponent>(oid),
                                          world.get_component<ObstacleComponent>(oid),
                                          hitT)) continue;
        if (hitT < nearestT) {
            nearestT = hitT;
            nearest = oid;
        }
    }

    if (nearest == kInvalidEntity) return;

    const PositionComponent& boxPos = world.get_component<PositionComponent>(nearest);
    float awayX = ePos.x - boxPos.x;
    float awayY = ePos.y - boxPos.y;
    float leftX = -seekY;
    float leftY = seekX;
    float rightX = seekY;
    float rightY = -seekX;
    float leftDot = leftX * awayX + leftY * awayY;
    float rightDot = rightX * awayX + rightY * awayY;
    if (fabsf(leftDot - rightDot) <= 1e-6f) {
        // Stable side choice when exactly centered on the obstacle line.
        leftDot = 1.f;
        rightDot = 0.f;
    }
    if (leftDot >= rightDot) {
        avoidX = leftX;
        avoidY = leftY;
    } else {
        avoidX = rightX;
        avoidY = rightY;
    }
}

static void separation(World& world, EntityID self, const PositionComponent& ePos,
                       float& sepX, float& sepY) {
    sepX = 0.f;
    sepY = 0.f;
    for (EntityID other = 0; other < world.entity_count(); ++other) {
        if (other == self) continue;
        if (!is_living_enemy_for_steering(world, other)) continue;
        if (is_boss_enemy(world, other)) continue;
        if (!world.has_component<PositionComponent>(other)) continue;
        const PositionComponent& oPos = world.get_component<PositionComponent>(other);
        float dx = ePos.x - oPos.x;
        float dy = ePos.y - oPos.y;
        float d2 = dx * dx + dy * dy;
        if (d2 <= 1e-6f || d2 > kSepRadius * kSepRadius) continue;
        float d = sqrtf(d2);
        sepX += dx / d;
        sepY += dy / d;
    }
    float len = sqrtf(sepX * sepX + sepY * sepY);
    if (len > 1e-6f) {
        sepX /= len;
        sepY /= len;
    } else {
        sepX = 0.f;
        sepY = 0.f;
    }
}

void EnemyAISystem_update(World& world, float gameDt) {
    if (gameDt == 0.0f) return; // HitStop — enemies freeze

    // Collect all alive player positions (up to 4) — each enemy targets the nearest.
    PositionComponent playerPositions[4];
    int playerCount = 0;
    {
        auto& tags = world.player_tags();
        uint32_t count = world.entity_count();
        for (EntityID id = 0; id < count && playerCount < 4; ++id) {
            if (!tags.present(id)) continue;
            if (!world.has_component<PositionComponent>(id)) continue;
            if (world.has_component<DownedComponent>(id)) continue;
            if (world.has_component<AnimationComponent>(id) &&
                world.get_component<AnimationComponent>(id).dying) continue;
            playerPositions[playerCount++] = world.get_component<PositionComponent>(id);
        }
    }
    if (playerCount == 0) return;

    uint32_t count = world.entity_count();
    auto& factions = world.factions();
    for (EntityID id = 0; id < count; ++id) {
        if (!factions.present(id)) continue;
        if (factions.get(id).type != FactionComponent::Enemy) continue;
        if (!world.has_component<PositionComponent>(id)) continue;
        if (world.has_component<SpawnAnimComponent>(id)) {
            if (world.has_component<VelocityComponent>(id))
                world.get_component<VelocityComponent>(id) = {0.f, 0.f, 0.f};
            continue;
        }
        if (world.has_component<AnimationComponent>(id) &&
            world.get_component<AnimationComponent>(id).dying) continue;

        const PositionComponent& ePos = world.get_component<PositionComponent>(id);

        // Per-archetype tuning, defaulting to the original grunt constants.
        float moveSpeed  = kEnemySpeed;
        float stopRadius = kStopRadius;
        float cooldown   = kEnemyAttackCooldown;
        bool isRusher = false;
        if (world.has_component<EnemyArchetypeComponent>(id)) {
            uint8_t archetype = world.get_component<EnemyArchetypeComponent>(id).type;
            if (archetype == (uint8_t)EnemyArchetype::Leaper &&
                world.has_component<LeaperComponent>(id) &&
                world.get_component<LeaperComponent>(id).state != 0) {
                if (world.has_component<VelocityComponent>(id))
                    world.get_component<VelocityComponent>(id) = {0.f, 0.f, 0.f};
                continue;
            }
            isRusher = archetype == (uint8_t)EnemyArchetype::Rusher;
            const EnemyArchetypeDef& def =
                enemy_archetype_def(archetype);
            moveSpeed  = def.moveSpeed * Difficulty_speed_mult(world.difficulty());
            stopRadius = def.stopRadius;
            cooldown   = def.attackCooldown * Difficulty_cooldown_mult(world.difficulty());
        }

        // Find nearest alive player.
        PositionComponent playerPos = playerPositions[0];
        float dist = sqrtf((playerPos.x-ePos.x)*(playerPos.x-ePos.x) +
                           (playerPos.y-ePos.y)*(playerPos.y-ePos.y));
        for (int pi = 1; pi < playerCount; ++pi) {
            float d = sqrtf((playerPositions[pi].x-ePos.x)*(playerPositions[pi].x-ePos.x) +
                            (playerPositions[pi].y-ePos.y)*(playerPositions[pi].y-ePos.y));
            if (d < dist) { dist = d; playerPos = playerPositions[pi]; }
        }

        float dx = playerPos.x - ePos.x;
        float dy = playerPos.y - ePos.y;

        // Always face toward the player.
        if (world.has_component<FacingComponent>(id) && dist > 0.001f) {
            FacingComponent& facing = world.get_component<FacingComponent>(id);
            facing.dx = dx / dist;
            facing.dy = dy / dist;
        }

        bool windupFinished = false;
        bool windupCancelled = false;

        // Tick down attack cooldown and any committed wind-up.
        if (world.has_component<EnemyAttackCooldownComponent>(id)) {
            auto& cd = world.get_component<EnemyAttackCooldownComponent>(id);
            cd.remaining -= gameDt;
            if (cd.remaining < 0.f) cd.remaining = 0.f;
            if (cd.windup > 0.f &&
                world.has_component<AnimationComponent>(id) &&
                world.get_component<AnimationComponent>(id).currentClip == AnimClipID::Hurt) {
                cd.windup = 0.f;
                windupCancelled = true;
            }
            if (cd.windup > 0.f) {
                cd.windup -= gameDt;
                if (cd.windup <= 0.f) {
                    cd.windup = 0.f;
                    windupFinished = true;
                }
            }
        }
        if (windupCancelled)
            world.remove_component<TelegraphLineComponent>(id);

        if (!world.has_component<VelocityComponent>(id))
            world.add_component<VelocityComponent>(id) = {};

        VelocityComponent& vel = world.get_component<VelocityComponent>(id);
        bool moving;

        bool windingUp = world.has_component<EnemyAttackCooldownComponent>(id) &&
                         world.get_component<EnemyAttackCooldownComponent>(id).windup > 0.f;

        if (windingUp) {
            vel = {0.f, 0.f, 0.f};
            moving = false;
        } else if (dist <= stopRadius) {
            vel = {0.f, 0.f, 0.f};
            moving = false;
        } else {
            float seekX = dx / dist;
            float seekY = dy / dist;
            float avoidX = 0.f, avoidY = 0.f;
            float sepX = 0.f, sepY = 0.f;
            bool boss = is_boss_enemy(world, id);
            obstacle_avoidance(world, ePos, seekX, seekY, avoidX, avoidY);
            if (!boss)
                separation(world, id, ePos, sepX, sepY);
            float moveX = seekX * kSeekWeight + avoidX * kAvoidWeight + sepX * kSepWeight;
            float moveY = seekY * kSeekWeight + avoidY * kAvoidWeight + sepY * kSepWeight;
            float moveLen = sqrtf(moveX * moveX + moveY * moveY);
            if (moveLen <= 1e-6f) {
                moveX = seekX;
                moveY = seekY;
                moveLen = 1.f;
            }
            vel.vx = (moveX / moveLen) * moveSpeed;
            vel.vy = (moveY / moveLen) * moveSpeed;
            vel.vz = 0.f;
            moving = true;
        }

        if (!world.has_component<AnimationComponent>(id)) continue;

        // Determine what animation to request.
        // Non-looping clips (Attack, Hurt) play through fully before this takes effect,
        // so it's safe to call every tick — the request is just queued.
        AnimClipID nextClip = moving ? (isRusher ? AnimClipID::Run : AnimClipID::Walk)
                                     : AnimClipID::Idle;

        if (windupFinished) {
            nextClip = AnimClipID::Attack;
        } else if (!moving && world.has_component<EnemyAttackCooldownComponent>(id)) {
            auto& cd = world.get_component<EnemyAttackCooldownComponent>(id);
            bool isLeaper = world.has_component<EnemyArchetypeComponent>(id) &&
                            world.get_component<EnemyArchetypeComponent>(id).type == (uint8_t)EnemyArchetype::Leaper;
            if (!isLeaper && cd.windup <= 0.f && cd.remaining <= 0.f) {
                cd.windup = kEnemyAttackWindup;
                cd.remaining = cooldown;
                if (world.has_component<EnemyArchetypeComponent>(id) &&
                    enemy_archetype_def(world.get_component<EnemyArchetypeComponent>(id).type).ranged) {
                    float len = dist > 0.001f ? telegraph_distance_until_blocked(world, ePos, dx / dist, dy / dist)
                                               : 0.f;
                    TelegraphLineComponent& line = world.has_component<TelegraphLineComponent>(id)
                        ? world.get_component<TelegraphLineComponent>(id)
                        : world.add_component<TelegraphLineComponent>(id);
                    line.x2 = ePos.x + (dist > 0.001f ? dx / dist : 0.f) * len;
                    line.y2 = ePos.y + (dist > 0.001f ? dy / dist : 1.f) * len;
                    line.width = kRangedTelegraphWidth;
                    line.aimX = dist > 0.001f ? dx / dist : 0.f;
                    line.aimY = dist > 0.001f ? dy / dist : 1.f;
                }
            }
        }

        AnimationSystem_request_clip(world, id, nextClip);
    }
}
