#import <XCTest/XCTest.h>
#include "Renderer/ParticleSim.h"

@interface ParticleSimTests : XCTestCase
@end

@implementation ParticleSimTests

- (void)test_burst_spawnsRequestedCount {
    ParticleSim sim;
    sim.spawn_burst(0, 0, 50, 14, 300.f, 12.f, 1, 1, 1, 7);
    XCTAssertEqual(sim.count, 14);
}

- (void)test_poolCap_dropsExcess {
    ParticleSim sim;
    sim.spawn_burst(0, 0, 0, ParticleSim::kCapacity + 50, 300.f, 12.f, 1, 1, 1, 7);
    XCTAssertEqual(sim.count, ParticleSim::kCapacity);
    // Another burst on a full pool must not write out of bounds.
    sim.spawn_burst(0, 0, 0, 10, 300.f, 12.f, 1, 1, 1, 9);
    XCTAssertEqual(sim.count, ParticleSim::kCapacity);
}

- (void)test_particlesMoveAndDie {
    ParticleSim sim;
    sim.spawn_burst(0, 0, 50, 20, 300.f, 12.f, 1, 1, 1, 7);

    sim.update(0.05f);
    bool anyMoved = false;
    for (int i = 0; i < sim.count; ++i) {
        const auto& p = sim.particles[i];
        if (p.x != 0.f || p.y != 0.f) { anyMoved = true; break; }
    }
    XCTAssertTrue(anyMoved, @"particles must move after update");

    // Max life is 0.5s; everything must be recycled after 1s.
    for (int i = 0; i < 20; ++i) sim.update(0.05f);
    XCTAssertEqual(sim.count, 0, @"all particles recycled after life expires");
}

- (void)test_sameSeed_sameBurst {
    ParticleSim a, b;
    a.spawn_burst(10, 20, 30, 8, 300.f, 12.f, 1, 0.5f, 0, 42);
    b.spawn_burst(10, 20, 30, 8, 300.f, 12.f, 1, 0.5f, 0, 42);
    for (int i = 0; i < a.count; ++i) {
        XCTAssertEqual(a.particles[i].vx, b.particles[i].vx);
        XCTAssertEqual(a.particles[i].vy, b.particles[i].vy);
        XCTAssertEqual(a.particles[i].life, b.particles[i].life);
    }
}

- (void)test_zeroDt_noChange {
    ParticleSim sim;
    sim.spawn_burst(0, 0, 50, 5, 300.f, 12.f, 1, 1, 1, 7);
    float x0 = sim.particles[0].x;
    sim.update(0.f);
    XCTAssertEqual(sim.particles[0].x, x0);
    XCTAssertEqual(sim.count, 5);
}

@end
