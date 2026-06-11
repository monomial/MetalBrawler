#import "BrawlerAutoTest.h"
#import "BrawlerGameDelegate.h"
#import <QuartzCore/QuartzCore.h>

static const float    kTickInterval   = 0.1f;   // driver poll rate
static const float    kBeatDelay      = 0.8f;   // settle time before acting on a phase
static const float    kRoomShotDelay  = 1.2f;   // into a room → mid-combat screenshot
static const double   kRunTimeout     = 300.0;  // wall-clock seconds before exit(1)
static const double   kExitGrace      = 1.5;    // let async PNG writes finish

@implementation BrawlerAutoTest {
    BrawlerGameDelegate *_delegate;
    NSString            *_outDir;
    NSMutableSet<NSString *> *_done;     // beats already handled
    NSTimer             *_timer;
    CFTimeInterval       _startTime;
    CFTimeInterval       _phaseEnteredAt;
    BrawlerGamePhase     _lastPhase;
    int                  _shotIndex;
}

+ (BOOL)isEnabled {
    return [[NSProcessInfo processInfo].arguments containsObject:@"--autotest"];
}

+ (NSString *)outputDir {
    for (NSString *arg in [NSProcessInfo processInfo].arguments)
        if ([arg hasPrefix:@"--autotest-out="])
            return [arg substringFromIndex:[@"--autotest-out=" length]];
    return @"/tmp/brawler-autotest";
}

- (instancetype)initWithDelegate:(BrawlerGameDelegate *)delegate {
    self = [super init];
    if (!self) return nil;
    _delegate  = delegate;
    _outDir    = [BrawlerAutoTest outputDir];
    _done      = [NSMutableSet set];
    _lastPhase = (BrawlerGamePhase)-1;
    _shotIndex = 0;
    return self;
}

- (void)start {
    [[NSFileManager defaultManager] createDirectoryAtPath:_outDir
                              withIntermediateDirectories:YES attributes:nil error:nil];
    _delegate.autoPilotEnabled = YES;
    _delegate.rngSeedOverride  = 42;
    _delegate.fixedFrameDt     = 1.f / 60.f; // reproduce the headless scenario exactly
    _startTime      = CACurrentMediaTime();
    _phaseEnteredAt = _startTime;

    NSLog(@"autotest: started, screenshots → %@", _outDir);
    _timer = [NSTimer scheduledTimerWithTimeInterval:kTickInterval target:self
                                            selector:@selector(_tick) userInfo:nil repeats:YES];
}

- (void)_shoot:(NSString *)name {
    if ([_done containsObject:name]) return;
    [_done addObject:name];
    NSString *file = [NSString stringWithFormat:@"%02d-%@.png", ++_shotIndex, name];
    [_delegate captureNextFrameToPath:[_outDir stringByAppendingPathComponent:file]];
    NSLog(@"autotest: capture %@", file);
}

- (void)_finishWithStatus:(int)status reason:(NSString *)reason {
    [_timer invalidate];
    _timer = nil;
    NSLog(@"autotest: %@ — exiting %d in %.1fs", reason, status, kExitGrace);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kExitGrace * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ exit(status); });
}

- (void)_tick {
    CFTimeInterval now = CACurrentMediaTime();
    if (now - _startTime > kRunTimeout) {
        [self _finishWithStatus:1 reason:@"TIMEOUT: bot never reached Win"];
        return;
    }

    BrawlerGamePhase phase = _delegate.gamePhase;
    if (phase != _lastPhase) {
        _lastPhase      = phase;
        _phaseEnteredAt = now;
    }
    double inPhase = now - _phaseEnteredAt;
    int    room    = _delegate.currentRoom;

    switch (phase) {
        case BrawlerGamePhaseTitle: {
            // Capture the title once, then advance. Ignore the post-win/lose
            // return to title (the run is already over by then).
            if ([_done containsObject:@"win"] || [_done containsObject:@"lose"]) break;
            [self _shoot:@"title"];
            if (inPhase > kBeatDelay) [_delegate triggerAttack];
            break;
        }
        case BrawlerGamePhasePlayerSelect: {
            [self _shoot:@"player-select"];
            if (inPhase > kBeatDelay) [_delegate startGameWithPlayers:1];
            break;
        }
        case BrawlerGamePhasePlaying: {
            // Wave lifecycle beats: markers telegraph ~1.5–2.5s in, spawn
            // animations ~2.5–3.1s, real combat after that.
            if (inPhase > 2.0f)
                [self _shoot:[NSString stringWithFormat:@"room%d-telegraph", room]];
            if (inPhase > 2.8f)
                [self _shoot:[NSString stringWithFormat:@"room%d-spawn", room]];
            if (inPhase > 5.5f)
                [self _shoot:[NSString stringWithFormat:@"room%d-combat", room]];
            break;
        }
        case BrawlerGamePhaseRoomClear: {
            [self _shoot:[NSString stringWithFormat:@"room%d-clear", room]];
            break;
        }
        case BrawlerGamePhaseUpgrade: {
            [self _shoot:[NSString stringWithFormat:@"room%d-upgrade", room]];
            if (inPhase > kBeatDelay) {
                // Same priority a competent player uses: damage > health > rest.
                NSString *a = [_delegate upgradeChoiceLabel:0];
                NSString *b = [_delegate upgradeChoiceLabel:1];
                if      ([a containsString:@"Damage"]) [_delegate triggerAttack];
                else if ([b containsString:@"Damage"]) [_delegate triggerDodge];
                else if ([a containsString:@"Health"]) [_delegate triggerAttack];
                else if ([b containsString:@"Health"]) [_delegate triggerDodge];
                else                                   [_delegate triggerAttack];
            }
            break;
        }
        case BrawlerGamePhaseWin: {
            [self _shoot:@"win"];
            [self _finishWithStatus:0 reason:@"WIN: bot cleared all rooms"];
            break;
        }
        case BrawlerGamePhaseLose: {
            [self _shoot:@"lose"];
            [self _finishWithStatus:2 reason:@"LOSE: bot ran out of lives"];
            break;
        }
        case BrawlerGamePhasePaused:
            break;
    }
}

@end
