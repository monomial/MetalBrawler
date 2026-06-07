#pragma once
#import <MetalKit/MetalKit.h>
#include "Platform/InputState.h"

typedef NS_ENUM(NSInteger, BrawlerGamePhase) {
    BrawlerGamePhaseTitle        = 0, // title screen — waiting for any button
    BrawlerGamePhasePlayerSelect = 1, // 1 or 2 players?
    BrawlerGamePhasePlaying      = 2, // active combat
    BrawlerGamePhaseRoomClear    = 3, // brief pause between rooms
    BrawlerGamePhaseWin          = 4, // all rooms beaten
    BrawlerGamePhaseLose         = 5, // all lives exhausted
    BrawlerGamePhasePaused       = 6, // mid-game pause
};

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

// Fire a one-frame dodge pulse (touch flick, single press). Same pattern as triggerAttack.
- (void)triggerDodge;

// Fire a one-frame pause/resume pulse.
- (void)triggerPause;

// Start the game with a specific player count. Call from the player-select UI.
- (void)startGameWithPlayers:(int)playerCount;

// Zero all input — call when the app goes to background so held inputs
// don't stay active on resume.
- (void)resetInput;

// Read-only game state for platform UIs (overlay labels, HUD).
@property (readonly, nonatomic) BrawlerGamePhase gamePhase;
@property (readonly, nonatomic) int currentRoom;    // 1-indexed (1–4)
@property (readonly, nonatomic) int livesRemaining; // 0–3

// Called on the main thread each time the phase transitions.
// room and lives reflect the NEW state after the transition.
@property (copy, nonatomic) void (^onPhaseChanged)(BrawlerGamePhase phase, int room, int lives);

// Called when the player takes damage (survives). Use for screen-flash feedback.
@property (copy, nonatomic) void (^onPlayerDamaged)(void);

@end
