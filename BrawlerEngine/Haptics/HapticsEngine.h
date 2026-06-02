#import <Foundation/Foundation.h>

// Wraps CHHapticEngine. Initialized at startup (not lazily).
// No-op on hardware that doesn't support haptics (guarded by supportsHaptics).
@interface HapticsEngine : NSObject

// Call once from app delegate before first frame.
- (void)startupInit;

// Sharp transient — call on CombatSystem hit contact.
- (void)playHitHaptic;

@end
