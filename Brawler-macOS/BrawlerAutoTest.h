#import <Foundation/Foundation.h>
@class BrawlerGameDelegate;

// --autotest smoke driver: AutoPilot plays a full 1P run while screenshots of
// the key beats (title, player select, each room mid-combat, room clears, win)
// are written to the output directory. The process exits 0 if the bot reaches
// the Win phase, 2 if it loses, 1 on timeout — so scripts/smoke.sh is a
// pass/fail gate that also produces visual evidence.
//
// Launch arguments:
//   --autotest                 enable
//   --autotest-out=/some/dir   screenshot directory (default /tmp/brawler-autotest)
@interface BrawlerAutoTest : NSObject

+ (BOOL)isEnabled;

- (instancetype)initWithDelegate:(BrawlerGameDelegate *)delegate;
- (void)start;

@end
