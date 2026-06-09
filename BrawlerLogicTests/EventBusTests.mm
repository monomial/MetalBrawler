#import <XCTest/XCTest.h>
#include "Simulation/EventBus.h"

@interface EventBusTests : XCTestCase
@end

@implementation EventBusTests

- (void)test_emitAndIterate {
    EventBus bus;
    bus.emit_damage(42, 1);
    bus.emit_died(42);

    int damageCount = 0, deathCount = 0;
    bus.for_each(EventType::DamageDealt, [&](const Event&){ ++damageCount; });
    bus.for_each(EventType::EntityDied,  [&](const Event&){ ++deathCount; });

    XCTAssertEqual(damageCount, 1);
    XCTAssertEqual(deathCount,  1);
}

- (void)test_clear_emptiesSlots {
    EventBus bus;
    bus.emit_damage(1, 1);
    bus.clear();

    int count = 0;
    bus.for_each(EventType::DamageDealt, [&](const Event&){ ++count; });
    XCTAssertEqual(count, 0);
}

- (void)test_payloadRoundTrip {
    EventBus bus;
    bus.emit_damage(99, 5);

    bus.for_each(EventType::DamageDealt, [](const Event& e){
        XCTAssertEqual(e.damageDealt.targetID, (uint32_t)99);
        XCTAssertEqual(e.damageDealt.amount,   5);
    });
}

- (void)test_slot256_overflow_dropsInRelease {
    EventBus bus;
    // Fill to capacity
    for (int i = 0; i < EventBus::kCapacity; ++i)
        bus.emit_damage(i, 1);
    XCTAssertEqual(bus.count, EventBus::kCapacity);

#ifdef NDEBUG
    // In release, slot 257 is silently dropped and dropCount increments.
    bus.emit_damage(999, 1);
    XCTAssertEqual(bus.count,     EventBus::kCapacity);
    XCTAssertEqual(bus.dropCount, (uint32_t)1);
#else
    // In debug we assert — don't test overflow directly, just verify count.
    XCTAssertEqual(bus.count, EventBus::kCapacity);
#endif
}

- (void)test_hitContact_payload {
    EventBus bus;
    bus.emit_hit_contact(1, 7);
    bus.for_each(EventType::HitContact, [](const Event& e){
        XCTAssertEqual(e.hitContact.attackerID, (uint32_t)1);
        XCTAssertEqual(e.hitContact.targetID,   (uint32_t)7);
    });
}

- (void)test_attackStarted_payload {
    EventBus bus;
    bus.emit_attack_started(3, 6); // clipID 6 = Attack2
    int seen = 0;
    bus.for_each(EventType::AttackStarted, [&seen](const Event& e){
        XCTAssertEqual(e.attackStarted.entityID, (uint32_t)3);
        XCTAssertEqual(e.attackStarted.clipID,   (uint8_t)6);
        seen++;
    });
    XCTAssertEqual(seen, 1);
}

- (void)test_dodgeStarted_payload {
    EventBus bus;
    bus.emit_dodge_started(9);
    int seen = 0;
    bus.for_each(EventType::DodgeStarted, [&seen](const Event& e){
        XCTAssertEqual(e.dodgeStarted.entityID, (uint32_t)9);
        seen++;
    });
    XCTAssertEqual(seen, 1);
}

@end
