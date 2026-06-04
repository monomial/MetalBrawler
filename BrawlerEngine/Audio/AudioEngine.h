#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

// Wraps AVAudioEngine (low-latency SFX) + AVAudioPlayer (background music).
// Must be initialized at app startup to avoid the ~100ms cold-start hitch.
//
// Asset loading: each sound method looks for a corresponding file in the main
// bundle (sfx_hit, sfx_hurt, sfx_death — any of .wav .caf .mp3 .m4a) before
// falling back to a synthetic version.  Drop real files into the assets/audio/
// folder and add them to the Xcode target to replace the synthetics.
//
// Music: startBattleMusic looks for music_battle (.mp3 .m4a .wav .caf).
// Silent if the file is absent — add a track when you have one.
@interface AudioEngine : NSObject

// Call once from game delegate init.
- (void)startupInit;

// Sound effects — safe to call every frame, internally rate-limited.
- (void)playHitSound;    // punch landing on target
- (void)playHurtSound;   // entity receiving damage but not dying
- (void)playDeathSound;  // entity HP hits 0

// Background music.
- (void)startBattleMusic;
- (void)stopMusic;
- (void)setMusicVolume:(float)volume; // 0.0–1.0, default 0.6

@end
