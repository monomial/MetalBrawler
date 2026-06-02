#import "AudioEngine.h"

@implementation AudioEngine {
    AVAudioEngine  *_engine;
    AVAudioPlayerNode *_playerNode;
    BOOL            _started;
}

- (void)startupInit {
    if (_started) return;

    _engine     = [[AVAudioEngine alloc] init];
    _playerNode = [[AVAudioPlayerNode alloc] init];
    [_engine attachNode:_playerNode];

    AVAudioMixerNode *mainMixer = _engine.mainMixerNode;
    AVAudioFormat *fmt = [mainMixer outputFormatForBus:0];
    [_engine connect:_playerNode to:mainMixer format:fmt];

    NSError *err = nil;
    if (![_engine startAndReturnError:&err]) {
        NSLog(@"AudioEngine startup failed: %@ — audio disabled", err);
        return;
    }

    _started = YES;
}

- (void)playHitSound {
    if (!_started) return;
    // TODO: schedule hit buffer on _playerNode when sound assets exist.
}

@end
