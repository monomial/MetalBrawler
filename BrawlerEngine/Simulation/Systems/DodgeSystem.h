#pragma once
#include "Simulation/World.h"

// Manages the dodge-roll mechanic for player entities.
//
// Lifecycle:
//   - InputSystem requests AnimClipID::Dodge when the player presses dodge.
//   - DodgeSystem detects when the Dodge clip actually starts playing (after any
//     non-interruptible clip finishes) and at that moment:
//       1. Adds DodgeComponent → entity becomes invincible (CombatSystem checks this).
//       2. Applies a one-shot velocity burst in the current facing direction.
//   - DodgeComponent is removed when the Dodge clip completes.
//
// Execution order: runs after AnimationSystem so clipDone is up-to-date.

void DodgeSystem_update(World& world, float gameDt);
