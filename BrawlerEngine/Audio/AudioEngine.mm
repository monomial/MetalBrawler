#import "AudioEngine.h"
#include <math.h>
#include <stdlib.h>

// ---------------------------------------------------------------------------
// Buffer synthesis helpers
// ---------------------------------------------------------------------------

static AVAudioPCMBuffer* synth_buffer(AVAudioFormat *fmt, double durationSec,
                                       void (^fill)(float *L, float *R, int frames, double sr)) {
    int frames = (int)(fmt.sampleRate * durationSec);
    AVAudioPCMBuffer *buf = [[AVAudioPCMBuffer alloc] initWithPCMFormat:fmt frameCapacity:frames];
    buf.frameLength = frames;
    float *L = buf.floatChannelData[0];
    float *R = (fmt.channelCount > 1) ? buf.floatChannelData[1] : nullptr;
    fill(L, R, frames, fmt.sampleRate);
    return buf;
}

// Improved punch impact: low thump + high-freq crack, 2ms fade-in to kill click transient.
static AVAudioPCMBuffer* make_hit_buffer(AVAudioFormat *fmt) {
    return synth_buffer(fmt, 0.18, ^(float *L, float *R, int frames, double sr) {
        for (int i = 0; i < frames; ++i) {
            float t     = (float)i / (float)frames;
            float tSec  = (float)i / (float)sr;
            float attack = fminf(tSec / 0.003f, 1.f);              // 3ms fade-in → no click
            float thump  = sinf(2.f * (float)M_PI * 90.f * tSec)
                           * expf(-tSec * 28.f) * 0.55f;           // 90 Hz body thump
            float noise  = ((float)rand() / (float)RAND_MAX * 2.f - 1.f);
            float crack  = noise * expf(-tSec * 90.f) * 0.22f;     // fast noise crack
            float s      = (thump + crack) * attack;
            L[i] = s;
            if (R) R[i] = s;
        }
    });
}

// Short, slightly higher-pitched impact for when the player takes a hit.
static AVAudioPCMBuffer* make_hurt_buffer(AVAudioFormat *fmt) {
    return synth_buffer(fmt, 0.14, ^(float *L, float *R, int frames, double sr) {
        for (int i = 0; i < frames; ++i) {
            float tSec   = (float)i / (float)sr;
            float attack = fminf(tSec / 0.003f, 1.f);
            float thump  = sinf(2.f * (float)M_PI * 140.f * tSec)
                           * expf(-tSec * 35.f) * 0.45f;
            float noise  = ((float)rand() / (float)RAND_MAX * 2.f - 1.f);
            float crack  = noise * expf(-tSec * 70.f) * 0.18f;
            float s      = (thump + crack) * attack;
            L[i] = s;
            if (R) R[i] = s;
        }
    });
}

// Descending thump with longer tail for enemy/player death.
static AVAudioPCMBuffer* make_death_buffer(AVAudioFormat *fmt) {
    return synth_buffer(fmt, 0.30, ^(float *L, float *R, int frames, double sr) {
        for (int i = 0; i < frames; ++i) {
            float tSec   = (float)i / (float)sr;
            float attack = fminf(tSec / 0.004f, 1.f);
            float freq   = 120.f * expf(-tSec * 4.f);             // pitch drop 120→~18Hz
            // Integrate frequency to get phase (avoid discontinuity in freq sweep)
            // Simple approx: use instantaneous freq
            float phase  = 2.f * (float)M_PI * (120.f / 4.f) * (1.f - expf(-tSec * 4.f));
            float thump  = sinf(phase) * expf(-tSec * 10.f) * 0.55f;
            float noise  = ((float)rand() / (float)RAND_MAX * 2.f - 1.f);
            float rumble = noise * expf(-tSec * 18.f) * 0.20f;
            float s      = (thump + rumble) * attack;
            L[i] = s;
            if (R) R[i] = s;
        }
    });
}

// ---------------------------------------------------------------------------
// Bundle asset lookup — tries multiple extensions, returns nil if not found.
// ---------------------------------------------------------------------------

static NSURL* bundleAudioURL(NSString *name) {
    NSArray *exts = @[@"wav", @"caf", @"mp3", @"m4a", @"aiff"];
    // Search top-level resources, then the assets/audio subfolder (folder reference).
    NSArray *subdirs = @[@"", @"assets/audio", @"audio"];
    for (NSString *sub in subdirs) {
        NSString *subArg = sub.length ? sub : nil;
        for (NSString *ext in exts) {
            NSURL *url = [[NSBundle mainBundle] URLForResource:name
                                                withExtension:ext
                                                 subdirectory:subArg];
            if (url) return url;
        }
    }
    return nil;
}

// Loads a bundle audio file into an AVAudioPCMBuffer in the engine's format.
// Returns nil if the file is not found or conversion fails.
static AVAudioPCMBuffer* loadBundleBuffer(NSString *name, AVAudioFormat *targetFmt) {
    NSURL *url = bundleAudioURL(name);
    if (!url) return nil;

    NSError *err = nil;
    AVAudioFile *file = [[AVAudioFile alloc] initForReading:url error:&err];
    if (!file) {
        NSLog(@"AudioEngine: failed to open %@: %@", name, err);
        return nil;
    }

    // Convert to engine's processing format if needed.
    AVAudioConverter *conv = [[AVAudioConverter alloc] initFromFormat:file.processingFormat
                                                            toFormat:targetFmt];
    AVAudioFrameCount capacity = (AVAudioFrameCount)(file.length * targetFmt.sampleRate
                                                     / file.processingFormat.sampleRate) + 1024;
    AVAudioPCMBuffer *out = [[AVAudioPCMBuffer alloc] initWithPCMFormat:targetFmt
                                                          frameCapacity:capacity];
    AVAudioPCMBuffer *src = [[AVAudioPCMBuffer alloc] initWithPCMFormat:file.processingFormat
                                                          frameCapacity:(AVAudioFrameCount)file.length];
    if (![file readIntoBuffer:src error:&err]) {
        NSLog(@"AudioEngine: failed to read %@: %@", name, err);
        return nil;
    }

    __block BOOL inputConsumed = NO;
    AVAudioConverterInputBlock inputBlock = ^AVAudioBuffer*(AVAudioPacketCount inNumPackets,
                                                            AVAudioConverterInputStatus *outStatus) {
        if (inputConsumed) { *outStatus = AVAudioConverterInputStatus_NoDataNow; return nil; }
        *outStatus = AVAudioConverterInputStatus_HaveData;
        inputConsumed = YES;
        return src;
    };
    NSError *convErr = nil;
    [conv convertToBuffer:out error:&convErr withInputFromBlock:inputBlock];
    if (convErr) {
        NSLog(@"AudioEngine: conversion failed for %@: %@", name, convErr);
        return nil;
    }

    NSLog(@"AudioEngine: loaded %@ from bundle", name);
    return out;
}

// ---------------------------------------------------------------------------
// AudioEngine
// ---------------------------------------------------------------------------

@implementation AudioEngine {
    AVAudioEngine       *_engine;
    AVAudioPlayerNode   *_sfxNode;      // shared low-latency SFX node
    AVAudioPCMBuffer    *_hitBuf;
    AVAudioPCMBuffer    *_hurtBuf;
    AVAudioPCMBuffer    *_deathBuf;
    AVAudioPlayer       *_musicPlayer;
    float                _musicVolume;
    BOOL                 _started;
}

- (instancetype)init {
    self = [super init];
    _musicVolume = 0.6f;
    return self;
}

- (void)startupInit {
    if (_started) return;

    _engine  = [[AVAudioEngine alloc] init];
    _sfxNode = [[AVAudioPlayerNode alloc] init];
    [_engine attachNode:_sfxNode];

    AVAudioMixerNode *mixer = _engine.mainMixerNode;
    AVAudioFormat    *fmt   = [mixer outputFormatForBus:0];
    [_engine connect:_sfxNode to:mixer format:fmt];

    NSError *err = nil;
    if (![_engine startAndReturnError:&err]) {
        NSLog(@"AudioEngine: startup failed: %@ — audio disabled", err);
        return;
    }

    // Load each SFX: bundle file overrides synthetic fallback.
    _hitBuf   = loadBundleBuffer(@"sfx_hit",   fmt) ?: make_hit_buffer(fmt);
    _hurtBuf  = loadBundleBuffer(@"sfx_hurt",  fmt) ?: make_hurt_buffer(fmt);
    _deathBuf = loadBundleBuffer(@"sfx_death", fmt) ?: make_death_buffer(fmt);

    _started = YES;
    NSLog(@"AudioEngine: ready (sampleRate %.0f Hz)", fmt.sampleRate);
}

// Schedules a buffer on the shared SFX node. Multiple rapid calls queue up
// naturally — AVAudioPlayerNode handles them without clipping.
- (void)_playBuffer:(AVAudioPCMBuffer*)buf {
    if (!_started || !buf) return;
    [_sfxNode scheduleBuffer:buf completionHandler:nil];
    if (!_sfxNode.playing) [_sfxNode play];
}

- (void)playHitSound   { [self _playBuffer:_hitBuf];   }
- (void)playHurtSound  { [self _playBuffer:_hurtBuf];  }
- (void)playDeathSound { [self _playBuffer:_deathBuf]; }

// ---------------------------------------------------------------------------
// Music
// ---------------------------------------------------------------------------

- (void)startBattleMusic {
    NSURL *url = bundleAudioURL(@"music_battle");
    if (!url) {
        NSLog(@"AudioEngine: music_battle not found — add music_battle.mp3 to bundle to enable music");
        return;
    }
    if (_musicPlayer && _musicPlayer.playing) return;

    NSError *err = nil;
    _musicPlayer = [[AVAudioPlayer alloc] initWithContentsOfURL:url error:&err];
    if (!_musicPlayer) { NSLog(@"AudioEngine: music load failed: %@", err); return; }
    _musicPlayer.numberOfLoops = -1; // loop forever
    _musicPlayer.volume        = _musicVolume;
    [_musicPlayer prepareToPlay];
    [_musicPlayer play];
    NSLog(@"AudioEngine: music started (%@)", url.lastPathComponent);
}

- (void)stopMusic {
    [_musicPlayer stop];
    _musicPlayer = nil;
}

- (void)setMusicVolume:(float)volume {
    _musicVolume = volume;
    _musicPlayer.volume = volume;
}

@end
