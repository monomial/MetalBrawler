#import "GameViewController.h"
#import <MetalKit/MetalKit.h>
#import <GameController/GameController.h>
#include "Simulation/World.h"
#include "Platform/InputState.h"

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

    // TODO T6: Siri Remote swipe delta → dead-zone + acceleration curve → InputState.moveX/Y
    // TODO: GCController gamepad support via controllerDidConnectNotification
}

@end
