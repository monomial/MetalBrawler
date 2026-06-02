#import "GameViewController.h"
#import <MetalKit/MetalKit.h>
#include "Simulation/World.h"
#include "Platform/InputState.h"

// MTKViewDelegate bridge — owns the World and drives the game loop.
@interface BrawlerDelegate : NSObject <MTKViewDelegate>
- (instancetype)initWithDevice:(id<MTLDevice>)device;
@end

@implementation BrawlerDelegate {
    World        _world;
    CFTimeInterval _lastTime;
    id<MTLCommandQueue> _commandQueue;
}

- (instancetype)initWithDevice:(id<MTLDevice>)device {
    self = [super init];
    if (self) {
        _commandQueue = [device newCommandQueue];
        _lastTime = CACurrentMediaTime();
    }
    return self;
}

- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {}

- (void)drawInMTKView:(MTKView *)view {
    CFTimeInterval now = CACurrentMediaTime();
    float physicalDt = (float)(now - _lastTime);
    _lastTime = now;
    if (physicalDt > 0.1f) physicalDt = 0.1f; // clamp spiral-of-death

    // TODO: HitStopSystem will scale gameDt. For now they're the same.
    float gameDt = physicalDt;
    _world.update(physicalDt, gameDt);

    id<MTLCommandBuffer> cmd = [_commandQueue commandBuffer];
    MTLRenderPassDescriptor *rpd = view.currentRenderPassDescriptor;
    if (rpd) {
        rpd.colorAttachments[0].clearColor = MTLClearColorMake(0.05, 0.05, 0.10, 1.0);
        rpd.colorAttachments[0].loadAction  = MTLLoadActionClear;
        rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLRenderCommandEncoder> enc = [cmd renderCommandEncoderWithDescriptor:rpd];
        // TODO: RenderSystem draws here
        [enc endEncoding];
    }
    [cmd presentDrawable:view.currentDrawable];
    [cmd commit];
}

@end

@implementation GameViewController {
    MTKView         *_mtkView;
    BrawlerDelegate *_delegate;
}

- (void)loadView {
    _mtkView = [[MTKView alloc] initWithFrame:NSMakeRect(0, 0, 960, 720)
                                       device:MTLCreateSystemDefaultDevice()];
    _mtkView.colorPixelFormat = MTLPixelFormatBGRA8Unorm;
    _mtkView.depthStencilPixelFormat = MTLPixelFormatDepth32Float;
    self.view = _mtkView;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    _delegate = [[BrawlerDelegate alloc] initWithDevice:_mtkView.device];
    _mtkView.delegate = _delegate;
}

@end
