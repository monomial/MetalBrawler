#import <XCTest/XCTest.h>
#import "BrawlerGameDelegate.h"
#include "Simulation/AutoPilot.h"

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

static void pickLowEffortPerk(BrawlerGameDelegate *d) {
    NSString *a = [d upgradeChoiceLabel:0];
    NSString *b = [d upgradeChoiceLabel:1];
    bool aPriority = [a containsString:@"Damage"] || [a containsString:@"Health"];
    bool bPriority = [b containsString:@"Damage"] || [b containsString:@"Health"];
    if (aPriority && !bPriority) [d triggerDodge];
    else                         [d triggerAttack];
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

static BOOL advanceLowEffortUntilPhase(BrawlerGameDelegate *d, BrawlerGamePhase phase,
                                       float maxSimSeconds) {
    int maxFrames = (int)(maxSimSeconds / kFrameDt);
    for (int i = 0; i < maxFrames; ++i) {
        if (d.gamePhase == phase) return YES;
        if (d.gamePhase == BrawlerGamePhaseUpgrade && phase != BrawlerGamePhaseUpgrade)
            pickLowEffortPerk(d);
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

static BOOL advanceUntilRoom(BrawlerGameDelegate *d, int room, float maxSimSeconds) {
    int maxFrames = (int)(maxSimSeconds / kFrameDt);
    for (int i = 0; i < maxFrames; ++i) {
        if (d.currentRoom == room && d.gamePhase == BrawlerGamePhasePlaying) return YES;
        if (d.gamePhase == BrawlerGamePhaseUpgrade)
            pickPerk(d);
        [d advanceFrame:kFrameDt];
    }
    return d.currentRoom == room && d.gamePhase == BrawlerGamePhasePlaying;
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
    AutoPilot_set_dodge_enabled(true);
    BrawlerGameDelegate *d = [self makeDelegateWithSeed:42];
    d.autoPilotEnabled = YES;

    NSMutableArray<NSNumber *> *phases = [NSMutableArray array];
    d.onPhaseChanged = ^(BrawlerGamePhase phase, int room, int lives) {
        [phases addObject:@(phase)];
    };

    [d startGameWithPlayers:1];
    XCTAssertEqual(d.gamePhase, BrawlerGamePhasePlaying);
    XCTAssertEqual(d.currentRoom, 1);

    BOOL won = advanceUntilPhase(d, BrawlerGamePhaseWin, 510.f);
    XCTAssertTrue(won, @"AutoPilot failed to clear all rooms within 510 sim-seconds (ended in phase %ld, room %d, lives %d)",
                  (long)d.gamePhase, d.currentRoom, d.livesRemaining);
    XCTAssertEqual(d.currentRoom, 8, @"a full run is intro + 4 middle rooms + shop + boss + twin boss");

    // Every room fires RoomClear; every non-final clear offers an upgrade.
    NSInteger clears = 0, upgrades = 0;
    for (NSNumber *p in phases) {
        if (p.integerValue == BrawlerGamePhaseRoomClear) clears++;
        if (p.integerValue == BrawlerGamePhaseUpgrade)   upgrades++;
    }
    XCTAssertGreaterThanOrEqual(clears,   (NSInteger)6);
    XCTAssertGreaterThanOrEqual(upgrades, (NSInteger)5);
}

- (void)test_autoPilot_2P_winsFullRun {
    AutoPilot_set_dodge_enabled(true);
    BrawlerGameDelegate *d = [self makeDelegateWithSeed:1337];
    d.autoPilotEnabled = YES;

    [d startGameWithPlayers:2];
    XCTAssertEqual(d.gamePhase, BrawlerGamePhasePlaying);

    BOOL won = advanceUntilPhase(d, BrawlerGamePhaseWin, 510.f);
    XCTAssertTrue(won, @"2P AutoPilot failed to win (phase %ld, room %d, lives %d)",
                  (long)d.gamePhase, d.currentRoom, d.livesRemaining);
    XCTAssertEqual(d.currentRoom, 8);
}

- (void)test_autoPilot_noDodgeRunFailsToWin {
    uint32_t seeds[] = {42, 7, 1337, 2026, 9001};
    for (uint32_t seed : seeds) {
        AutoPilot_set_dodge_enabled(true);
        BrawlerGameDelegate *dodging = [self makeDelegateWithSeed:seed];
        dodging.autoPilotEnabled = YES;
        [dodging startGameWithPlayers:1];
        BOOL dodgingWon = advanceUntilPhase(dodging, BrawlerGamePhaseWin, 510.f);
        if (!dodgingWon) continue;

        AutoPilot_set_dodge_enabled(false);
        BrawlerGameDelegate *noDodge = [self makeDelegateWithSeed:seed];
        noDodge.autoPilotEnabled = YES;
        [noDodge startGameWithPlayers:1];
        BOOL noDodgeWon = advanceLowEffortUntilPhase(noDodge, BrawlerGamePhaseWin, 510.f);
        AutoPilot_set_dodge_enabled(true);

        if (!noDodgeWon) return;
    }
    AutoPilot_set_dodge_enabled(true);
    XCTFail(@"no-dodge AutoPilot won every checked seed where dodging AutoPilot won");
}

- (void)test_singleBossRoomOffersUpgradeAndWinWaitsForTwinBoss {
    BrawlerGameDelegate *d = [self makeDelegateWithSeed:42];
    d.autoPilotEnabled = YES;

    [d startGameWithPlayers:1];
    XCTAssertTrue(advanceUntilRoom(d, 7, 360.f), @"AutoPilot must reach the single-boss room");
    XCTAssertEqual(d.gamePhase, BrawlerGamePhasePlaying);

    XCTAssertTrue(advanceUntilPhase(d, BrawlerGamePhaseUpgrade, 120.f),
                  @"single-boss room should clear into an upgrade instead of Win");
    XCTAssertEqual(d.currentRoom, 7);
    XCTAssertNotEqual(d.gamePhase, BrawlerGamePhaseWin);

    pickPerk(d);
    [d advanceFrame:kFrameDt];
    XCTAssertTrue(advanceUntilRoom(d, 8, 30.f), @"exit after single-boss upgrade should load twin-boss room");
    XCTAssertEqual(d.gamePhase, BrawlerGamePhasePlaying);
}

// --- Lose path --------------------------------------------------------------

- (void)test_idlePlayer_losesAllLivesThenGameOver {
    BrawlerGameDelegate *d = [self makeDelegateWithSeed:7];
    // No autopilot: the player stands at spawn until the enemies beat them down.

    [d startGameWithPlayers:1];
    XCTAssertEqual(d.livesRemaining, 3);

    BOOL lost = advanceUntilPhase(d, BrawlerGamePhaseLose, 300.f);
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
    XCTAssertEqual(d.currentRoom, 1, @"choice returns to the cleared room");
    XCTAssertEqual([d exitEntityCount], 1, @"last choice spawns the exit portal");

    BOOL advanced = advanceUntilRoom(d, 2, 20.f);
    XCTAssertTrue(advanced, @"AutoPilot must walk through the exit before room advances");
    XCTAssertEqual([d exitEntityCount], 0);
}

- (void)test_twoPlayers_eachGetsOwnUpgradeChoiceBeforeNextRoom {
    BrawlerGameDelegate *d = [self makeDelegateWithSeed:1337];
    d.autoPilotEnabled = YES;

    [d startGameWithPlayers:2];
    BOOL reached = advanceUntilPhase(d, BrawlerGamePhaseUpgrade, 120.f);
    XCTAssertTrue(reached, @"room clear must lead to P1 upgrade");
    XCTAssertEqual(d.currentRoom, 1);
    XCTAssertEqual([d currentUpgradePlayerIndex], 0);

    NSString *p1A = [d upgradeChoiceLabel:0];
    NSString *p1B = [d upgradeChoiceLabel:1];
    XCTAssertNotEqualObjects(p1A, @"");
    XCTAssertNotEqualObjects(p1B, @"");

    [d chooseUpgrade:0];
    XCTAssertEqual(d.gamePhase, BrawlerGamePhaseUpgrade,
                   @"P1 choice should hand upgrade selection to P2, not advance the room");
    XCTAssertEqual(d.currentRoom, 1);
    XCTAssertEqual([d currentUpgradePlayerIndex], 1);
    XCTAssertNotEqualObjects([d upgradeChoiceLabel:0], @"");
    XCTAssertNotEqualObjects([d upgradeChoiceLabel:1], @"");

    [d chooseUpgrade:1];
    XCTAssertEqual(d.gamePhase, BrawlerGamePhasePlaying);
    XCTAssertEqual(d.currentRoom, 1, @"next room waits until a player reaches the exit");
    XCTAssertEqual([d exitEntityCount], 1);

    BOOL advanced = advanceUntilRoom(d, 2, 20.f);
    XCTAssertTrue(advanced, @"AutoPilot must walk through the exit after both choices");
}

- (void)test_fourPlayers_getFourSequentialUpgradeTurns {
    BrawlerGameDelegate *d = [self makeDelegateWithSeed:2026];
    d.autoPilotEnabled = YES;

    [d startGameWithPlayers:4];
    BOOL reached = advanceUntilPhase(d, BrawlerGamePhaseUpgrade, 120.f);
    XCTAssertTrue(reached, @"4P room clear must lead to upgrade phase");

    for (int p = 0; p < 4; ++p) {
        XCTAssertEqual(d.gamePhase, BrawlerGamePhaseUpgrade);
        XCTAssertEqual([d currentUpgradePlayerIndex], p);
        [d chooseUpgrade:p % 2];
    }

    XCTAssertEqual(d.gamePhase, BrawlerGamePhasePlaying);
    XCTAssertEqual(d.currentRoom, 1);
    XCTAssertEqual([d exitEntityCount], 1);
    XCTAssertTrue(advanceUntilRoom(d, 2, 20.f));
}

- (void)test_upgradeOffers_areDeterministicAndDistinct {
    BrawlerGameDelegate *a = [self makeDelegateWithSeed:4242];
    BrawlerGameDelegate *b = [self makeDelegateWithSeed:4242];
    a.autoPilotEnabled = YES;
    b.autoPilotEnabled = YES;
    [a startGameWithPlayers:1];
    [b startGameWithPlayers:1];
    XCTAssertTrue(advanceUntilPhase(a, BrawlerGamePhaseUpgrade, 120.f));
    XCTAssertTrue(advanceUntilPhase(b, BrawlerGamePhaseUpgrade, 120.f));

    XCTAssertNotEqualObjects([a upgradeChoiceLabel:0], [a upgradeChoiceLabel:1]);
    XCTAssertEqualObjects([a upgradeChoiceLabel:0], [b upgradeChoiceLabel:0]);
    XCTAssertEqualObjects([a upgradeChoiceLabel:1], [b upgradeChoiceLabel:1]);
}

- (void)test_shopPedestals_haveDistinctPerks {
    BrawlerGameDelegate *d = [self makeDelegateWithSeed:42];
    d.autoPilotEnabled = YES;
    [d startGameWithPlayers:1];

    XCTAssertTrue(advanceUntilRoom(d, 4, 240.f), @"AutoPilot must reach the shop room");
    XCTAssertEqual([d shopItemEntityCount], 3);
    XCTAssertTrue([d debugShopItemsHaveDistinctPerks]);
}

- (void)test_applyPerk_setsNewRareAndEpicFields {
    BrawlerGameDelegate *d = [self makeDelegateWithSeed:1];
    [d debugApplyPerkID:8 toPlayer:0];  // Heavy Hitter
    [d debugApplyPerkID:9 toPlayer:0];  // Toughness
    [d debugApplyPerkID:10 toPlayer:0]; // Lifesteal
    [d debugApplyPerkID:11 toPlayer:0]; // Thorns
    [d debugApplyPerkID:12 toPlayer:0]; // Whirlwind
    [d debugApplyPerkID:13 toPlayer:0]; // Adrenaline

    XCTAssertEqual([d debugPerkDamageBonusForPlayer:0], 1);
    XCTAssertEqual([d debugPerkMaxHPBonusForPlayer:0], 4);
    XCTAssertEqual([d debugPerkLifestealForPlayer:0], 10);
    XCTAssertTrue([d debugPerkThornsForPlayer:0]);
    XCTAssertTrue([d debugPerkWhirlwindForPlayer:0]);
    XCTAssertTrue([d debugPerkPassiveSpecialForPlayer:0]);

    [d debugApplyPerkID:14 toPlayer:0]; // Vampire
    XCTAssertEqual([d debugPerkDamageBonusForPlayer:0], 1);
    XCTAssertEqual([d debugPerkLifestealForPlayer:0], 6);
}

- (void)test_comboScore_incrementsResetsExpiresAndTracksMax {
    BrawlerGameDelegate *d = [self makeDelegateWithSeed:1];
    [d debugRegisterEnemyDamage:1];
    [d debugRegisterEnemyDamage:1];
    [d debugRegisterEnemyDamage:1];

    XCTAssertEqual([d comboCount], 3);
    XCTAssertEqual([d maxCombo], 3);
    XCTAssertEqual([d scoreValue], 60);

    [d debugRegisterPlayerDamage:1];
    XCTAssertEqual([d comboCount], 0);
    XCTAssertEqual([d maxCombo], 3);

    [d debugRegisterEnemyDamage:1];
    [d debugAdvanceComboTimer:2.6f];
    XCTAssertEqual([d comboCount], 0);
}

- (void)test_comboScore_resetsOnNewRun {
    BrawlerGameDelegate *d = [self makeDelegateWithSeed:1];
    [d debugRegisterEnemyDamage:1];
    XCTAssertGreaterThan([d scoreValue], 0);

    [d startGameWithPlayers:1];

    XCTAssertEqual([d comboCount], 0);
    XCTAssertEqual([d maxCombo], 0);
    XCTAssertEqual([d scoreValue], 0);
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
