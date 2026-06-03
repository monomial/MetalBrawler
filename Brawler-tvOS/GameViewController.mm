#import "GameViewController.h"
#import <MetalKit/MetalKit.h>
#import <GameController/GameController.h>
#include "Simulation/World.h"
#include "Platform/InputState.h"
#include "Platform/SiriRemoteInput.h"

// tvOS input: Siri Remote swipe delta → dead-zone + acceleration curve → InputState.
// GCController events for MFi gamepads handled via GCController.controllerDidConnectNotification.

@interface BrawlerDelegate_tvOS : NSObject <MTKViewDelegate>
- (instancetype)initWithDevice:(id<MTLDevice>)device;
@end

@implementation BrawlerDelegate_tvOS {
    World              _world;
    CFTimeInterval     _lastTime;
    id<MTLCommandQueue> _commandQueue;
    InputState         _currentInput;
}

- (instancetype)initWithDevice:(id<MTLDevice>)device {
    self = [super init];
    if (self) {
        _commandQueue = [device newCommandQueue];
        _lastTime = CACurrentMediaTime();
        _currentInput = {};
    }
    return self;
}

- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {}

- (void)drawInMTKView:(MTKView *)view {
    CFTimeInterval now = CACurrentMediaTime();
    float physicalDt = (float)(now - _lastTime);
    _lastTime = now;
    if (physicalDt > 0.1f) physicalDt = 0.1f;

    float gameDt = physicalDt;
    _world.set_input(_currentInput);
    _world.update(physicalDt, gameDt);

    id<MTLCommandBuffer> cmd = [_commandQueue commandBuffer];
    MTLRenderPassDescriptor *rpd = view.currentRenderPassDescriptor;
    if (rpd) {
        rpd.colorAttachments[0].clearColor = MTLClearColorMake(0.05, 0.05, 0.10, 1.0);
        rpd.colorAttachments[0].loadAction  = MTLLoadActionClear;
        rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLRenderCommandEncoder> enc = [cmd renderCommandEncoderWithDescriptor:rpd];
        [enc endEncoding];
    }
    [cmd presentDrawable:view.currentDrawable];
    [cmd commit];
}

- (void)_controllerConnected:(NSNotification *)note {
    GCController *ctrl = note.object;
    if (!ctrl) return;

    // Siri Remote (micro-gamepad) — swipe delta input.
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
        return;
    }

    // MFi extended gamepad — left thumbstick.
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
    }
}

@end

@implementation GameViewController {
    MTKView              *_mtkView;
    BrawlerDelegate_tvOS *_delegate;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    _mtkView = [[MTKView alloc] initWithFrame:self.view.bounds device:device];
    _mtkView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _mtkView.colorPixelFormat = MTLPixelFormatBGRA8Unorm;
    _mtkView.depthStencilPixelFormat = MTLPixelFormatDepth32Float;
    [self.view addSubview:_mtkView];

    _delegate = [[BrawlerDelegate_tvOS alloc] initWithDevice:device];
    _mtkView.delegate = _delegate;

    // T6: Siri Remote swipe delta → dead-zone + acceleration curve → InputState.
    [[NSNotificationCenter defaultCenter]
        addObserver:_delegate
           selector:@selector(_controllerConnected:)
               name:GCControllerDidConnectNotification
             object:nil];
    [GCController startWirelessControllerDiscoveryWithCompletionHandler:nil];
}

@end
