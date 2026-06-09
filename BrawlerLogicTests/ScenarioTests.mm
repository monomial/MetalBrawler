#import <XCTest/XCTest.h>
#import "BrawlerGameDelegate.h"

// Full-game integration tests: a headless BrawlerGameDelegate driven at a
// fixed 60Hz frame rate, with AutoPilot standing in for human input. These are
// the regression gate for gameplay changes — if the bot can no longer fight
// through a run, something load-bearing broke.

static const float kFrameDt = 1.0f / 60.0f;

// Bot perk strategy: damage beats health beats anything else — same priority
// a competent player uses. Pulses pick: attack → choice 0, dodge → choice 1.
static void pickPerk(BrawlerGameDelegate *d) {
    NSString *a = [d upgradeChoiceLabel:0];
    NSString *b = [d upgradeChoiceLabel:1];
    if      ([a containsString:@"Damage"]) [d triggerAttack];
    else if ([b containsString:@"Damage"]) [d triggerDodge];
    else if ([a containsString:@"Health"]) [d triggerAttack];
    else if ([b containsString:@"Health"]) [d triggerDodge];
    else                                   [d triggerAttack];
}

// Advance until the delegate reaches `phase` or `maxSimSeconds` of simulated
// time elapses. Returns YES if the phase was reached.
static BOOL advanceUntilPhase(BrawlerGameDelegate *d, BrawlerGamePhase phase,
                              float maxSimSeconds) {
    int maxFrames = (int)(maxSimSeconds / kFrameDt);
    for (int i = 0; i < maxFrames; ++i) {
        if (d.gamePhase == phase) return YES;
        if (d.gamePhase == BrawlerGamePhaseUpgrade && phase != BrawlerGamePhaseUpgrade)
            pickPerk(d);
        [d advanceFrame:kFrameDt];
    }
    return d.gamePhase == phase;
}

static void advanceSeconds(BrawlerGameDelegate *d, float seconds) {
    int frames = (int)(seconds / kFrameDt);
    for (int i = 0; i < frames; ++i) {
        if (d.gamePhase == BrawlerGamePhaseUpgrade)
            pickPerk(d);
        [d advanceFrame:kFrameDt];
    }
}

@interface ScenarioTests : XCTestCase
@end

@implementation ScenarioTests

- (BrawlerGameDelegate *)makeDelegateWithSeed:(uint32_t)seed {
    BrawlerGameDelegate *d = [[BrawlerGameDelegate alloc] initHeadless];
    d.rngSeedOverride = seed;
    return d;
}

// --- Full win run -----------------------------------------------------------

- (void)test_autoPilot_1P_winsFullRun {
    BrawlerGameDelegate *d = [self makeDelegateWithSeed:42];
    d.autoPilotEnabled = YES;

    NSMutableArray<NSNumber *> *phases = [NSMutableArray array];
    d.onPhaseChanged = ^(BrawlerGamePhase phase, int room, int lives) {
        [phases addObject:@(phase)];
    };

    [d startGameWithPlayers:1];
    XCTAssertEqual(d.gamePhase, BrawlerGamePhasePlaying);
    XCTAssertEqual(d.currentRoom, 1);

    BOOL won = advanceUntilPhase(d, BrawlerGamePhaseWin, 240.f);
    XCTAssertTrue(won, @"AutoPilot failed to clear all rooms within 240 sim-seconds (ended in phase %ld, room %d, lives %d)",
                  (long)d.gamePhase, d.currentRoom, d.livesRemaining);
    XCTAssertEqual(d.currentRoom, 6, @"a full run is intro + 4 middle rooms + boss");

    // Every room fires RoomClear; every non-final clear offers an upgrade.
    NSInteger clears = 0, upgrades = 0;
    for (NSNumber *p in phases) {
        if (p.integerValue == BrawlerGamePhaseRoomClear) clears++;
        if (p.integerValue == BrawlerGamePhaseUpgrade)   upgrades++;
    }
    XCTAssertGreaterThanOrEqual(clears,   (NSInteger)5);
    XCTAssertGreaterThanOrEqual(upgrades, (NSInteger)4);
}

- (void)test_autoPilot_2P_winsFullRun {
    BrawlerGameDelegate *d = [self makeDelegateWithSeed:1337];
    d.autoPilotEnabled = YES;

    [d startGameWithPlayers:2];
    XCTAssertEqual(d.gamePhase, BrawlerGamePhasePlaying);

    BOOL won = advanceUntilPhase(d, BrawlerGamePhaseWin, 240.f);
    XCTAssertTrue(won, @"2P AutoPilot failed to win (phase %ld, room %d, lives %d)",
                  (long)d.gamePhase, d.currentRoom, d.livesRemaining);
}

// --- Lose path --------------------------------------------------------------

- (void)test_idlePlayer_losesAllLivesThenGameOver {
    BrawlerGameDelegate *d = [self makeDelegateWithSeed:7];
    // No autopilot: the player stands at spawn until the enemies beat them down.

    [d startGameWithPlayers:1];
    XCTAssertEqual(d.livesRemaining, 3);

    BOOL lost = advanceUntilPhase(d, BrawlerGamePhaseLose, 240.f);
    XCTAssertTrue(lost, @"Idle player never reached the Lose phase (phase %ld, room %d, lives %d)",
                  (long)d.gamePhase, d.currentRoom, d.livesRemaining);
    XCTAssertEqual(d.livesRemaining, 0);

    // Lose screen times out back to the title.
    BOOL backToTitle = advanceUntilPhase(d, BrawlerGamePhaseTitle, 10.f);
    XCTAssertTrue(backToTitle);
}

- (void)test_lifeLoss_reloadsSameRoom {
    BrawlerGameDelegate *d = [self makeDelegateWithSeed:7];

    [d startGameWithPlayers:1];

    // Advance until exactly one life is gone.
    int maxFrames = (int)(120.f / kFrameDt);
    for (int i = 0; i < maxFrames && d.livesRemaining == 3; ++i)
        [d advanceFrame:kFrameDt];

    XCTAssertEqual(d.livesRemaining, 2, @"expected to lose exactly one life");
    XCTAssertEqual(d.currentRoom, 1, @"life loss must reload the same room, not advance");
    XCTAssertEqual(d.gamePhase, BrawlerGamePhasePlaying);
}

// --- Pause ------------------------------------------------------------------

- (void)test_pause_freezesSimulation {
    BrawlerGameDelegate *d = [self makeDelegateWithSeed:7];

    [d startGameWithPlayers:1];
    [d triggerPause];
    [d advanceFrame:kFrameDt];
    XCTAssertEqual(d.gamePhase, BrawlerGamePhasePaused);

    // An idle player would normally be dead well within 60s; paused, nothing
    // can touch them.
    advanceSeconds(d, 60.f);
    XCTAssertEqual(d.gamePhase, BrawlerGamePhasePaused);
    XCTAssertEqual(d.livesRemaining, 3);

    [d triggerPause];
    [d advanceFrame:kFrameDt];
    XCTAssertEqual(d.gamePhase, BrawlerGamePhasePlaying);
}

// --- Title / player-select flow ----------------------------------------------

- (void)test_titleFlow_attackSelectsOnePlayer {
    BrawlerGameDelegate *d = [self makeDelegateWithSeed:7];

    XCTAssertEqual(d.gamePhase, BrawlerGamePhaseTitle);
    [d triggerAttack];
    [d advanceFrame:kFrameDt];
    XCTAssertEqual(d.gamePhase, BrawlerGamePhasePlayerSelect);

    [d triggerAttack];
    [d advanceFrame:kFrameDt];
    XCTAssertEqual(d.gamePhase, BrawlerGamePhasePlaying);
    XCTAssertEqual(d.currentRoom, 1);
    XCTAssertEqual(d.livesRemaining, 3);
}

// --- Perks -------------------------------------------------------------------

- (void)test_upgradePhase_freezesSimAndAppliesChoice {
    BrawlerGameDelegate *d = [self makeDelegateWithSeed:42];
    d.autoPilotEnabled = YES;

    [d startGameWithPlayers:1];
    BOOL reached = NO;
    int maxFrames = (int)(120.f / kFrameDt);
    for (int i = 0; i < maxFrames; ++i) {
        if (d.gamePhase == BrawlerGamePhaseUpgrade) { reached = YES; break; }
        [d advanceFrame:kFrameDt];
    }
    XCTAssertTrue(reached, @"room 1 clear must lead to an upgrade choice");
    XCTAssertEqual(d.currentRoom, 1, @"still on room 1 while choosing");
    XCTAssertNotEqualObjects([d upgradeChoiceLabel:0], @"");
    XCTAssertNotEqualObjects([d upgradeChoiceLabel:1], @"");

    // Sitting on the choice screen must not let enemies act (sim frozen).
    for (int i = 0; i < 600; ++i) [d advanceFrame:kFrameDt];
    XCTAssertEqual(d.gamePhase, BrawlerGamePhaseUpgrade);
    XCTAssertEqual(d.livesRemaining, 3);

    [d chooseUpgrade:0];
    XCTAssertEqual(d.gamePhase, BrawlerGamePhasePlaying);
    XCTAssertEqual(d.currentRoom, 2, @"choice advances to the next room");
}

// --- Determinism -------------------------------------------------------------

- (void)test_sameSeed_identicalPhaseTranscript {
    // Two runs with the same seed and the same (bot) inputs must produce the
    // same sequence of phase transitions with the same room/lives at each.
    NSMutableArray<NSString *> *a = [NSMutableArray array];
    NSMutableArray<NSString *> *b = [NSMutableArray array];

    for (NSMutableArray<NSString *> *transcript in @[a, b]) {
        BrawlerGameDelegate *d = [self makeDelegateWithSeed:9001];
        d.autoPilotEnabled = YES;
        d.onPhaseChanged = ^(BrawlerGamePhase phase, int room, int lives) {
            [transcript addObject:[NSString stringWithFormat:@"%ld/%d/%d",
                                   (long)phase, room, lives]];
        };
        [d startGameWithPlayers:1];
        advanceSeconds(d, 90.f);
    }

    XCTAssertGreaterThan(a.count, (NSUInteger)1, @"expected at least some phase transitions");
    XCTAssertEqualObjects(a, b, @"identical seeds must replay identically");
}

@end
