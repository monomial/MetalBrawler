#pragma once
#include <stdint.h>

using EntityID = uint32_t;
static constexpr EntityID kInvalidEntity = UINT32_MAX;

// Hand-rolled ECS world. Owns entity IDs, component storage, and system execution.
// Systems call World.update(physicalDt, gameDt) once per frame.
//   physicalDt — wall-clock time; audio, haptics, screen shake, render always use this.
//   gameDt     — scaled game time; HitStopSystem sets to 0 to freeze gameplay.
class World {
public:
    World();
    ~World();

    void update(float physicalDt, float gameDt);

    // Deferred lifecycle — buffered until flush() at end of frame.
    EntityID defer_create();
    void     defer_destroy(EntityID id);

private:
    void flush();

    uint32_t _nextID;
    uint32_t _deferredDestroyCount;
    EntityID _deferredDestroy[256];
};
