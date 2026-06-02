#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

// Wraps AVAudioEngine. Must be initialized at app startup (not lazily) to
// avoid the ~100ms cold-start hitch on the first sound trigger.
// Placeholder: no sounds yet — engine is started and ready for nodes.
@interface AudioEngine : NSObject

// Call once from app delegate / game loop init. Safe to call multiple times.
- (void)startupInit;

// Placeholder trigger — wired to CombatSystem hit events in a future pass.
- (void)playHitSound;

@end
