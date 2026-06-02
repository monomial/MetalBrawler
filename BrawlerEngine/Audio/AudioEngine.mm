#import "AudioEngine.h"
#include <math.h>
#include <stdlib.h>

// Synthetic hit sound — decaying noise burst, no external assets required.
// Replace with real asset when art pipeline decision is made.
static AVAudioPCMBuffer* make_hit_buffer(AVAudioFormat *fmt) {
    const double sampleRate = fmt.sampleRate;
    const int    frames     = (int)(sampleRate * 0.12); // 120ms

    AVAudioPCMBuffer *buf = [[AVAudioPCMBuffer alloc] initWithPCMFormat:fmt
                                                          frameCapacity:frames];
    buf.frameLength = frames;
    float *L = buf.floatChannelData[0];
    float *R = (fmt.channelCount > 1) ? buf.floatChannelData[1] : NULL;

    for (int i = 0; i < frames; ++i) {
        float t     = (float)i / (float)frames;
        float decay = expf(-t * 30.0f);                          // fast decay
        float noise = ((float)rand() / (float)RAND_MAX) * 2.f - 1.f;
        float sample = noise * decay * 0.55f;
        L[i] = sample;
        if (R) R[i] = sample;
    }
    return buf;
}

@implementation AudioEngine {
    AVAudioEngine       *_engine;
    AVAudioPlayerNode   *_playerNode;
    AVAudioPCMBuffer    *_hitBuffer;
    BOOL                 _started;
}

- (void)startupInit {
    if (_started) return;

    _engine     = [[AVAudioEngine alloc] init];
    _playerNode = [[AVAudioPlayerNode alloc] init];
    [_engine attachNode:_playerNode];

    AVAudioMixerNode *mixer = _engine.mainMixerNode;
    AVAudioFormat    *fmt   = [mixer outputFormatForBus:0];
    [_engine connect:_playerNode to:mixer format:fmt];

    NSError *err = nil;
    if (![_engine startAndReturnError:&err]) {
        NSLog(@"AudioEngine startup failed: %@ — audio disabled", err);
        return;
    }

    _hitBuffer = make_hit_buffer(fmt);
    _started   = YES;
}

- (void)playHitSound {
    if (!_started || !_hitBuffer) return;
    // Schedule at the player's sample time so consecutive hits don't clip each other.
    [_playerNode scheduleBuffer:_hitBuffer completionHandler:nil];
    if (!_playerNode.playing) [_playerNode play];
}

@end
