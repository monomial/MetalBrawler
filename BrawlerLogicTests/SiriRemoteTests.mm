#import <XCTest/XCTest.h>
#include "Platform/SiriRemoteInput.h"
#include <math.h>

static constexpr float kEps = 1e-4f;

@interface SiriRemoteTests : XCTestCase
@end

@implementation SiriRemoteTests

- (void)test_belowDeadZone_returnsZero {
    InputState s = SiriRemote_processSwipeDelta(0.05f, 0.05f);
    XCTAssertEqualWithAccuracy(s.moveX, 0.f, kEps);
    XCTAssertEqualWithAccuracy(s.moveY, 0.f, kEps);
}

- (void)test_atDeadZoneEdge_returnsZero {
    // Exactly at dead-zone boundary — remapped value is 0.
    InputState s = SiriRemote_processSwipeDelta(0.10f, 0.f);
    XCTAssertEqualWithAccuracy(s.moveX, 0.f, kEps);
}

- (void)test_fullSwipe_returnsOne {
    InputState s = SiriRemote_processSwipeDelta(0.80f, 0.f);
    // curved(1.0) = 1.0, direction = (1, 0)
    XCTAssertEqualWithAccuracy(s.moveX, 1.f, kEps);
    XCTAssertEqualWithAccuracy(s.moveY, 0.f, kEps);
}

- (void)test_diagonal_clampedToUnitCircle {
    // Full diagonal: raw (0.8, 0.8) — after processing both axes would be 1.0
    // → must be clamped to unit circle.
    InputState s = SiriRemote_processSwipeDelta(0.80f, 0.80f);
    float len = sqrtf(s.moveX * s.moveX + s.moveY * s.moveY);
    XCTAssertLessThanOrEqual(len, 1.0f + kEps);
}

- (void)test_accelerationCurve_midpoint_lessThanHalf {
    // At mid-range input, curved output should be less than 0.5 (square curve).
    // raw mag ≈ 0.45 → remapped ≈ 0.5 → curved ≈ 0.25
    InputState s = SiriRemote_processSwipeDelta(0.45f, 0.f);
    XCTAssertLessThan(s.moveX, 0.5f);
    XCTAssertGreaterThan(s.moveX, 0.f);
}

- (void)test_negativeDirection {
    InputState s = SiriRemote_processSwipeDelta(-0.80f, 0.f);
    XCTAssertEqualWithAccuracy(s.moveX, -1.f, kEps);
}

@end
