#import <XCTest/XCTest.h>
#include "Simulation/World.h"
#include "Simulation/Systems/ScreenShakeSystem.h"

static constexpr float kFixedDt = 1.0f / 120.0f;
static constexpr float kEps     = 1e-4f;

// Reset shake state between tests by decaying it to zero.
static void drain_shake(World& world) {
    for (int i = 0; i < 600; ++i) // 5 seconds at 120Hz — enough for full decay
        ScreenShakeSystem_update(world, kFixedDt);
}

@interface ScreenShakeTests : XCTestCase
@end

@implementation ScreenShakeTests

- (void)setUp {
    // Drain any residual shake from previous tests (static state).
    World world;
    drain_shake(world);
}

- (void)test_noTrigger_offsetIsZero {
    World world;
    simd_float2 off = ScreenShakeSystem_offset(world);
    XCTAssertEqualWithAccuracy(off.x, 0.f, kEps);
    XCTAssertEqualWithAccuracy(off.y, 0.f, kEps);
}

- (void)test_trigger_offsetBecomesNonZero {
    World world;
    ScreenShakeSystem_trigger(world, 20.f);
    ScreenShakeSystem_update(world, kFixedDt);

    simd_float2 off = ScreenShakeSystem_offset(world);
    float mag = sqrtf(off.x*off.x + off.y*off.y);
    XCTAssertGreaterThan(mag, 0.f);
    drain_shake(world);
}

- (void)test_magnitude_clampedByTriggerValue {
    World world;
    ScreenShakeSystem_trigger(world, 10.f);
    ScreenShakeSystem_update(world, kFixedDt);

    simd_float2 off = ScreenShakeSystem_offset(world);
    float mag = sqrtf(off.x*off.x + off.y*off.y);
    // Offset magnitude <= trigger magnitude.
    XCTAssertLessThanOrEqual(mag, 10.f + kEps);
    drain_shake(world);
}

- (void)test_decaysToZero_afterEnoughTime {
    World world;
    ScreenShakeSystem_trigger(world, 20.f);
    drain_shake(world); // 5 seconds of decay

    simd_float2 off = ScreenShakeSystem_offset(world);
    float mag = sqrtf(off.x*off.x + off.y*off.y);
    XCTAssertEqualWithAccuracy(mag, 0.f, kEps);
}

- (void)test_smallerTrigger_doesNotOverrideActiveLarger {
    World world;
    ScreenShakeSystem_trigger(world, 30.f); // large
    ScreenShakeSystem_update(world, kFixedDt);
    simd_float2 offBefore = ScreenShakeSystem_offset(world);
    float magBefore = sqrtf(offBefore.x*offBefore.x + offBefore.y*offBefore.y);

    ScreenShakeSystem_trigger(world, 5.f); // small — should not reduce magnitude
    ScreenShakeSystem_update(world, kFixedDt);
    simd_float2 offAfter = ScreenShakeSystem_offset(world);
    float magAfter = sqrtf(offAfter.x*offAfter.x + offAfter.y*offAfter.y);

    // After a second trigger with smaller value, magnitude should still be > 5 units
    // (the 30-unit shake hasn't fully decayed in 2 ticks).
    XCTAssertGreaterThan(magAfter, 5.f);
    (void)magBefore;
    drain_shake(world);
}

- (void)test_largerTrigger_overridesSmaller {
    World world;
    ScreenShakeSystem_trigger(world, 5.f);
    ScreenShakeSystem_update(world, kFixedDt);

    ScreenShakeSystem_trigger(world, 30.f); // larger — takes over
    ScreenShakeSystem_update(world, kFixedDt);

    simd_float2 off = ScreenShakeSystem_offset(world);
    float mag = sqrtf(off.x*off.x + off.y*off.y);
    XCTAssertGreaterThan(mag, 5.f); // significantly more than the 5-unit trigger
    drain_shake(world);
}

@end
