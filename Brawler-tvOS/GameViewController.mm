#import "GameViewController.h"
#import <MetalKit/MetalKit.h>
#import <GameController/GameController.h>
#include "Simulation/World.h"
#include "Platform/InputState.h"
#include "Platform/SiriRemoteInput.h"
#include "Simulation/Systems/RespawnSystem.h"
#include "Simulation/Systems/AnimationSystem.h"
#include "Assets/CharacterLoader.h"
#import "Renderer/BrawlerRenderer.h"
#import "Haptics/HapticsEngine.h"
#import "Audio/AudioEngine.h"

// tvOS input: Siri Remote swipe delta → dead-zone + acceleration curve → InputState.
// GCController events for MFi gamepads handled via GCController.controllerDidConnectNotification.

@interface BrawlerDelegate_tvOS : NSObject <MTKViewDelegate>
- (instancetype)initWithDevice:(id<MTLDevice>)device pixelFormat:(MTLPixelFormat)pfmt;
- (void)resetInput;
@end

@implementation BrawlerDelegate_tvOS {
    World                _world;
    CFTimeInterval       _lastTime;
    id<MTLCommandQueue>  _commandQueue;
    BrawlerRenderer     *_renderer;
    HapticsEngine       *_haptics;
    AudioEngine         *_audio;
    dispatch_semaphore_t _frameSemaphore;
    InputState           _currentInput;
    BOOL                 _gameOver;
    float                _gameOverTimer;
}

- (instancetype)initWithDevice:(id<MTLDevice>)device pixelFormat:(MTLPixelFormat)pfmt {
    self = [super init];
    if (!self) return nil;

    _commandQueue   = [device newCommandQueue];
    _lastTime       = CACurrentMediaTime();
    _frameSemaphore = dispatch_semaphore_create(3);
    _currentInput   = {};
    _renderer = [[BrawlerRenderer alloc] initWithDevice:device pixelFormat:pfmt];
    _haptics  = [[HapticsEngine alloc] init];
    [_haptics startupInit];
    _audio    = [[AudioEngine alloc] init];
    [_audio startupInit];

    [self _loadCharacters:device];
    [self _spawnEntities];

    return self;
}

- (void)_loadCharacters:(id<MTLDevice>)device {
    NSString *res = [NSBundle mainBundle].resourcePath;
    NSString *playerDir = [res stringByAppendingPathComponent:@"assets/characters/player"];
    NSString *mesh = [playerDir stringByAppendingPathComponent:@"Ch24_nonPBR.usdz"];

    NSMutableArray<NSString*> *clips = [NSMutableArray array];
    for (NSString *n in @[@"idle.usdz", @"walk.usdz", @"attack.usdz",
                           @"hurt.usdz", @"death.usdz"])
        [clips addObject:[playerDir stringByAppendingPathComponent:n]];

    LoadedCharacter *player = CharacterLoader_load(mesh, clips, device);
    AnimationSystem_set_characters(player, player);
    [_renderer setPlayerCharacter:player enemyCharacter:player];
}

- (void)_spawnEntities {
    EntityID player = _world.defer_create();
    _world.add_component<PlayerTagComponent>(player).active   = true;
    _world.add_component<PositionComponent>(player)           = {0, -100, 0};
    _world.add_component<VelocityComponent>(player)           = {0, 0, 0};
    _world.add_component<FactionComponent>(player).type       = FactionComponent::Player;
    _world.add_component<HealthComponent>(player)             = {10, 10};
    _world.add_component<DamageCooldownComponent>(player).remaining = 0.f;
    _world.add_component<AnimationComponent>(player);

    EntityID enemy = _world.defer_create();
    _world.add_component<PositionComponent>(enemy)            = {200, 300, 0};
    _world.add_component<VelocityComponent>(enemy)            = {0, 0, 0};
    _world.add_component<FactionComponent>(enemy).type        = FactionComponent::Enemy;
    _world.add_component<HealthComponent>(enemy)              = {3, 3};
    _world.add_component<AnimationComponent>(enemy);
}

- (void)resetInput { _currentInput = {}; }

- (void)_restart {
    _world    = World();
    _gameOver = NO;
    _currentInput = {};
    [self _spawnEntities];
    RespawnSystem_reset();
}

- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {
    [_renderer updateDrawableSize:size];
}

- (void)drawInMTKView:(MTKView *)view {
    dispatch_semaphore_wait(_frameSemaphore, DISPATCH_TIME_FOREVER);

    CFTimeInterval now = CACurrentMediaTime();
    float physicalDt = fminf((float)(now - _lastTime), 0.1f);
    _lastTime = now;

    _world.set_input(_currentInput);
    _world.update(physicalDt, physicalDt);

    _world.events().for_each(EventType::HitContact, [self](const Event&) {
        [_audio  playHitSound];
        [_haptics playHitHaptic];
    });

    if (!_gameOver) {
        for (EntityID id = 0; id < _world.entity_count(); ++id) {
            if (!_world.player_tags().present(id)) continue;
            if (_world.has_component<AnimationComponent>(id) &&
                _world.get_component<AnimationComponent>(id).dying) {
                _gameOver      = YES;
                _gameOverTimer = 3.0f;
            }
            break;
        }
    } else {
        _gameOverTimer -= physicalDt;
        if (_gameOverTimer <= 0.f) [self _restart];
    }

    id<MTLCommandBuffer> cmd = [_commandQueue commandBuffer];
    __block dispatch_semaphore_t sem = _frameSemaphore;
    [cmd addCompletedHandler:^(id<MTLCommandBuffer> _) {
        dispatch_semaphore_signal(sem);
    }];

    [_renderer drawWorld:&_world inView:view commandBuffer:cmd];
    [cmd commit];
}

- (void)_controllerConnected:(NSNotification *)note {
    GCController *ctrl = note.object;
    if (!ctrl) return;

    // Extended gamepad FIRST — PS4/Xbox/Switch Pro all report non-nil microGamepad
    // too (it's a subset profile), so checking micro first incorrectly routes them
    // through SiriRemote_processSwipeDelta. Prefer extendedGamepad for full analog.
    GCExtendedGamepad *ext = ctrl.extendedGamepad;
    if (ext) {
        __weak BrawlerDelegate_tvOS *weakSelf = self;
        ext.leftThumbstick.valueChangedHandler = ^(GCControllerDirectionPad *pad, float x, float y) {
            BrawlerDelegate_tvOS *s = weakSelf;
            if (!s) return;
            s->_currentInput.moveX = x;
            s->_currentInput.moveY = y;
        };
        ext.buttonA.valueChangedHandler = ^(GCControllerButtonInput *btn, float val, BOOL pressed) {
            BrawlerDelegate_tvOS *s = weakSelf;
            if (!s) return;
            s->_currentInput.attack = pressed;
        };
        return;
    }

    // Siri Remote only (micro-gamepad, no extended profile) — swipe delta input.
    GCMicroGamepad *micro = ctrl.microGamepad;
    if (micro) {
        micro.reportsAbsoluteDpadValues = NO; // want delta, not absolute
        __weak BrawlerDelegate_tvOS *weakSelf = self;
        micro.dpad.valueChangedHandler = ^(GCControllerDirectionPad *dpad, float x, float y) {
            BrawlerDelegate_tvOS *s = weakSelf;
            if (!s) return;
            s->_currentInput = SiriRemote_processSwipeDelta(x, y);
        };
        micro.buttonA.valueChangedHandler = ^(GCControllerButtonInput *btn, float val, BOOL pressed) {
            BrawlerDelegate_tvOS *s = weakSelf;
            if (!s) return;
            s->_currentInput.attack = pressed;
        };
    }
}

@end

// ---------------------------------------------------------------------------
// GameViewController — owns MTKView and BrawlerDelegate_tvOS
// ---------------------------------------------------------------------------
@implementation GameViewController {
    MTKView              *_mtkView;
    BrawlerDelegate_tvOS *_delegate;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    _mtkView = [[MTKView alloc] initWithFrame:self.view.bounds device:device];
    _mtkView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _mtkView.colorPixelFormat        = MTLPixelFormatBGRA8Unorm;
    _mtkView.depthStencilPixelFormat = MTLPixelFormatDepth32Float;
    [self.view addSubview:_mtkView];

    _delegate = [[BrawlerDelegate_tvOS alloc] initWithDevice:device
                                                 pixelFormat:_mtkView.colorPixelFormat];
    [_delegate mtkView:_mtkView drawableSizeWillChange:_mtkView.drawableSize];
    _mtkView.delegate = _delegate;

    [[NSNotificationCenter defaultCenter]
        addObserver:_delegate
           selector:@selector(_controllerConnected:)
               name:GCControllerDidConnectNotification
             object:nil];
    [GCController startWirelessControllerDiscoveryWithCompletionHandler:nil];
}

- (void)pauseRendering {
    [_delegate resetInput];
    _mtkView.paused = YES;
}
- (void)resumeRendering { _mtkView.paused = NO; }

@end
