#include "World.h"
#include <cassert>

// _pool<T>() specializations — each returns the matching storage member.
// To add a new component type: add the member to World.h, then add a line here.
template<> ComponentStorage<PositionComponent>& World::_pool() { return _positions; }
template<> ComponentStorage<VelocityComponent>& World::_pool() { return _velocities; }
template<> ComponentStorage<HealthComponent>&   World::_pool() { return _healths; }
template<> ComponentStorage<FactionComponent>&  World::_pool() { return _factions; }

// ----

World::World()
    : _nextID(0)
    , _deferredDestroyCount(0)
{}

World::~World() {}

EntityID World::defer_create() {
    return _nextID++;
}

void World::defer_destroy(EntityID id) {
    assert(_deferredDestroyCount < 256 && "deferred destroy buffer overflow — increase limit or flush more often");
    _deferredDestroy[_deferredDestroyCount++] = id;
}

void World::flush() {
    for (uint32_t i = 0; i < _deferredDestroyCount; ++i) {
        EntityID id = _deferredDestroy[i];
        _positions.remove(id);
        _velocities.remove(id);
        _healths.remove(id);
        _factions.remove(id);
    }
    _deferredDestroyCount = 0;
}

void World::update(float physicalDt, float gameDt) {
    // Frame execution order (see docs/ecs-vocabulary.md):
    //  1. InputSystem       (physicalDt) — read InputState, write velocity/intent
    //  2. PhysicsSystem     (gameDt)     — integrate velocity into position
    //  3. CombatSystem      (gameDt)     — hitboxes, damage events, death events
    //  4. HitStopSystem     (physical)   — scale gameDt to 0 for N frames on hit
    //  5. AnimationSystem   (gameDt)     — bone matrices (already scaled)
    //  6. AudioSystem       (physicalDt) — sound triggers (never freezes)
    //  7. HapticsSystem     (physicalDt) — CHHapticEngine patterns
    //  8. ScreenShakeSystem (physicalDt) — camera offset exponential decay
    //  9. flush             —             deferred create/destroy
    // 10. RenderSystem      (physicalDt) — mesh draw, present

    (void)physicalDt;
    (void)gameDt;
    flush();
}
