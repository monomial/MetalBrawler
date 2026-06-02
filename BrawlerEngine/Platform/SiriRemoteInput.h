#pragma once
#include "InputState.h"

// Converts raw Siri Remote swipe delta (as delivered by GCController panInput)
// into a normalized InputState.moveX/moveY.
//
// Raw delta is in arbitrary units with no dead-zone. Without processing:
//   - Tiny accidental touches register as movement
//   - Fast swipes saturate immediately with no speed gradation
//
// Processing:
//   1. Dead-zone: ignore deltas below kDeadZone (eliminates resting drift)
//   2. Remap: rescale [kDeadZone, kMaxRaw] → [0, 1]
//   3. Acceleration curve: apply square to give fine control near center
//   4. Normalize: clamp to unit circle so diagonal isn't faster than cardinal

InputState SiriRemote_processSwipeDelta(float rawX, float rawY);
