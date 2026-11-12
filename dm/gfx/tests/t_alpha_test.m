// Exercise recorded NVN state through real Metal fragment/color/depth writes.
#define nvn_game_fps nvn_game_fps_mtl_default
#include "../nvn/nvn_mtl.m"
#undef nvn_game_fps
#define g_ft nvn_flushed_textures
#include "../nvn/hle_nvn.c"
#undef g_ft
uint64_t g_t0_ns;
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { return NULL; }
module_t g_mod[MAX_MOD]; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
int dm_guest_as_contains(uintptr_t p) { return 0; }
#define CHECK(x) do { if (!(x)) { fprintf(stderr,"FAIL line %d: %s (%s)\n",__LINE__,#x,error.localizedDescription.UTF8String); return 1; } } while (0)

int main(int argc, char **argv) { @autoreleasepool {
    NSError *error = nil; CHECK(argc == 2); mtl_init(); state_reset();
    NSString *source = [NSString stringWithContentsOfFile:@(argv[1]) encoding:NSUTF8StringEncoding error:&error]; CHECK(source);
    MTLCompileOptions *options = [MTLCompileOptions new]; options.fastMathEnabled = NO;
    id<MTLLibrary> lib = [g_dev newLibraryWithSource:source options:options error:&error]; CHECK(lib);
    NvShader *fs = [NvShader new], *vs = [NvShader new];
    fs->color_lib = lib; fs->color_entry = @"main0"; fs->color_mask = 3; fs->alpha_test = 1;
    vs->fn = [lib newFunctionWithName:@"triangle"]; vs->varying_outputs = 0;
    const float values[] = {-1, -0.0f, 0, .25f, .5f, .75f, 1, NAN};
    const float references[] = {0, .5f, 1, -.5f, 2, NAN};
    id<MTLCommandQueue> queue = [g_dev newCommandQueue];
    MTLDepthStencilDescriptor *dd = [MTLDepthStencilDescriptor new]; dd.depthCompareFunction = MTLCompareFunctionAlways; dd.depthWriteEnabled = YES;
    id<MTLDepthStencilState> ds = [g_dev newDepthStencilStateWithDescriptor:dd];
    id<MTLTexture> targets[3];
    for (unsigned i = 0; i < 3; i++) {
        MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:i < 2 ? MTLPixelFormatRGBA32Float : MTLPixelFormatDepth32Float width:8 height:1 mipmapped:NO];
        d.usage = MTLTextureUsageRenderTarget; d.storageMode = MTLStorageModeShared;
        targets[i] = [g_dev newTextureWithDescriptor:d]; CHECK(targets[i]);
    }
    unsigned checks = 0;
    for (unsigned func = 1; func <= 8; func++) for (unsigned ref = 0; ref < sizeof references / sizeof *references; ref++) { @autoreleasepool {
        uint8_t memory[512]; pool_t pool = {.mem=memory}; NVNcommandBuffer cbn;
        NVNcolorState color; h_nvnColorStateSetDefaults(&color);
        CHECK(h_nvnColorStateGetAlphaTest(&color) == NVN_ALPHA_FUNC_ALWAYS);
        h_nvnColorStateSetAlphaTest(&color, (NVNalphaFunc)func);
        CHECK(h_nvnColorStateGetAlphaTest(&color) == func);
        h_nvnCommandBufferInitialize(&cbn, NULL);
        h_nvnCommandBufferAddCommandMemory(&cbn, (NVNmemoryPool *)&pool, 0, sizeof memory);
        h_nvnCommandBufferBeginRecording(&cbn);
        h_nvnCommandBufferBindColorState(&cbn, &color);
        h_nvnCommandBufferSetAlphaRef(&cbn, references[ref]);
        NVNcommandHandle commands = h_nvnCommandBufferEndRecording(&cbn);
        memset(&color, 0, sizeof color); // recording retains the original state
        mtl_exec((const uint8_t *)commands);
        CHECK(S.color.alpha_func == func);
        CHECK(!memcmp(&S.alpha_ref, &references[ref], sizeof(float)));
        uint32_t formats[8] = {MTLPixelFormatRGBA32Float, MTLPixelFormatRGBA32Float};
        pso_key key; pso_key_fill(&key, vs, fs, formats, MTLPixelFormatDepth32Float, 0, 1, 0);
        MTLRenderPipelineDescriptor *pd = pso_desc(&key, vs, fs, nil, 0);
        CHECK(pd && pd.fragmentFunction);
        id<MTLRenderPipelineState> pipeline = [g_dev newRenderPipelineStateWithDescriptor:pd error:&error]; CHECK(pipeline);
        MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
        for (unsigned i = 0; i < 2; i++) {
            pass.colorAttachments[i].texture = targets[i]; pass.colorAttachments[i].loadAction = MTLLoadActionClear;
            pass.colorAttachments[i].storeAction = MTLStoreActionStore; pass.colorAttachments[i].clearColor = MTLClearColorMake(.125, .125, .125, .125);
        }
        pass.depthAttachment.texture = targets[2]; pass.depthAttachment.loadAction = MTLLoadActionClear;
        pass.depthAttachment.storeAction = MTLStoreActionStore; pass.depthAttachment.clearDepth = 1;
        id<MTLCommandBuffer> cb = [queue commandBuffer]; id<MTLRenderCommandEncoder> en = [cb renderCommandEncoderWithDescriptor:pass];
        [en setRenderPipelineState:pipeline]; [en setDepthStencilState:ds];
        [en drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [en endEncoding]; [cb commit]; [cb waitUntilCompleted]; CHECK(!cb.error);
        float color0[32], color1[32], depth[8];
        [targets[0] getBytes:color0 bytesPerRow:128 fromRegion:MTLRegionMake2D(0, 0, 8, 1) mipmapLevel:0];
        [targets[1] getBytes:color1 bytesPerRow:128 fromRegion:MTLRegionMake2D(0, 0, 8, 1) mipmapLevel:0];
        [targets[2] getBytes:depth bytesPerRow:32 fromRegion:MTLRegionMake2D(0, 0, 8, 1) mipmapLevel:0];
        for (unsigned pixel = 0; pixel < 8; pixel++) {
            float a = values[pixel], b = references[ref];
            // Truth is derived from the NVN compare enum, independently of the
            // generated epilogue; all comparisons are ordered (NaN fails).
            bool conditions[] = {false, a < b, a == b, a <= b, a > b,
                                 !isnan(a) && !isnan(b) && a != b, a >= b, true};
            bool writes = conditions[func - 1];
            CHECK(depth[pixel] == (writes ? .25f : 1));
            float want0[4] = {.25f, .5f, .75f, a}, want1[4] = {1, 0, 1, 1};
            for (unsigned channel = 0; channel < 4; channel++) {
                float expected0 = writes ? want0[channel] : .125f, expected1 = writes ? want1[channel] : .125f;
                CHECK(color0[pixel * 4 + channel] == expected0 || (isnan(color0[pixel * 4 + channel]) && isnan(expected0)));
                CHECK(color1[pixel * 4 + channel] == expected1); checks += 2;
            }
            checks++;
        }
        h_nvnCommandBufferFinalize(&cbn);
    } }
    printf("PASS 48 recorded alpha-test cases, %u color/depth values; all comparisons, equality, signed zero, NaN, state changes and both returns\n", checks);
    return 0;
} }
