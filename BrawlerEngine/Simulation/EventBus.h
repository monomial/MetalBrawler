#pragma once
#include <stdint.h>
#include <cassert>

// Event types — add new entries here and a handler in the relevant system.
enum class EventType : uint8_t {
    None = 0,
    DamageDealt,   // entity took damage
    EntityDied,    // entity HP hit 0, queued for destroy
    HitContact,    // attack landed (triggers hit-stop + shake)
    AttackStarted, // an Attack/Attack2 clip actually began (audio: swing whoosh)
    DodgeStarted,  // a Dodge clip actually began (audio + haptics)
    BossTelegraph, // boss is winding up a charge (audio + warning particles)
};

struct DamageDealtPayload   { uint32_t targetID; int amount; };
struct EntityDiedPayload    { uint32_t entityID; };
struct HitContactPayload    { uint32_t attackerID; uint32_t targetID; };
struct AttackStartedPayload { uint32_t entityID; uint8_t clipID; }; // clipID = (uint8_t)AnimClipID
struct DodgeStartedPayload  { uint32_t entityID; };
struct BossTelegraphPayload { uint32_t entityID; };

// One slot in the ring buffer.
struct Event {
    EventType type;
    union {
        DamageDealtPayload   damageDealt;
        EntityDiedPayload    entityDied;
        HitContactPayload    hitContact;
        AttackStartedPayload attackStarted;
        DodgeStartedPayload  dodgeStarted;
        BossTelegraphPayload bossTelegraph;
    };
};

// 256-slot single-frame ring buffer. Zero heap allocation.
// Overflow policy: assert in debug, silent drop + increment counter in release.
// Cleared at the start of each frame by World::tick().
struct EventBus {
    static constexpr int kCapacity = 256;

    Event    slots[kCapacity];
    int      count       = 0;
    uint32_t dropCount   = 0; // incremented on overflow in release

    void clear() { count = 0; }

    void push(const Event& e) {
        if (count >= kCapacity) {
#ifdef NDEBUG
            ++dropCount;
            return;
#else
            assert(false && "EventBus overflow — increase kCapacity or flush more often");
#endif
        }
        slots[count++] = e;
    }

    // Convenience emitters
    void emit_damage(uint32_t targetID, int amount) {
        Event e{}; e.type = EventType::DamageDealt;
        e.damageDealt = { targetID, amount };
        push(e);
    }
    void emit_died(uint32_t entityID) {
        Event e{}; e.type = EventType::EntityDied;
        e.entityDied = { entityID };
        push(e);
    }
    void emit_hit_contact(uint32_t attackerID, uint32_t targetID) {
        Event e{}; e.type = EventType::HitContact;
        e.hitContact = { attackerID, targetID };
        push(e);
    }
    void emit_attack_started(uint32_t entityID, uint8_t clipID) {
        Event e{}; e.type = EventType::AttackStarted;
        e.attackStarted = { entityID, clipID };
        push(e);
    }
    void emit_dodge_started(uint32_t entityID) {
        Event e{}; e.type = EventType::DodgeStarted;
        e.dodgeStarted = { entityID };
        push(e);
    }
    void emit_boss_telegraph(uint32_t entityID) {
        Event e{}; e.type = EventType::BossTelegraph;
        e.bossTelegraph = { entityID };
        push(e);
    }

    // Iterate all events of a given type.
    template<typename Fn>
    void for_each(EventType type, Fn fn) const {
        for (int i = 0; i < count; ++i)
            if (slots[i].type == type) fn(slots[i]);
    }
};
