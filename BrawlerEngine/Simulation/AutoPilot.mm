#include "AutoPilot.h"
#include "Simulation/World.h"
#include <math.h>

// Stop and punch inside CombatSystem's 130-unit attack range. Approaching
// head-on also sets FacingComponent toward the target, so the ±70° punch arc
// check passes once we stop.
static constexpr float kEngageDist = 100.0f;

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
    if (world.has_component<AnimationComponent>(me) &&
        world.get_component<AnimationComponent>(me).dying) return in;

    const PositionComponent& myPos = world.get_component<PositionComponent>(me);

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
    if (!found) return in; // room clearing — stand still

    float dist = sqrtf(bestD2);
    if (dist > kEngageDist) {
        in.moveX = bdx / dist;
        in.moveY = bdy / dist;
    } else {
        // Tap attack like a human: a held button never re-triggers, because a
        // finished non-looping clip only transitions when a DIFFERENT clip is
        // requested (AnimationSystem). Release while mid-swing so the clip can
        // exit to Idle, then press again next frame.
        bool midSwing = world.has_component<AnimationComponent>(me) &&
                        world.get_component<AnimationComponent>(me).currentClip == AnimClipID::Attack;
        in.attack = !midSwing;
    }
    return in;
}
