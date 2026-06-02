#pragma once

// Single hard-coded room for first ship.
// These are the authoritative world-space boundaries used by
// WallCollisionSystem, WallBounceSystem (future), and BrawlerRenderer.
// V1: one room, fixed camera. Multi-room support deferred post-first-ship.

static constexpr float kRoomMinX   = -500.f;
static constexpr float kRoomMaxX   =  500.f;
static constexpr float kRoomMinY   = -250.f;
static constexpr float kRoomMaxY   =  650.f;

static constexpr float kRoomWidth  = kRoomMaxX - kRoomMinX; // 1000
static constexpr float kRoomHeight = kRoomMaxY - kRoomMinY; // 900
static constexpr float kRoomCenterX = (kRoomMinX + kRoomMaxX) * 0.5f; //   0
static constexpr float kRoomCenterY = (kRoomMinY + kRoomMaxY) * 0.5f; // 200

// Camera looks at this point when no player exists and for clamping reference.
static constexpr float kCameraDefaultTargetX = kRoomCenterX;
static constexpr float kCameraDefaultTargetY = kRoomCenterY;
