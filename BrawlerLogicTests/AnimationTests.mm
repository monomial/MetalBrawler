#import <XCTest/XCTest.h>
#include "Simulation/World.h"
#include "Simulation/Systems/AnimationSystem.h"

static constexpr float kFixedDt = 1.0f / 120.0f;

// Actual fallback durations used when no character asset is loaded (see AnimationSystem.mm).
static constexpr float kIdleDur   = 3.83f;
static constexpr float kWalkDur   = 1.03f;
static constexpr float kAttackDur = 1.03f;
static constexpr float kHurtDur   = 1.50f;
static constexpr float kDeathDur  = 4.50f;

static EntityID make_animated(World& w, FactionComponent::Type faction = FactionComponent::Enemy) {
    EntityID e = w.defer_create();
    w.add_component<PositionComponent>(e) = {0, 0, 0};
    w.add_component<FactionComponent>(e).type = faction;
    AnimationComponent& anim = w.add_component<AnimationComponent>(e);
    anim.currentClip   = AnimClipID::Idle;
    anim.requestedClip = AnimClipID::Idle;
    anim.clipTime      = 0.f;
    anim.looping       = true;
    anim.dying         = false;
    return e;
}

static void advance(World& w, float seconds) {
    int ticks = (int)(seconds / kFixedDt) + 1;
    for (int i = 0; i < ticks; ++i) w.update(kFixedDt, kFixedDt);
}

@interface AnimationTests : XCTestCase
@end

@implementation AnimationTests

// ---------------------------------------------------------------------------
// Basic clip progression
// ---------------------------------------------------------------------------

- (void)test_clipTimeAdvancesEachTick {
    World world;
    EntityID e = make_animated(world);
    world.update(kFixedDt, kFixedDt);
    XCTAssertGreaterThan(world.get_component<AnimationComponent>(e).clipTime, 0.f);
}

- (void)test_loopingClip_wrapsAround {
    World world;
    EntityID e = make_animated(world);
    // Advance past one full Idle cycle (3.83s) plus a little extra.
    advance(world, kIdleDur + 0.1f);
    float t = world.get_component<AnimationComponent>(e).clipTime;
    XCTAssertLessThan(t, kIdleDur * 0.5f); // wrapped, not near the end
}

- (void)test_loopingClip_transitionsImmediately_onNewRequest {
    // Requesting a different clip from a looping clip should take effect
    // on the very next tick — not wait for the clip to end.
    World world;
    EntityID e = make_animated(world);
    AnimationSystem_request_clip(world, e, AnimClipID::Walk);
    world.update(kFixedDt, kFixedDt); // one tick
    XCTAssertEqual(world.get_component<AnimationComponent>(e).currentClip, AnimClipID::Walk);
}

- (void)test_nonLoopingClip_setsClipDoneAtEnd {
    World world;
    EntityID e = make_animated(world);
    auto& anim = world.get_component<AnimationComponent>(e);
    anim.currentClip   = AnimClipID::Attack;
    anim.requestedClip = AnimClipID::Attack;
    anim.looping       = false;
    advance(world, kAttackDur + 0.1f);
    XCTAssertTrue(world.get_component<AnimationComponent>(e).clipDone);
}

- (void)test_nonLoopingClip_transitionsToRequestedAfterFinish {
    World world;
    EntityID e = make_animated(world);
    auto& anim = world.get_component<AnimationComponent>(e);
    anim.currentClip   = AnimClipID::Attack;
    anim.requestedClip = AnimClipID::Idle;
    anim.looping       = false;
    advance(world, kAttackDur + 0.1f);
    XCTAssertEqual(world.get_component<AnimationComponent>(e).currentClip, AnimClipID::Idle);
}

- (void)test_hitStop_freezesAnimation {
    World world;
    EntityID e = make_animated(world);
    world.trigger_hit_stop(4);
    world.update(4 * kFixedDt, kFixedDt);
    XCTAssertEqualWithAccuracy(world.get_component<AnimationComponent>(e).clipTime, 0.f, 1e-4f);
}

- (void)test_noAnimationComponent_doesNotCrash {
    World world;
    EntityID e = world.defer_create();
    world.add_component<PositionComponent>(e) = {0, 0, 0};
    XCTAssertNoThrow(world.update(kFixedDt, kFixedDt));
}

// ---------------------------------------------------------------------------
// Dying + death animation — the class of bug we shipped in the second kill
// ---------------------------------------------------------------------------

// Case 1: killed while in a LOOPING clip (Idle/Walk) → immediate Death transition.
- (void)test_dying_inLoopingClip_transitionsImmediatelyToDeath {
    World world;
    EntityID e = make_animated(world); // starts in Idle (looping)
    auto& anim = world.get_component<AnimationComponent>(e);
    anim.dying         = true;
    anim.requestedClip = AnimClipID::Death;
    world.update(kFixedDt, kFixedDt);
    XCTAssertEqual(anim.currentClip, AnimClipID::Death);
    XCTAssertFalse(anim.clipDone);
}

// Case 2: killed while mid-HURT (the exact bug that caused the stuck state).
// The Death clip must NOT fire until Hurt finishes, but MUST fire once it does.
- (void)test_dying_killedMidHurt_transitionsToDeathAfterHurtFinishes {
    World world;
    EntityID e = make_animated(world);
    auto& anim = world.get_component<AnimationComponent>(e);
    anim.currentClip   = AnimClipID::Hurt;
    anim.requestedClip = AnimClipID::Death; // killing blow sets this
    anim.clipTime      = 0.f;
    anim.looping       = false;
    anim.dying         = true;

    // Before Hurt ends: must stay on Hurt.
    advance(world, kHurtDur * 0.5f);
    XCTAssertEqual(anim.currentClip, AnimClipID::Hurt);

    // After Hurt ends: must transition to Death.
    advance(world, kHurtDur);
    XCTAssertEqual(anim.currentClip, AnimClipID::Death);
    XCTAssertFalse(anim.clipDone);
}

// Case 3: same scenario but mid-Attack instead of mid-Hurt.
- (void)test_dying_killedMidAttack_transitionsToDeathAfterAttackFinishes {
    World world;
    EntityID e = make_animated(world);
    auto& anim = world.get_component<AnimationComponent>(e);
    anim.currentClip   = AnimClipID::Attack;
    anim.requestedClip = AnimClipID::Death;
    anim.clipTime      = 0.f;
    anim.looping       = false;
    anim.dying         = true;

    advance(world, kAttackDur + 0.1f);
    XCTAssertEqual(anim.currentClip, AnimClipID::Death);
}

// Case 4: once in Death clip, no further transitions (not to Idle, Walk, etc.).
- (void)test_dying_deathClip_doesNotTransitionAway {
    World world;
    EntityID e = make_animated(world);
    auto& anim = world.get_component<AnimationComponent>(e);
    anim.currentClip   = AnimClipID::Death;
    anim.requestedClip = AnimClipID::Idle; // something tries to request Idle
    anim.clipTime      = 0.f;
    anim.looping       = false;
    anim.dying         = true;

    advance(world, kDeathDur + 0.5f);
    XCTAssertEqual(anim.currentClip, AnimClipID::Death);
    XCTAssertTrue(anim.clipDone);
}

// Case 5: non-player entity is defer_destroyed after death clip completes.
- (void)test_dying_nonPlayer_destroyedAfterDeathClip {
    World world;
    EntityID e = make_animated(world, FactionComponent::Enemy);
    auto& anim = world.get_component<AnimationComponent>(e);
    anim.currentClip   = AnimClipID::Death;
    anim.requestedClip = AnimClipID::Death;
    anim.clipTime      = 0.f;
    anim.looping       = false;
    anim.dying         = true;

    advance(world, kDeathDur + 0.1f);
    // After death clip + flush, entity should have no components.
    XCTAssertFalse(world.has_component<AnimationComponent>(e));
}

// Case 6: player entity is NOT destroyed after death clip (game loop handles it).
- (void)test_dying_player_notDestroyedByAnimationSystem {
    World world;
    EntityID e = make_animated(world, FactionComponent::Player);
    world.add_component<PlayerTagComponent>(e) = {true, 0};
    auto& anim = world.get_component<AnimationComponent>(e);
    anim.currentClip   = AnimClipID::Death;
    anim.requestedClip = AnimClipID::Death;
    anim.clipTime      = 0.f;
    anim.looping       = false;
    anim.dying         = true;

    advance(world, kDeathDur + 0.1f);
    // Player should still exist — BrawlerDelegate handles game-over instead.
    XCTAssertTrue(world.has_component<AnimationComponent>(e));
}

// ---------------------------------------------------------------------------
// Cross-fade bookkeeping (matrix output needs real assets; not tested here)
// ---------------------------------------------------------------------------

- (void)test_transition_armsCrossFade {
    World world;
    EntityID e = make_animated(world);
    auto& anim = world.get_component<AnimationComponent>(e);
    anim.clipTime = 0.5f;

    anim.requestedClip = AnimClipID::Walk;
    world.update(kFixedDt, kFixedDt);

    const auto& a = world.get_component<AnimationComponent>(e);
    XCTAssertEqual((int)a.currentClip, (int)AnimClipID::Walk);
    XCTAssertEqual((int)a.prevClip,    (int)AnimClipID::Idle);
    XCTAssertGreaterThan(a.blendRemaining, 0.f, @"transition must arm the cross-fade");
    XCTAssertGreaterThan(a.prevClipTime, 0.4f, @"outgoing pose frozen at its clip time");
}

- (void)test_crossFade_decaysToZero {
    World world;
    EntityID e = make_animated(world);
    world.get_component<AnimationComponent>(e).requestedClip = AnimClipID::Walk;

    advance(world, 0.2f); // > kAnimBlendDuration (0.1s)

    XCTAssertEqual(world.get_component<AnimationComponent>(e).blendRemaining, 0.f,
                   @"blend must fully decay after the fade window");
}

@end
