#import <XCTest/XCTest.h>
#import "BrawlerGameDelegate.h"
#import "MetaProgressStore.h"
#include "Simulation/World.h"
#include "Simulation/Systems/CombatHelpers.h"
#include "Simulation/Systems/ShopSystem.h"

static constexpr float kFixedDt = 1.0f / 120.0f;
static constexpr float kFrameDt = 1.0f / 60.0f;

static EntityID spawnPlayer(World& world, float x = 0, float y = 0,
                            float facingDx = 1.f, float facingDy = 0.f) {
    EntityID e = world.defer_create();
    world.add_component<PlayerTagComponent>(e) = {true, 0};
    world.add_component<PositionComponent>(e) = {x, y, 0.f};
    world.add_component<VelocityComponent>(e) = {0.f, 0.f, 0.f};
    world.add_component<FactionComponent>(e).type = FactionComponent::Player;
    world.add_component<HealthComponent>(e) = {10, 10};
    world.add_component<FacingComponent>(e) = {facingDx, facingDy};
    world.add_component<AnimationComponent>(e);
    return e;
}

static EntityID spawnScrap(World& world, float x, float y, int value = 2) {
    EntityID e = world.defer_create();
    world.add_component<PositionComponent>(e) = {x, y, 0.f};
    world.add_component<ScrapPickupComponent>(e).value = value;
    return e;
}

static EntityID spawnBox(World& world, float x, float y, bool hasScrap) {
    EntityID e = world.defer_create();
    world.add_component<PositionComponent>(e) = {x, y, 0.f};
    world.add_component<BoxComponent>(e).hasScrap = hasScrap;
    return e;
}

static EntityID spawnEnemy(World& world, float x, float y) {
    EntityID e = world.defer_create();
    world.add_component<PositionComponent>(e) = {x, y, 0.f};
    world.add_component<FactionComponent>(e).type = FactionComponent::Enemy;
    world.add_component<HealthComponent>(e) = {1, 1};
    return e;
}

static void setPlayerAttacking(World& world, EntityID player) {
    AnimationComponent& anim = world.get_component<AnimationComponent>(player);
    anim.currentClip = AnimClipID::Attack;
    anim.requestedClip = AnimClipID::Attack;
    anim.clipTime = 1.03f * 0.475f;
    anim.looping = false;
    anim.hitApplied = false;
}

static int scrapPickupCount(World& world) {
    int count = 0;
    for (EntityID id = 0; id < world.entity_count(); ++id)
        if (world.scrap_pickups().present(id)) ++count;
    return count;
}

static int eventCount(World& world, EventType type) {
    int count = 0;
    world.events().for_each(type, [&count](const Event&) { ++count; });
    return count;
}

static void chooseUpgradesIfNeeded(BrawlerGameDelegate *d) {
    if (d.gamePhase != BrawlerGamePhaseUpgrade) return;
    NSString *a = [d upgradeChoiceLabel:0];
    NSString *b = [d upgradeChoiceLabel:1];
    if      ([a containsString:@"Damage"]) [d triggerAttack];
    else if ([b containsString:@"Damage"]) [d triggerDodge];
    else if ([a containsString:@"Health"]) [d triggerAttack];
    else if ([b containsString:@"Health"]) [d triggerDodge];
    else                                   [d triggerAttack];
}

static BOOL advanceDelegateUntilPhase(BrawlerGameDelegate *d, BrawlerGamePhase phase, float seconds) {
    int maxFrames = (int)(seconds / kFrameDt);
    for (int i = 0; i < maxFrames; ++i) {
        if (d.gamePhase == phase) return YES;
        chooseUpgradesIfNeeded(d);
        [d advanceFrame:kFrameDt];
    }
    return d.gamePhase == phase;
}

@interface Part2EconomyShopTests : XCTestCase
@end

@implementation Part2EconomyShopTests

- (void)test_scrapPickupMagnetizesCollectsValueAndExpires {
    World world;
    spawnPlayer(world, 0, 0);
    EntityID scrap = spawnScrap(world, 100, 0, 7);

    world.update(kFixedDt, kFixedDt);
    XCTAssertLessThan(world.get_component<PositionComponent>(scrap).x, 100.f);
    XCTAssertTrue(world.has_component<ScrapPickupComponent>(scrap));

    world.get_component<PositionComponent>(scrap) = {39.f, 0.f, 0.f};
    world.update(kFixedDt, kFixedDt);
    int seen = 0;
    world.events().for_each(EventType::ScrapCollected, [&seen](const Event& ev) {
        ++seen;
        XCTAssertEqual(ev.scrapCollected.value, 7);
    });
    XCTAssertEqual(seen, 1);
    XCTAssertFalse(world.has_component<ScrapPickupComponent>(scrap));

    EntityID expiring = spawnScrap(world, 500, 0, 2);
    for (int i = 0; i < 1441; ++i) world.update(kFixedDt, kFixedDt);
    XCTAssertFalse(world.has_component<ScrapPickupComponent>(expiring));
}

- (void)test_boxesBreakByMeleeAndContactWithPayloadAndScrapCounts {
    World meleeWorld;
    EntityID player = spawnPlayer(meleeWorld, 0, 0, 1.f, 0.f);
    setPlayerAttacking(meleeWorld, player);
    EntityID scrapBox = spawnBox(meleeWorld, 80, 0, true);

    meleeWorld.update(kFixedDt, kFixedDt);
    XCTAssertFalse(meleeWorld.has_component<BoxComponent>(scrapBox));
    XCTAssertEqual(scrapPickupCount(meleeWorld), 3);
    int boxEvents = 0;
    meleeWorld.events().for_each(EventType::BoxBroken, [&boxEvents](const Event& ev) {
        ++boxEvents;
        XCTAssertEqual(ev.boxBroken.hadScrap, 1);
        XCTAssertEqualWithAccuracy(ev.boxBroken.x, 80.f, 0.001f);
    });
    XCTAssertEqual(boxEvents, 1);

    World contactWorld;
    spawnPlayer(contactWorld, 0, 0);
    EntityID emptyBox = spawnBox(contactWorld, 44, 0, false);
    contactWorld.update(kFixedDt, kFixedDt);
    XCTAssertFalse(contactWorld.has_component<BoxComponent>(emptyBox));
    XCTAssertEqual(scrapPickupCount(contactWorld), 0);
    contactWorld.events().for_each(EventType::BoxBroken, [](const Event& ev) {
        XCTAssertEqual(ev.boxBroken.hadScrap, 0);
    });
}

- (void)test_enemyDeathScrapDropIsDeterministicForFixedSeed {
    auto killAndCount = [](uint32_t seed) {
        World world;
        world.set_seed(seed);
        EntityID enemy = spawnEnemy(world, 0, 0);
        Combat_apply_death(world, enemy);
        world.update(kFixedDt, kFixedDt);
        return scrapPickupCount(world);
    };

    XCTAssertEqual(killAndCount(1), killAndCount(1));
    XCTAssertEqual(killAndCount(4096), killAndCount(4096));
    XCTAssertNotEqual(killAndCount(1), killAndCount(4096));
}

- (void)test_shopSystemPurchasesDeductDestroyEmitAndNoOverspend {
    World world;
    EntityID player = spawnPlayer(world, 0, 0);
    (void)player;
    EntityID item = world.defer_create();
    world.add_component<PositionComponent>(item) = {50.f, 0.f, 0.f};
    world.add_component<ShopItemComponent>(item) = {2, 25, {false, false, false, false}};
    world.set_scrap(30);
    world.set_input({0, 0, true, false, false});

    ShopSystem_update(world, kFixedDt);
    XCTAssertEqual(world.scrap(), 5);
    XCTAssertEqual(eventCount(world, EventType::ShopPurchase), 1);
    world.update(kFixedDt, kFixedDt);
    XCTAssertFalse(world.has_component<ShopItemComponent>(item));

    World poorWorld;
    spawnPlayer(poorWorld, 0, 0);
    EntityID expensive = poorWorld.defer_create();
    poorWorld.add_component<PositionComponent>(expensive) = {40.f, 0.f, 0.f};
    poorWorld.add_component<ShopItemComponent>(expensive) = {1, 25, {false, false, false, false}};
    poorWorld.set_scrap(24);
    poorWorld.set_input({0, 0, true, false, false});
    ShopSystem_update(poorWorld, kFixedDt);
    XCTAssertEqual(poorWorld.scrap(), 24);
    XCTAssertEqual(eventCount(poorWorld, EventType::ShopPurchase), 0);
    XCTAssertTrue(poorWorld.has_component<ShopItemComponent>(expensive));

    World twoItems;
    spawnPlayer(twoItems, 0, 0);
    for (int i = 0; i < 2; ++i) {
        EntityID e = twoItems.defer_create();
        twoItems.add_component<PositionComponent>(e) = {(float)(40 + i * 10), 0.f, 0.f};
        twoItems.add_component<ShopItemComponent>(e) = {(uint8_t)i, 25, {false, false, false, false}};
    }
    twoItems.set_scrap(30);
    twoItems.set_input({0, 0, true, false, false});
    ShopSystem_update(twoItems, kFixedDt);
    XCTAssertEqual(twoItems.scrap(), 5);
    XCTAssertEqual(eventCount(twoItems, EventType::ShopPurchase), 1);
}

- (void)test_shopRoomLoadsWithExitShopkeeperItemsAndAdvancesByExit {
    BrawlerGameDelegate *d = [[BrawlerGameDelegate alloc] initHeadless];
    d.rngSeedOverride = 42;
    d.autoPilotEnabled = YES;
    NSMutableArray<NSNumber *> *phases = [NSMutableArray array];
    d.onPhaseChanged = ^(BrawlerGamePhase phase, int room, int lives) {
        (void)room; (void)lives;
        [phases addObject:@(phase)];
    };

    [d startGameWithPlayers:1];
    int maxFrames = (int)(300.f / kFrameDt);
    for (int i = 0; i < maxFrames && d.currentRoom < 4; ++i) {
        if (d.gamePhase == BrawlerGamePhaseUpgrade)
            [d chooseUpgrade:0];
        [d advanceFrame:kFrameDt];
    }

    XCTAssertEqual(d.currentRoom, 4);
    XCTAssertEqual(d.gamePhase, BrawlerGamePhasePlaying);
    // Leaving the shop into a combat room offers the curse choice → calm + cursed exits.
    XCTAssertEqual([d exitEntityCount], 2);
    XCTAssertEqual([d shopkeeperEntityCount], 1);
    XCTAssertEqual([d shopItemEntityCount], 3);
    [phases removeAllObjects];
    for (int i = 0; i < 20; ++i)
        [d advanceFrame:kFrameDt];
    for (NSNumber *phase in phases)
        XCTAssertNotEqual(phase.integerValue, BrawlerGamePhaseRoomClear,
                          @"shop room must not enter RoomClear immediately");

    BOOL advanced = NO;
    for (int i = 0; i < (int)(30.f / kFrameDt); ++i) {
        [d advanceFrame:kFrameDt];
        if (d.currentRoom == 5 && d.gamePhase == BrawlerGamePhasePlaying) {
            advanced = YES;
            break;
        }
    }
    XCTAssertTrue(advanced, @"ExitReached in the shop should advance to the next middle room");
}

- (void)test_metaProgressInMemoryStoreSaveLoadRoundTripsWithoutDefaults {
    MetaProgressStore *store = [MetaProgressStore inMemoryStore];
    store.coins = 123;
    store.hpLevel = 4;
    store.livesLevel = 2;
    store.scrapLevel = 3;
    store.secondWindLevel = 1;
    [store save];

    store.coins = 0;
    store.hpLevel = 0;
    store.livesLevel = 0;
    store.scrapLevel = 0;
    store.secondWindLevel = 0;
    [store load];

    XCTAssertEqual(store.coins, 123);
    XCTAssertEqual(store.hpLevel, 4);
    XCTAssertEqual(store.livesLevel, 2);
    XCTAssertEqual(store.scrapLevel, 3);
    XCTAssertEqual(store.secondWindLevel, 1);
}

- (void)test_metaShopBuyingRespectsCostsCapsAndNavigation {
    BrawlerGameDelegate *d = [[BrawlerGameDelegate alloc] initHeadless];
    MetaProgressStore *store = d.debugMetaStore;
    store.coins = 200;
    [store save];

    [d enterMetaShop];
    XCTAssertEqual(d.gamePhase, BrawlerGamePhaseMetaShop);
    XCTAssertEqual([d currentMetaShopIndex], 0);
    XCTAssertTrue([[d metaShopLine:0] containsString:@"Vitality"]);

    XCTAssertTrue([d buySelectedMetaUpgrade]);
    XCTAssertEqual(store.hpLevel, 1);
    XCTAssertEqual(store.coins, 180);
    XCTAssertTrue([d buySelectedMetaUpgrade]);
    XCTAssertTrue([d buySelectedMetaUpgrade]);
    XCTAssertTrue([d buySelectedMetaUpgrade]);
    XCTAssertEqual(store.hpLevel, 4);
    XCTAssertEqual(store.coins, 10);
    XCTAssertFalse([d buySelectedMetaUpgrade]);
    XCTAssertEqual(store.hpLevel, 4);
    XCTAssertEqual(store.coins, 10);

    [d metaShopMove:1];
    XCTAssertEqual([d currentMetaShopIndex], 1);
    XCTAssertFalse([d buySelectedMetaUpgrade]);
    XCTAssertEqual(store.livesLevel, 0);
    [d exitMetaShop];
    XCTAssertEqual(d.gamePhase, BrawlerGamePhaseTitle);
}

- (void)test_metaUpgradesApplyAtRunStartBeforePlayersSpawn {
    BrawlerGameDelegate *d = [[BrawlerGameDelegate alloc] initHeadless];
    MetaProgressStore *store = d.debugMetaStore;
    store.hpLevel = 4;
    store.livesLevel = 2;
    store.scrapLevel = 3;
    store.secondWindLevel = 1;
    [store save];

    [d startGameWithPlayers:1];
    XCTAssertEqual(d.livesRemaining, 5);
    XCTAssertEqual([d debugScrap], 45);
    XCTAssertEqual([d debugFirstPlayerMaxHP], 14);
    XCTAssertEqual([d debugFirstPlayerSecondWinds], 1);
}

- (void)test_metaDefaultsAreZeroForHeadlessRuns {
    BrawlerGameDelegate *d = [[BrawlerGameDelegate alloc] initHeadless];
    XCTAssertEqual(d.debugMetaStore.coins, 0);
    XCTAssertEqual(d.debugMetaStore.hpLevel, 0);
    XCTAssertEqual(d.debugMetaStore.livesLevel, 0);
    XCTAssertEqual(d.debugMetaStore.scrapLevel, 0);
    XCTAssertEqual(d.debugMetaStore.secondWindLevel, 0);

    [d startGameWithPlayers:1];
    XCTAssertEqual(d.livesRemaining, 3);
    XCTAssertEqual([d debugScrap], 0);
    XCTAssertEqual([d debugFirstPlayerMaxHP], 10);
    XCTAssertEqual([d debugFirstPlayerSecondWinds], 0);
}

- (void)test_runCoinsAccruePerRoomBankOnWinAndResetNextRun {
    BrawlerGameDelegate *d = [[BrawlerGameDelegate alloc] initHeadless];
    d.rngSeedOverride = 42;
    d.autoPilotEnabled = YES;
    MetaProgressStore *store = d.debugMetaStore;

    [d startGameWithPlayers:1];
    XCTAssertTrue(advanceDelegateUntilPhase(d, BrawlerGamePhaseWin, 510.f),
                  @"AutoPilot should still win at meta level 0");

    XCTAssertEqual([d debugRunCoins], 46);
    XCTAssertEqual(store.coins, 46);

    [d startGameWithPlayers:1];
    XCTAssertEqual([d debugRunCoins], 0);
    XCTAssertEqual(store.coins, 46);
}

- (void)test_runCoinsBankOnLoseIncludingCurseRewards {
    BrawlerGameDelegate *d = [[BrawlerGameDelegate alloc] initHeadless];
    d.rngSeedOverride = 42;
    [d startGameWithPlayers:1];
    [d debugApplyCurseRewardType:0];
    XCTAssertEqual([d debugRunCoins], 8);

    XCTAssertTrue(advanceDelegateUntilPhase(d, BrawlerGamePhaseLose, 300.f),
                  @"Idle player should eventually lose and bank run coins");
    XCTAssertEqual(d.debugMetaStore.coins, 8);
}

@end
