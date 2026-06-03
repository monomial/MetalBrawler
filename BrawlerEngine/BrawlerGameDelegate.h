#pragma once
#import <MetalKit/MetalKit.h>
#include "Platform/InputState.h"

// Shared game delegate used by all three platform targets (macOS, iOS, tvOS).
// Owns the World, renderer, audio, haptics, character loading, and game loop.
// Platform GameViewControllers are thin wrappers that translate input and
// call setInputState: / triggerAttack:.
@interface BrawlerGameDelegate : NSObject <MTKViewDelegate>

- (instancetype)initWithDevice:(id<MTLDevice>)device pixelFormat:(MTLPixelFormat)pfmt;

// Set the full input state for a specific player (0 = P1, 1 = P2, …).
- (void)setInputState:(InputState)state forPlayer:(int)playerIndex;

// Read back the current state for a player (used by controller handlers that
// update only one field at a time, e.g. thumbstick without touching attack).
- (InputState)currentInputStateForPlayer:(int)playerIndex;

// Convenience shorthands for single-player / P1-only callers.
- (void)setInputState:(InputState)state;
- (InputState)currentInputState;

// Fire a one-frame attack pulse (touch tap, single press). Does not affect
// held-button platforms — those set attack via setInputState: directly.
- (void)triggerAttack;

// Zero all input — call when the app goes to background so held inputs
// don't stay active on resume.
- (void)resetInput;

@end
