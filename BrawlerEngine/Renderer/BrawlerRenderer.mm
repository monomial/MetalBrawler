#import "BrawlerRenderer.h"
#import <simd/simd.h>
#include "Simulation/World.h"
#include "Simulation/RoomBounds.h"
#include "Assets/CharacterLoader.h"

typedef struct { simd_float4x4 mvp; simd_float4 color; } DrawUniforms;
typedef struct { simd_float4x4 mvp; simd_float4 color; } SkinnedUniforms;

// Auto-scale: characters should be ~150 game units tall.
// Computed from meshHeight at runtime; this is the fallback.
static const float kTargetCharHeight = 150.0f;

// Builds the model matrix for a character at game position (x, y).
// scale:       uniform world scale
// yMin:        lowest Y vertex in model space — shifted to Z=0 so feet touch the floor.
// facingAngle: atan2(vy,vx) of movement direction. Default facing (no rotation) is -Y
//              (toward camera); offset of +π/2 aligns atan2 with the character's front.
// Rx(+90°) rotates the FBX/USDZ Y-up character to the game's Z-up convention.
static simd_float4x4 make_char_model(float x, float y, float scale, float yMin, float facingAngle) {
    simd_float4x4 Rx = matrix_identity_float4x4;
    Rx.columns[1] = (simd_float4){ 0.f,  0.f, 1.f, 0.f};
    Rx.columns[2] = (simd_float4){ 0.f, -1.f, 0.f, 0.f};
    // Translate model up so feet (yMin) land on Z=0 after rotation.
    simd_float4x4 Tfoot = matrix_identity_float4x4;
    Tfoot.columns[3].y = -yMin;
    // Rotate around game Z-axis to face movement direction.
    float theta = facingAngle + (float)M_PI_2;
    float c = cosf(theta), s = sinf(theta);
    simd_float4x4 Rz = matrix_identity_float4x4;
    Rz.columns[0] = (simd_float4){ c, s, 0.f, 0.f};
    Rz.columns[1] = (simd_float4){-s, c, 0.f, 0.f};
    simd_float4x4 S = matrix_identity_float4x4;
    S.columns[0].x = scale; S.columns[1].y = scale; S.columns[2].z = scale;
    simd_float4x4 T = matrix_identity_float4x4;
    T.columns[3] = (simd_float4){x, y, 0.f, 1.f};
    return simd_mul(T, simd_mul(S, simd_mul(Rz, simd_mul(Rx, Tfoot))));
}

// Triple-buffered bone matrix storage: kMaxBones float4x4 per entity slot, 3 frames.
static const int kMaxAnimEntities = 64;
static const NSUInteger kBoneMatStride = kMaxBones * 16 * sizeof(float); // 4096 B

static const simd_float3 kQuadVerts[6] = {
    {-0.5f,-0.5f,0.f},{ 0.5f,-0.5f,0.f},{-0.5f, 0.5f,0.f},
    { 0.5f,-0.5f,0.f},{ 0.5f, 0.5f,0.f},{-0.5f, 0.5f,0.f},
};

static const float kEntitySize = 40.0f;
static const float kCamDist    = 800.0f;
static const float kCamPitch   = 55.0f * ((float)M_PI / 180.0f);
static const float kFOVY       = 70.0f * ((float)M_PI / 180.0f);
static const float kNear       = 1.0f;
static const float kFar        = 3000.0f;

static simd_float4x4 make_perspective(float fovY, float aspect, float n, float f) {
    float t = 1.f / tanf(fovY * .5f);
    simd_float4x4 m = {};
    m.columns[0].x = t / aspect;  m.columns[1].y = t;
    m.columns[2].z = f/(n-f);     m.columns[2].w = -1.f;
    m.columns[3].z = n*f/(n-f);
    return m;
}

static simd_float4x4 make_look_at(simd_float3 eye, simd_float3 tgt, simd_float3 up) {
    simd_float3 f = simd_normalize(tgt-eye);
    simd_float3 r = simd_normalize(simd_cross(f,up));
    simd_float3 u = simd_cross(r,f);
    simd_float4x4 m;
    m.columns[0]=(simd_float4){r.x,u.x,-f.x,0};
    m.columns[1]=(simd_float4){r.y,u.y,-f.y,0};
    m.columns[2]=(simd_float4){r.z,u.z,-f.z,0};
    m.columns[3]=(simd_float4){-simd_dot(r,eye),-simd_dot(u,eye),simd_dot(f,eye),1};
    return m;
}

static simd_float4x4 make_model(float x, float y, float s) {
    simd_float4x4 m = matrix_identity_float4x4;
    m.columns[0].x = s; m.columns[1].y = s; m.columns[2].z = s;
    m.columns[3] = (simd_float4){x,y,0.f,1.f};
    return m;
}

// Non-uniform scale — used for floor quad and wall strips.
static simd_float4x4 make_model_rect(float x, float y, float z, float w, float h) {
    simd_float4x4 m = matrix_identity_float4x4;
    m.columns[0].x = w; m.columns[1].y = h; m.columns[2].z = 1.f;
    m.columns[3] = (simd_float4){x, y, z, 1.f};
    return m;
}

static float clampf(float v, float lo, float hi) {
    return v < lo ? lo : (v > hi ? hi : v);
}

@implementation BrawlerRenderer {
    id<MTLRenderPipelineState> _pipeline;        // flat-color quads
    id<MTLRenderPipelineState> _skinnedPipeline; // skinned meshes
    id<MTLDepthStencilState>   _depthState;
    id<MTLDepthStencilState>   _noDepthState;   // for 2D HUD overlay
    id<MTLSamplerState>        _linearSampler;
    id<MTLBuffer>              _quadVB;
    id<MTLBuffer>              _boneBuf[3];      // triple-buffered bone matrices
    id<MTLTexture>             _whiteTexture;    // 1×1 white fallback when no diffuse
    int                        _frameIdx;
    simd_float4x4              _proj;

    LoadedCharacter* _playerChar;
    LoadedCharacter* _enemyChar;
    float            _facingAngle[kMaxAnimEntities]; // per-entity last known facing (atan2 radians)
}

- (instancetype)initWithDevice:(id<MTLDevice>)device pixelFormat:(MTLPixelFormat)pfmt {
    self = [super init];
    if (!self) return nil;

    _quadVB   = [device newBufferWithBytes:kQuadVerts length:sizeof(kQuadVerts)
                                   options:MTLResourceStorageModeShared];
    _proj     = matrix_identity_float4x4;
    _frameIdx = 0;
    // Default facing: π/2 = characters face +Y (up the screen) until first movement.
    for (int i = 0; i < kMaxAnimEntities; i++) _facingAngle[i] = (float)M_PI_2;

    NSUInteger boneBufSize = kBoneMatStride * kMaxAnimEntities;
    for (int i = 0; i < 3; i++)
        _boneBuf[i] = [device newBufferWithLength:boneBufSize
                                          options:MTLResourceStorageModeShared];

    id<MTLLibrary> lib = [device newDefaultLibrary];
    if (!lib) { NSLog(@"BrawlerRenderer: no default Metal library"); return nil; }

    NSError *err = nil;

    // Flat-color quad pipeline
    {
        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
        pd.vertexFunction   = [lib newFunctionWithName:@"vertex_main"];
        pd.fragmentFunction = [lib newFunctionWithName:@"fragment_main"];
        pd.colorAttachments[0].pixelFormat = pfmt;
        pd.depthAttachmentPixelFormat      = MTLPixelFormatDepth32Float;
        MTLVertexDescriptor *vd = [MTLVertexDescriptor new];
        vd.attributes[0].format = MTLVertexFormatFloat3;
        vd.attributes[0].offset = 0; vd.attributes[0].bufferIndex = 0;
        vd.layouts[0].stride    = sizeof(simd_float3);
        pd.vertexDescriptor = vd;
        _pipeline = [device newRenderPipelineStateWithDescriptor:pd error:&err];
        if (!_pipeline) { NSLog(@"Flat pipeline: %@", err); return nil; }
    }

    // Skinned mesh pipeline
    {
        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
        pd.vertexFunction   = [lib newFunctionWithName:@"skinned_vertex_main"];
        pd.fragmentFunction = [lib newFunctionWithName:@"skinned_fragment_main"];
        pd.colorAttachments[0].pixelFormat = pfmt;
        pd.depthAttachmentPixelFormat      = MTLPixelFormatDepth32Float;

        MTLVertexDescriptor *vd = [MTLVertexDescriptor new];
        // Must match CharacterLoader.mm skinnedVertexDescriptor() layout
        vd.attributes[0].format = MTLVertexFormatFloat3;   // position
        vd.attributes[0].offset = 0;  vd.attributes[0].bufferIndex = 0;
        vd.attributes[1].format = MTLVertexFormatFloat3;   // normal
        vd.attributes[1].offset = 12; vd.attributes[1].bufferIndex = 0;
        vd.attributes[2].format = MTLVertexFormatFloat2;   // texcoord
        vd.attributes[2].offset = 24; vd.attributes[2].bufferIndex = 0;
        vd.attributes[3].format = MTLVertexFormatUShort4;  // joint indices
        vd.attributes[3].offset = 32; vd.attributes[3].bufferIndex = 0;
        vd.attributes[4].format = MTLVertexFormatFloat4;   // joint weights
        vd.attributes[4].offset = 40; vd.attributes[4].bufferIndex = 0;
        vd.layouts[0].stride    = 56;
        vd.layouts[0].stepFunction = MTLVertexStepFunctionPerVertex;
        pd.vertexDescriptor = vd;

        _skinnedPipeline = [device newRenderPipelineStateWithDescriptor:pd error:&err];
        if (!_skinnedPipeline)
            NSLog(@"Skinned pipeline failed (skinned_vertex_main not found?): %@", err);
    }

    MTLDepthStencilDescriptor *dd = [MTLDepthStencilDescriptor new];
    dd.depthCompareFunction = MTLCompareFunctionLess;
    dd.depthWriteEnabled    = YES;
    _depthState = [device newDepthStencilStateWithDescriptor:dd];

    MTLDepthStencilDescriptor *dd2 = [MTLDepthStencilDescriptor new];
    dd2.depthCompareFunction = MTLCompareFunctionAlways;
    dd2.depthWriteEnabled    = NO;
    _noDepthState = [device newDepthStencilStateWithDescriptor:dd2];

    // Linear sampler for character textures
    MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
    sd.minFilter     = MTLSamplerMinMagFilterLinear;
    sd.magFilter     = MTLSamplerMinMagFilterLinear;
    sd.mipFilter     = MTLSamplerMipFilterLinear;
    sd.sAddressMode  = MTLSamplerAddressModeClampToEdge;
    sd.tAddressMode  = MTLSamplerAddressModeClampToEdge;
    _linearSampler   = [device newSamplerStateWithDescriptor:sd];

    // 1×1 white fallback texture — used when character has no diffuse texture
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                  width:1 height:1
                                                                              mipmapped:NO];
    _whiteTexture = [device newTextureWithDescriptor:td];
    uint32_t white = 0xFFFFFFFF;
    [_whiteTexture replaceRegion:MTLRegionMake2D(0,0,1,1) mipmapLevel:0 withBytes:&white bytesPerRow:4];

    return self;
}

- (void)setPlayerCharacter:(LoadedCharacter*)player enemyCharacter:(LoadedCharacter*)enemy {
    _playerChar = player;
    _enemyChar  = enemy;
}

- (void)updateDrawableSize:(CGSize)size {
    if (size.width > 0 && size.height > 0)
        _proj = make_perspective(kFOVY, (float)size.width/(float)size.height, kNear, kFar);
}

- (void)drawWorld:(World*)world inView:(MTKView*)view commandBuffer:(id<MTLCommandBuffer>)cmd {
    MTLRenderPassDescriptor *rpd = view.currentRenderPassDescriptor;
    if (!rpd || !view.currentDrawable) return;

    // Camera follows player, clamped to room so void is never visible.
    simd_float3 target = {kCameraDefaultTargetX, kCameraDefaultTargetY, 0};
    for (EntityID id = 0; id < world->entity_count(); ++id) {
        if (world->player_tags().present(id) && world->has_component<PositionComponent>(id)) {
            auto& p = world->get_component<PositionComponent>(id);
            target = {p.x, p.y, 0};
            break;
        }
    }
    // Clamp camera target so the view frustum stays within room bounds.
    // Padding ≈ half visible ground width at the camera's pitch & FOV.
    static const float kCamPadX = 320.f;
    static const float kCamPadY = 220.f;
    target.x = clampf(target.x, kRoomMinX + kCamPadX, kRoomMaxX - kCamPadX);
    target.y = clampf(target.y, kRoomMinY + kCamPadY, kRoomMaxY - kCamPadY);

    simd_float3 eye = { target.x,
                        target.y - kCamDist * cosf(kCamPitch),
                        kCamDist  * sinf(kCamPitch) };
    simd_float4x4 vp = simd_mul(_proj, make_look_at(eye, target, (simd_float3){0,0,1}));

    rpd.colorAttachments[0].clearColor  = MTLClearColorMake(0.08,0.08,0.12,1);
    rpd.colorAttachments[0].loadAction  = MTLLoadActionClear;
    rpd.colorAttachments[0].storeAction = MTLStoreActionStore;

    id<MTLRenderCommandEncoder> enc = [cmd renderCommandEncoderWithDescriptor:rpd];
    [enc setRenderPipelineState:_pipeline];
    [enc setDepthStencilState:_depthState];
    [enc setVertexBuffer:_quadVB offset:0 atIndex:0];

    // Floor quad — drawn first at Z=-1 so entities render on top.
    {
        DrawUniforms u;
        u.mvp   = simd_mul(vp, make_model_rect(kRoomCenterX, kRoomCenterY, -1.f,
                                               kRoomWidth, kRoomHeight));
        u.color = (simd_float4){0.13f, 0.13f, 0.18f, 1.f}; // slightly lighter than clear
        [enc setVertexBytes:&u length:sizeof(u) atIndex:1];
        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
    }

    // Wall outlines — thin quads along each boundary edge, at Z=0.
    static const simd_float4 kWallColor = {0.30f, 0.30f, 0.40f, 1.f};
    static const float kWallThick = 20.f;
    struct { float cx,cy,w,h; } walls[4] = {
        {kRoomCenterX, kRoomMinY + kWallThick*0.5f, kRoomWidth, kWallThick}, // bottom
        {kRoomCenterX, kRoomMaxY - kWallThick*0.5f, kRoomWidth, kWallThick}, // top
        {kRoomMinX + kWallThick*0.5f, kRoomCenterY, kWallThick, kRoomHeight}, // left
        {kRoomMaxX - kWallThick*0.5f, kRoomCenterY, kWallThick, kRoomHeight}, // right
    };
    for (auto& w : walls) {
        DrawUniforms u;
        u.mvp   = simd_mul(vp, make_model_rect(w.cx, w.cy, 0.f, w.w, w.h));
        u.color = kWallColor;
        [enc setVertexBytes:&u length:sizeof(u) atIndex:1];
        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
    }

    _frameIdx = (_frameIdx + 1) % 3;

    for (EntityID eid = 0; eid < world->entity_count(); ++eid) {
        if (!world->has_component<PositionComponent>(eid)) continue;
        auto& pos = world->get_component<PositionComponent>(eid);

        simd_float4 color = {1,1,1,1};
        FactionComponent::Type faction = FactionComponent::Player;
        if (world->has_component<FactionComponent>(eid)) {
            faction = world->get_component<FactionComponent>(eid).type;
            switch (faction) {
                case FactionComponent::Player: color = {0.3f,0.7f,1.0f,1.f}; break; // blue tint
                case FactionComponent::Enemy:  color = {1.0f,0.4f,0.3f,1.f}; break; // orange-red tint
            }
        }

        // Update facing angle from velocity when the entity is actually moving.
        if (eid < kMaxAnimEntities && world->has_component<VelocityComponent>(eid)) {
            auto& vel = world->get_component<VelocityComponent>(eid);
            float speed = sqrtf(vel.vx * vel.vx + vel.vy * vel.vy);
            if (speed > 5.f)
                _facingAngle[eid] = atan2f(vel.vy, vel.vx);
        }

        LoadedCharacter* charData = (faction == FactionComponent::Player) ? _playerChar : _enemyChar;
        bool hasMesh = charData && charData->indexCount > 0 && _skinnedPipeline
                       && world->has_component<AnimationComponent>(eid);

        if (hasMesh) {
            auto& anim = world->get_component<AnimationComponent>(eid);
            NSUInteger boneOffset = (NSUInteger)eid * kBoneMatStride;
            memcpy((uint8_t*)_boneBuf[_frameIdx].contents + boneOffset,
                   anim.boneMatrices, kBoneMatStride);

            // Auto-scale from mesh bounding box so character is kTargetCharHeight game units.
            float scale = (charData->meshHeight > 0.01f)
                        ? kTargetCharHeight / charData->meshHeight
                        : 1.0f;

            [enc setRenderPipelineState:_skinnedPipeline];
            [enc setDepthStencilState:_depthState];
            [enc setVertexBuffer:charData->vertexBuffer offset:0 atIndex:0];
            [enc setVertexBuffer:_boneBuf[_frameIdx] offset:boneOffset atIndex:1];
            SkinnedUniforms su;
            float facing = (eid < kMaxAnimEntities) ? _facingAngle[eid] : (float)M_PI_2;
            su.mvp   = simd_mul(vp, make_char_model(pos.x, pos.y, scale, charData->meshYMin, facing));
            su.color = color;
            [enc setVertexBytes:&su length:sizeof(su) atIndex:2];

            id<MTLTexture> tex = charData->diffuseTexture ? charData->diffuseTexture : _whiteTexture;
            [enc setFragmentBytes:&su length:sizeof(su) atIndex:2];
            [enc setFragmentTexture:tex atIndex:0];
            [enc setFragmentSamplerState:_linearSampler atIndex:0];

            [enc drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                            indexCount:charData->indexCount
                             indexType:charData->indexType
                           indexBuffer:charData->indexBuffer
                     indexBufferOffset:0];
        } else {
            [enc setRenderPipelineState:_pipeline];
            [enc setDepthStencilState:_depthState];
            [enc setVertexBuffer:_quadVB offset:0 atIndex:0];
            DrawUniforms u;
            u.mvp   = simd_mul(vp, make_model(pos.x, pos.y, kEntitySize));
            u.color = color;
            [enc setVertexBytes:&u length:sizeof(u) atIndex:1];
            [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
        }
    }
    // -----------------------------------------------------------------------
    // World-anchored health bars — project above each character's head,
    // draw as 2D ortho overlay (no depth test, drawn on top of everything).
    // -----------------------------------------------------------------------
    {
        CGSize ds = view.drawableSize;
        float W = (float)ds.width, H = (float)ds.height;

        // Ortho: pixel (0,0) = top-left → NDC (-1,+1)
        simd_float4x4 ortho = matrix_identity_float4x4;
        ortho.columns[0].x =  2.f / W;
        ortho.columns[1].y = -2.f / H;
        ortho.columns[3]   = (simd_float4){-1.f, 1.f, 0.f, 1.f};

        [enc setRenderPipelineState:_pipeline];
        [enc setDepthStencilState:_noDepthState];
        [enc setVertexBuffer:_quadVB offset:0 atIndex:0];

        static const float kBarW     = 80.f;  // pixels
        static const float kBarH     = 10.f;  // pixels
        static const float kBarGap   = 8.f;   // pixels above projected head

        for (EntityID id = 0; id < world->entity_count(); ++id) {
            if (!world->has_component<HealthComponent>(id)) continue;
            if (!world->has_component<PositionComponent>(id)) continue;
            // Skip dying — bar is at 0 and just adds clutter during death anim.
            if (world->has_component<AnimationComponent>(id) &&
                world->get_component<AnimationComponent>(id).dying) continue;

            const auto& pos = world->get_component<PositionComponent>(id);
            const auto& hp  = world->get_component<HealthComponent>(id);

            // Project the above-head world position to screen pixels.
            simd_float4 clip = simd_mul(vp, (simd_float4){pos.x, pos.y, kTargetCharHeight, 1.f});
            if (clip.w <= 0.f) continue; // behind camera
            float ndcX  = clip.x / clip.w;
            float ndcY  = clip.y / clip.w;
            float scrX  = (ndcX + 1.f) * 0.5f * W;
            float scrY  = (1.f - ndcY) * 0.5f * H - kBarGap; // shift up by gap

            // Background
            DrawUniforms u;
            u.color = {0.08f, 0.08f, 0.10f, 1.f};
            u.mvp   = simd_mul(ortho, make_model_rect(scrX, scrY, 0.f, kBarW, kBarH));
            [enc setVertexBytes:&u length:sizeof(u) atIndex:1];
            [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];

            // Foreground fill (left-aligned)
            float fill = (hp.max > 0) ? (float)hp.current / hp.max : 0.f;
            if (fill < 0.f) fill = 0.f;
            float fw = kBarW * fill;
            if (fw > 1.f) {
                bool isPlayer = world->player_tags().present(id);
                u.color = isPlayer ? (simd_float4){0.25f, 0.65f, 1.00f, 1.f}   // blue
                                   : (simd_float4){1.00f, 0.35f, 0.20f, 1.f};  // orange-red
                u.mvp   = simd_mul(ortho, make_model_rect(scrX - kBarW * 0.5f + fw * 0.5f,
                                                          scrY, 0.f, fw, kBarH));
                [enc setVertexBytes:&u length:sizeof(u) atIndex:1];
                [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
            }
        }
    }

    [enc endEncoding];
    [cmd presentDrawable:view.currentDrawable];
}

@end
