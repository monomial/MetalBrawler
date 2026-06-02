#import "HapticsEngine.h"
#import <CoreHaptics/CoreHaptics.h>

@implementation HapticsEngine {
    CHHapticEngine *_engine;
    BOOL            _supported;
}

- (void)startupInit {
    if (_supported) return;

    id<CHHapticDeviceCapability> cap = [CHHapticEngine capabilitiesForHardware];
    if (!cap.supportsHaptics) {
        NSLog(@"HapticsEngine: haptics not supported on this device");
        return;
    }

    NSError *err = nil;
    _engine = [[CHHapticEngine alloc] initAndReturnError:&err];
    if (!_engine) { NSLog(@"HapticsEngine init: %@", err); return; }

    __weak HapticsEngine *weakSelf = self;
    _engine.stoppedHandler = ^(CHHapticEngineStoppedReason reason) {
        NSLog(@"HapticsEngine stopped (reason %ld) — restarting", (long)reason);
        HapticsEngine *strong = weakSelf;
        if (strong) [strong->_engine startWithCompletionHandler:nil];
    };
    _engine.resetHandler = ^{
        HapticsEngine *strong = weakSelf;
        if (strong) [strong->_engine startWithCompletionHandler:nil];
    };

    [_engine startWithCompletionHandler:^(NSError *startErr) {
        if (startErr) NSLog(@"HapticsEngine start: %@", startErr);
    }];
    _supported = YES;
}

- (void)playHitHaptic {
    if (!_supported) return;

    CHHapticEventParameter *intensity =
        [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticIntensity
                                                      value:0.85f];
    CHHapticEventParameter *sharpness =
        [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticSharpness
                                                      value:0.9f];

    CHHapticEvent *impact =
        [[CHHapticEvent alloc] initWithEventType:CHHapticEventTypeHapticTransient
                                      parameters:@[intensity, sharpness]
                                    relativeTime:0
                                        duration:0.1];

    NSError *err = nil;
    CHHapticPattern *pattern =
        [[CHHapticPattern alloc] initWithEvents:@[impact] parameters:@[] error:&err];
    if (!pattern) return;

    id<CHHapticPatternPlayer> player = [_engine createPlayerWithPattern:pattern error:&err];
    [player startAtTime:0 error:nil];
}

@end
