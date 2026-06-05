#include "AnimationSystem.h"
#include "Simulation/World.h"
#include "Assets/CharacterLoader.h"

static const LoadedCharacter* s_playerChar = nullptr;
static const LoadedCharacter* s_enemyChar  = nullptr;

void AnimationSystem_set_characters(const LoadedCharacter* player,
                                    const LoadedCharacter* enemy) {
    s_playerChar = player;
    s_enemyChar  = enemy;
}

// Fallback clip durations used before character assets are loaded.
// These match the actual Mixamo clips we exported (idle 3.83s, walk 1.03s, etc.).
static const float kClipDurationFallback[(int)AnimClipID::Count] = {
    3.83f, // Idle    — looping
    1.03f, // Walk    — looping
    1.03f, // Attack  — one-shot
    1.50f, // Hurt    — one-shot
    4.50f, // Death   — one-shot
    2.40f, // Dodge   — one-shot (72 frames @ 30fps)
};

static float clip_duration(const LoadedCharacter* charData, AnimClipID id) {
    if (charData && charData->clipLoaded[(int)id]) {
        float d = charData->clips[(int)id].duration();
        if (d > 0.f) return d;
    }
    return kClipDurationFallback[(int)id];
}

static bool clip_loops(AnimClipID id) {
    return id == AnimClipID::Idle || id == AnimClipID::Walk;
}

static bool is_combat_speed_clip(AnimClipID id) {
    return id == AnimClipID::Attack || id == AnimClipID::Hurt || id == AnimClipID::Dodge;
}

void AnimationSystem_update(World& world, float gameDt) {
    if (gameDt == 0.f) return; // frozen during HitStop

    uint32_t count = world.entity_count();
    for (EntityID id = 0; id < count; ++id) {
        if (!world.has_component<AnimationComponent>(id)) continue;
        AnimationComponent& anim = world.get_component<AnimationComponent>(id);

        // Resolve character data for accurate clip durations.
        const LoadedCharacter* charData = nullptr;
        if (world.has_component<FactionComponent>(id)) {
            auto t = world.get_component<FactionComponent>(id).type;
            charData = (t == FactionComponent::Player) ? s_playerChar : s_enemyChar;
        }

        float duration = clip_duration(charData, anim.currentClip);
        // Attack and Hurt play at 1.5× so punches feel snappy and hit reactions
        // are brief. Idle/Walk/Death keep normal speed.
        static constexpr float kCombatSpeed = 2.0f;
        anim.clipTime += gameDt * (is_combat_speed_clip(anim.currentClip) ? kCombatSpeed : 1.0f);
        anim.clipDone  = false;

        if (clip_loops(anim.currentClip)) {
            // Looping clips transition immediately when any different clip is requested.
            if (anim.requestedClip != anim.currentClip) {
                anim.currentClip  = anim.requestedClip;
                anim.clipTime     = 0.f;
                anim.hitApplied   = false;
                anim.looping      = clip_loops(anim.currentClip);
            } else if (anim.clipTime >= duration) {
                anim.clipTime = fmodf(anim.clipTime, duration);
            }
        } else {
            // Non-looping: play through fully, then allow transition.
            if (anim.clipTime >= duration) {
                anim.clipTime = duration;
                anim.clipDone = true;
                // Dying entities may only transition to Death (not back to Idle/Walk).
                // Non-dying entities may transition to any requested clip.
                bool canTransition = !anim.dying || anim.requestedClip == AnimClipID::Death;
                if (canTransition && anim.requestedClip != anim.currentClip) {
                    anim.currentClip  = anim.requestedClip;
                    anim.clipTime     = 0.f;
                    anim.hitApplied   = false;
                    anim.clipDone    = false;
                    anim.looping     = clip_loops(anim.currentClip);
                }
            }
        }

        if (charData && charData->clipLoaded[(int)anim.currentClip])
            charData->clips[(int)anim.currentClip].sample(anim.clipTime, anim.boneMatrices);
    }

    // Destroy non-player entities whose death animation has finished.
    for (EntityID id = 0; id < count; ++id) {
        if (!world.has_component<AnimationComponent>(id)) continue;
        if (world.player_tags().present(id)) continue; // player death handled by game loop
        const AnimationComponent& anim = world.get_component<AnimationComponent>(id);
        if (anim.dying && anim.clipDone && anim.currentClip == AnimClipID::Death)
            world.defer_destroy(id);
    }
}

void AnimationSystem_request_clip(World& world, EntityID entity, AnimClipID clip) {
    if (!world.has_component<AnimationComponent>(entity)) return;
    world.get_component<AnimationComponent>(entity).requestedClip = clip;
}

float AnimationSystem_clip_duration(World& world, EntityID entity, AnimClipID clip) {
    const LoadedCharacter* charData = nullptr;
    if (world.has_component<FactionComponent>(entity)) {
        auto t = world.get_component<FactionComponent>(entity).type;
        charData = (t == FactionComponent::Player) ? s_playerChar : s_enemyChar;
    }
    return clip_duration(charData, clip);
}
