#import <XCTest/XCTest.h>
#include "Simulation/World.h"

// BrawlerLogicTests — XCTest suite for ECS logic (no GPU required).
// Target: BrawlerLogicTests (macOS bundle.unit-test)
// See docs/design.md § "XCTest Suite" for the full test plan.

@interface WorldTests : XCTestCase
@end

@implementation WorldTests

- (void)test_deferCreate_returnsSequentialIDs {
    World world;
    EntityID a = world.defer_create();
    EntityID b = world.defer_create();
    XCTAssertNotEqual(a, b);
    XCTAssertEqual(b, a + 1);
}

- (void)test_update_doesNotCrash {
    World world;
    // Smoke test: one frame with zero dt should not crash or assert.
    XCTAssertNoThrow(world.update(0.0f, 0.0f));
}

- (void)test_deferDestroy_withinBufferLimit {
    World world;
    // Create and destroy 256 entities in one frame — should not overflow.
    for (int i = 0; i < 256; ++i) {
        EntityID id = world.defer_create();
        world.defer_destroy(id);
    }
    XCTAssertNoThrow(world.update(0.016f, 0.016f));
}

@end
