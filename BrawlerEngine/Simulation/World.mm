#include "World.h"
#include <cassert>

World::World()
    : _nextID(0)
    , _deferredDestroyCount(0)
{}

World::~World() {}

EntityID World::defer_create() {
    return _nextID++;
}

void World::defer_destroy(EntityID id) {
    assert(_deferredDestroyCount < 256 && "deferred destroy buffer overflow");
    _deferredDestroy[_deferredDestroyCount++] = id;
}

void World::flush() {
    // TODO: reclaim component slots for destroyed entities
    _deferredDestroyCount = 0;
}

void World::update(float physicalDt, float gameDt) {
    // Frame execution order (see docs/ecs-vocabulary.md):
    //  1. InputSystem      (physicalDt)
    //  2. PhysicsSystem    (gameDt)
    //  3. CombatSystem     (gameDt)
    //  4. HitStopSystem    (sets gameDt scale)
    //  5. AnimationSystem  (gameDt — already scaled)
    //  6. AudioSystem      (physicalDt)
    //  7. HapticsSystem    (physicalDt)
    //  8. ScreenShakeSystem(physicalDt)
    //  9. flush            (deferred create/destroy)
    // 10. RenderSystem     (physicalDt)

    (void)physicalDt;
    (void)gameDt;
    flush();
}
