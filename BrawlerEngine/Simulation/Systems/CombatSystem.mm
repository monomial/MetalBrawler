#include "CombatSystem.h"
#include "Simulation/World.h"
#include "Platform/InputState.h"
#include "Simulation/Systems/AnimationSystem.h"
#include "Simulation/Systems/ScreenShakeSystem.h"
#include <math.h>

static constexpr float kAttackRange      = 80.0f;
static constexpr int   kHitStopTicks     = 4;      // ~33ms freeze on hit
// Punch arc: enemy must be within ±70° of the player's facing direction.
// cos(70°) ≈ 0.342. Enemies behind the player (dot < threshold) are not hit.
static constexpr float kPunchArcCosine   = 0.342f;

// Active-frame window for each clip: the fraction of clip duration where the
// hitbox is live, and the damage dealt on contact. Zero damage = not an attack.
// Fractions are tunable — set them by watching the animation and noting when
// the fist is at peak extension.
struct AttackWindow {
    float startFrac; // fraction of clip where hitbox opens
    float endFrac;   // fraction of clip where hitbox closes
    int   damage;
};

static const AttackWindow kAttackWindows[(int)AnimClipID::Count] = {
    {0.f,   0.f,   0},  // Idle   — no hitbox
    {0.f,   0.f,   0},  // Walk   — no hitbox
    {0.35f, 0.60f, 1},  // Attack — jab: fist extends around 35–60% of clip
    {0.f,   0.f,   0},  // Hurt   — no hitbox
    {0.f,   0.f,   0},  // Death  — no hitbox
};

void CombatSystem_update(World& world, float gameDt) {
    if (gameDt == 0.0f) return; // frozen during HitStop

    // Find the player.
    EntityID playerID = kInvalidEntity;
    uint32_t count = world.entity_count();
    for (EntityID id = 0; id < count; ++id) {
        if (world.player_tags().present(id)) { playerID = id; break; }
    }
    if (playerID == kInvalidEntity) return;
    if (!world.has_component<PositionComponent>(playerID)) return;
    if (!world.has_component<AnimationComponent>(playerID)) return;

    AnimationComponent& playerAnim = world.get_component<AnimationComponent>(playerID);

    // Dead players cannot attack.
    if (playerAnim.dying) return;

    // Only deal damage when the player is inside an attack clip's active window.
    const AttackWindow& win = kAttackWindows[(int)playerAnim.currentClip];
    if (win.damage == 0) return; // not an attack clip

    // Already hit something this swing — don't hit again.
    if (playerAnim.hitApplied) return;

    // Check whether clipTime is inside the active window.
    float clipDur   = AnimationSystem_clip_duration(world, playerID, playerAnim.currentClip);
    float winStart  = clipDur * win.startFrac;
    float winEnd    = clipDur * win.endFrac;
    if (playerAnim.clipTime < winStart || playerAnim.clipTime > winEnd) return;

    const PositionComponent playerPos = world.get_component<PositionComponent>(playerID);

    // Facing direction for arc check — fall back to +Y if component absent.
    float facingDx = 0.f, facingDy = 1.f;
    if (world.has_component<FacingComponent>(playerID)) {
        const FacingComponent& f = world.get_component<FacingComponent>(playerID);
        facingDx = f.dx; facingDy = f.dy;
    }

    bool hitAnything = false;

    for (EntityID id = 0; id < count; ++id) {
        if (!world.factions().present(id)) continue;
        if (world.factions().get(id).type != FactionComponent::Enemy) continue;
        if (!world.has_component<PositionComponent>(id)) continue;
        if (!world.has_component<HealthComponent>(id)) continue;
        // Skip entities already in their death animation.
        if (world.has_component<AnimationComponent>(id) &&
            world.get_component<AnimationComponent>(id).dying) continue;

        const PositionComponent& ePos = world.get_component<PositionComponent>(id);
        float dx   = ePos.x - playerPos.x;
        float dy   = ePos.y - playerPos.y;
        float dist = sqrtf(dx * dx + dy * dy);
        if (dist > kAttackRange) continue;

        // Arc check: enemy must be within ±70° of the player's facing direction.
        // dot(facing, normalize(enemy - player)) > cos(70°)
        if (dist > 0.001f) {
            float dot = (dx / dist) * facingDx + (dy / dist) * facingDy;
            if (dot < kPunchArcCosine) continue;
        }

        HealthComponent& hp = world.get_component<HealthComponent>(id);
        hp.current -= win.damage;
        hitAnything = true;

        world.events().emit_hit_contact(playerID, id);
        world.events().emit_damage(id, win.damage);

        if (hp.current <= 0) {
            world.events().emit_died(id);
            if (world.has_component<AnimationComponent>(id)) {
                world.get_component<AnimationComponent>(id).dying = true;
                AnimationSystem_request_clip(world, id, AnimClipID::Death);
            } else {
                world.defer_destroy(id);
            }
        } else if (world.has_component<AnimationComponent>(id)) {
            AnimationSystem_request_clip(world, id, AnimClipID::Hurt);
        }
    }

    if (hitAnything) {
        playerAnim.hitApplied = true; // one hit per swing
    }

    if (hitAnything) {
        world.trigger_hit_stop(kHitStopTicks);
        ScreenShakeSystem_trigger(world, 18.f);
    }
}
