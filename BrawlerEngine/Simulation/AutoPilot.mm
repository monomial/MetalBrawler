#include "AutoPilot.h"
#include "Simulation/World.h"
#include <math.h>

// Stop and punch inside CombatSystem's 130-unit attack range. Approaching
// head-on also sets FacingComponent toward the target, so the ±70° punch arc
// check passes once we stop.
static constexpr float kEngageDist = 100.0f;
static constexpr int   kStuckSampleFrames = 30; // ~0.5s at the fixed 60Hz scenario driver
static constexpr int   kUnstuckFrames     = 24; // ~0.4s
static float s_lastX[4] = {};
static float s_lastY[4] = {};
static int   s_sampleFrames[4] = {};
static int   s_unstuckFrames[4] = {};
static bool  s_hasSample[4] = {};

void AutoPilot_reset() {
    for (int i = 0; i < 4; ++i) {
        s_lastX[i] = 0.f;
        s_lastY[i] = 0.f;
        s_sampleFrames[i] = 0;
        s_unstuckFrames[i] = 0;
        s_hasSample[i] = false;
    }
}

InputState AutoPilot_input(World& world, int playerIndex) {
    InputState in = {};

    // Find this player's entity.
    EntityID me = kInvalidEntity;
    for (EntityID id = 0; id < world.entity_count(); ++id) {
        if (!world.player_tags().present(id)) continue;
        if (world.get_component<PlayerTagComponent>(id).playerIndex == playerIndex) {
            me = id;
            break;
        }
    }
    if (me == kInvalidEntity || !world.has_component<PositionComponent>(me)) return in;
    if (world.has_component<DownedComponent>(me)) return in;
    if (world.has_component<AnimationComponent>(me) &&
        world.get_component<AnimationComponent>(me).dying) return in;

    const PositionComponent& myPos = world.get_component<PositionComponent>(me);

    if (world.has_component<SpecialMeterComponent>(me) &&
        world.get_component<SpecialMeterComponent>(me).charge >= 1.f) {
        int nearby = 0;
        for (EntityID id = 0; id < world.entity_count(); ++id) {
            if (!world.has_component<FactionComponent>(id)) continue;
            if (world.get_component<FactionComponent>(id).type != FactionComponent::Enemy) continue;
            if (!world.has_component<PositionComponent>(id)) continue;
            if (world.has_component<AnimationComponent>(id) &&
                world.get_component<AnimationComponent>(id).dying) continue;
            const PositionComponent& p = world.get_component<PositionComponent>(id);
            float dx = p.x - myPos.x, dy = p.y - myPos.y;
            if (dx * dx + dy * dy <= 220.f * 220.f)
                ++nearby;
        }
        if (nearby >= 2)
            in.special = true;
    }

    // Nearest living enemy.
    bool  found  = false;
    float bestD2 = 0.f, bdx = 0.f, bdy = 0.f;
    for (EntityID id = 0; id < world.entity_count(); ++id) {
        if (!world.has_component<FactionComponent>(id)) continue;
        if (world.get_component<FactionComponent>(id).type != FactionComponent::Enemy) continue;
        if (!world.has_component<PositionComponent>(id)) continue;
        if (world.has_component<AnimationComponent>(id) &&
            world.get_component<AnimationComponent>(id).dying) continue;

        const PositionComponent& p = world.get_component<PositionComponent>(id);
        float dx = p.x - myPos.x, dy = p.y - myPos.y;
        float d2 = dx * dx + dy * dy;
        if (!found || d2 < bestD2) {
            bestD2 = d2; bdx = dx; bdy = dy; found = true;
        }
    }
    EntityID downedMate = kInvalidEntity;
    float downedD2 = 0.f, ddx = 0.f, ddy = 0.f;
    for (EntityID id = 0; id < world.entity_count(); ++id) {
        if (id == me) continue;
        if (!world.player_tags().present(id)) continue;
        if (!world.has_component<DownedComponent>(id)) continue;
        if (!world.has_component<PositionComponent>(id)) continue;
        const PositionComponent& p = world.get_component<PositionComponent>(id);
        float dx = p.x - myPos.x, dy = p.y - myPos.y;
        float d2 = dx * dx + dy * dy;
        if (downedMate == kInvalidEntity || d2 < downedD2) {
            downedMate = id; downedD2 = d2; ddx = dx; ddy = dy;
        }
    }

    if (downedMate != kInvalidEntity && (!found || bestD2 > 150.f * 150.f)) {
        float d = sqrtf(downedD2);
        in.moveX = (d > 0.001f) ? ddx / d : 0.f;
        in.moveY = (d > 0.001f) ? ddy / d : 0.f;
        return in;
    }

    if (!found) {
        EntityID exitID = kInvalidEntity;
        float exitD2 = 0.f, edx = 0.f, edy = 0.f;
        for (EntityID id = 0; id < world.entity_count(); ++id) {
            if (!world.exits().present(id)) continue;
            if (!world.has_component<PositionComponent>(id)) continue;
            const PositionComponent& p = world.get_component<PositionComponent>(id);
            float dx = p.x - myPos.x, dy = p.y - myPos.y;
            float d2 = dx * dx + dy * dy;
            if (exitID == kInvalidEntity || d2 < exitD2) {
                exitID = id; exitD2 = d2; edx = dx; edy = dy;
            }
        }
        if (exitID != kInvalidEntity) {
            float d = sqrtf(exitD2);
            in.moveX = (d > 0.001f) ? edx / d : 0.f;
            in.moveY = (d > 0.001f) ? edy / d : 0.f;
        }
        return in;
    }

    float dist = sqrtf(bestD2);

    // Defense: dodge ONLY boss threats (its swing, its charge telegraph/rush —
    // the 2-damage hits). Normal enemy hits are traded through: dodging costs
    // ~1.2s of attack time, which loses the war of attrition in crowded rooms.
    bool meCanDodge = world.has_component<AnimationComponent>(me) &&
                      (world.get_component<AnimationComponent>(me).currentClip == AnimClipID::Idle ||
                       world.get_component<AnimationComponent>(me).currentClip == AnimClipID::Walk);
    if (meCanDodge) {
        for (EntityID id = 0; id < world.entity_count(); ++id) {
            if (!world.boss_tags().present(id)) continue;
            if (!world.has_component<PositionComponent>(id)) continue;
            if (world.has_component<AnimationComponent>(id) &&
                world.get_component<AnimationComponent>(id).dying) continue;

            bool threatening = world.has_component<AnimationComponent>(id) &&
                               world.get_component<AnimationComponent>(id).currentClip
                                   == AnimClipID::Attack;
            if (world.has_component<BossChargeComponent>(id)) {
                uint8_t st = world.get_component<BossChargeComponent>(id).state;
                threatening |= (st == BossChargeComponent::Telegraph ||
                                st == BossChargeComponent::Charge);
            }
            if (!threatening) continue;

            const auto& p = world.get_component<PositionComponent>(id);
            float dx = p.x - myPos.x, dy = p.y - myPos.y;
            if (dx * dx + dy * dy < 240.f * 240.f) {
                in.dodge = true;
                return in;
            }
        }
    }

    // Always steer toward the target — also while punching. Movement is what
    // updates FacingComponent, and a stale facing fails CombatSystem's ±70°
    // arc check forever (the bot once dead-locked whiffing at a rusher that
    // approached from a different direction than its previous kill).
    in.moveX = (dist > 0.001f) ? bdx / dist : 0.f;
    in.moveY = (dist > 0.001f) ? bdy / dist : 0.f;

    int slot = (playerIndex >= 0 && playerIndex < 4) ? playerIndex : 0;
    if (!s_hasSample[slot]) {
        s_lastX[slot] = myPos.x;
        s_lastY[slot] = myPos.y;
        s_sampleFrames[slot] = 0;
        s_unstuckFrames[slot] = 0;
        s_hasSample[slot] = true;
    }
    s_sampleFrames[slot] += 1;
    if (s_sampleFrames[slot] >= kStuckSampleFrames) {
        float sx = myPos.x - s_lastX[slot];
        float sy = myPos.y - s_lastY[slot];
        bool tryingToMove = (in.moveX * in.moveX + in.moveY * in.moveY) > 0.01f;
        if (tryingToMove && sx * sx + sy * sy <= 2.f * 2.f)
            s_unstuckFrames[slot] = kUnstuckFrames;
        else if (sx * sx + sy * sy > 120.f * 120.f)
            s_unstuckFrames[slot] = 0; // room reload or respawn
        s_lastX[slot] = myPos.x;
        s_lastY[slot] = myPos.y;
        s_sampleFrames[slot] = 0;
    }
    if (s_unstuckFrames[slot] > 0 &&
        (in.moveX * in.moveX + in.moveY * in.moveY) > 0.01f) {
        float px = -in.moveY;
        float py =  in.moveX;
        in.moveX = px;
        in.moveY = py;
        s_unstuckFrames[slot] -= 1;
    }

    if (dist <= kEngageDist) {
        // Hold attack through the first punch (which both starts the swing and
        // queues the Attack→Attack2 combo), but release during the finisher so
        // the clip can exit to Idle and the next swing can start.
        bool inFinisher = world.has_component<AnimationComponent>(me) &&
                          world.get_component<AnimationComponent>(me).currentClip == AnimClipID::Attack2;
        in.attack = !inFinisher;
    }
    return in;
}
