// Raiders' spatial upscaler uses a 372-HMMA network. On hosts without the
// original tensor instruction, the reference shader expands it into scalar
// shuffles and half arithmetic. MetalFX is an optional native reconstruction
// of the same color image; it does not replace geometry, lighting or the HUD.
#if TARGET_OS_OSX
@interface NvGameScale : NSObject {
@public
    id<MTL4FXSpatialScaler> fx;
    id<MTLFence> fence;
    NSUInteger shape[4];
}
@end
@implementation NvGameScale @end

static int game_scale_enabled(void) {
    static int on = -1;
    if (on < 0) { const char *e = getenv("DM_GAME_UPSCALER"); on = e && !strcmp(e, "metalfx"); }
    return on;
}

static int game_scale_shape(id<MTLTexture> input, id<MTLTexture> output, const uint32_t root[18], uint64_t valid, NSUInteger shape[4]) {
    if ((valid & 0x3ffff) != 0x3ffff || !input || !output || input == output ||
        input.textureType != MTLTextureType2D || output.textureType != MTLTextureType2D ||
        input.sampleCount != 1 || output.sampleCount != 1 ||
        input.pixelFormat != MTLPixelFormatRGB10A2Unorm || output.pixelFormat != MTLPixelFormatRGB10A2Unorm ||
        output.storageMode != MTLStorageModePrivate || root[0] || root[1] || root[4] || root[5]) return 0;
    // The first two root vectors are source/destination origin and inclusive
    // maximum coordinates. Restrict the initial path to complete output images.
    uint64_t iw = (uint64_t)root[2] + 1, ih = (uint64_t)root[3] + 1;
    uint64_t ow = (uint64_t)root[6] + 1, oh = (uint64_t)root[7] + 1;
    if (iw < 16 || ih < 16 || iw > input.width || ih > input.height ||
        ow != output.width || oh != output.height || ow <= iw || oh <= ih || ow > 8192 || oh > 8192) return 0;
    if (fabs((double)ow / iw - (double)oh / ih) > .01) return 0;
    // This shader reconstructs 3:2 tiles; a rounded source width (1707 for
    // 2560 output pixels) can differ by one in the integer cross product.
    if (llabs((long long)(2 * ow) - (long long)(3 * iw)) > 1 ||
        llabs((long long)(2 * oh) - (long long)(3 * ih)) > 1) return 0;
    shape[0] = input.width; shape[1] = input.height; shape[2] = ow; shape[3] = oh;
    return 1;
}

static int game_scale_full_dispatch(const p_dispatch *dispatch, const uint32_t root[18]) {
    // The original workgroup advances 64 source columns and 32 source rows.
    // A partial or indirect dispatch must retain the original shader.
    return !dispatch->ind && dispatch->z == 1 &&
        dispatch->x == ((uint64_t)root[2] + 64) / 64 &&
        dispatch->y == ((uint64_t)root[3] + 32) / 32;
}

static NvGameScale *game_scale_make(const NSUInteger shape[4]) {
    if (![MTLFXSpatialScalerDescriptor supportsMetal4FX:g_dev]) return nil;
    static id<MTL4Compiler> compiler;
    if (!compiler) compiler = [g_dev newCompilerWithDescriptor:[MTL4CompilerDescriptor new] error:nil];
    if (!compiler) return nil;
    MTLFXSpatialScalerDescriptor *d = [MTLFXSpatialScalerDescriptor new];
    d.inputWidth = shape[0]; d.inputHeight = shape[1]; d.outputWidth = shape[2]; d.outputHeight = shape[3];
    d.colorTextureFormat = d.outputTextureFormat = MTLPixelFormatRGB10A2Unorm;
    d.colorProcessingMode = MTLFXSpatialScalerColorProcessingModePerceptual;
    NvGameScale *s = [NvGameScale new];
    s->fx = [d newSpatialScalerWithDevice:g_dev compiler:compiler]; s->fence = [g_dev newFence];
    if (!s->fx || !s->fence) return nil;
    memcpy(s->shape, shape, sizeof s->shape); s->fx.fence = s->fence;
    return s;
}

static int game_scale_encode(id<MTL4CommandBuffer> cb, id<MTLTexture> input, id<MTLTexture> output,
                             const uint32_t root[18], uint64_t valid) {
    NSUInteger shape[4]; if (!game_scale_shape(input, output, root, valid, shape)) return 0;
    // MetalFX records its texture bindings at encode time. The main queue is
    // ordered, and a fence bridges the renderer's untracked resource barriers.
    static NvGameScale *cache[8]; static unsigned replace;
    NvGameScale *s = nil;
    for (unsigned i = 0; i < 8; i++) if (cache[i] && !memcmp(cache[i]->shape, shape, sizeof shape)) { s = cache[i]; break; }
    if (!s) {
        s = game_scale_make(shape); if (!s) return 0;
        unsigned i = replace++ % 8; if (cache[i]) defer_obj_unref(cache[i]); cache[i] = s;
        MLOG("MetalFX game scaling: input storage %lux%lu, valid %ux%u -> %lux%lu RGB10A2", shape[0], shape[1], root[2] + 1, root[3] + 1, shape[2], shape[3]);
    }
    if ((input.usage & s->fx.colorTextureUsage) != s->fx.colorTextureUsage ||
        (output.usage & s->fx.outputTextureUsage) != s->fx.outputTextureUsage) return 0;
    s->fx.colorTexture = input; s->fx.outputTexture = output;
    s->fx.inputContentWidth = root[2] + 1; s->fx.inputContentHeight = root[3] + 1;
    id<MTL4ComputeCommandEncoder> before = [cb computeCommandEncoder];
    [before barrierAfterQueueStages:MTLStageAll beforeStages:MTLStageAll visibilityOptions:MTL4VisibilityOptionDevice];
    [before updateFence:s->fence afterEncoderStages:MTLStageDispatch | MTLStageBlit];
    m4_end(before);
    [s->fx encodeToCommandBuffer:cb];
    id<MTL4ComputeCommandEncoder> after = [cb computeCommandEncoder];
    [after waitForFence:s->fence beforeEncoderStages:MTLStageDispatch | MTLStageBlit];
    m4_end(after);
    return 1;
}

static int game_scale_dispatch(NvShader *shader, const p_dispatch *dispatch) {
    if (DM_GAME_PROGRAM_ID != 0x0400380020056000ull || strcmp(shader->key, "77f5e1708cc76abe_b")) return 0;
    static int audit = -1;
    if (audit < 0) audit = getenv("DM_NVN_UPSCALE_AUDIT") != NULL;
    if (!game_scale_enabled() && !audit) return 0;
    pthread_mutex_lock(&g_rmu);
    id<MTLTexture> input = tex_by_id((int)(S.tex[5][0] & 0xfffff));
    id<MTLTexture> output = tex_by_id((int)(S.img[5][1] & 0xfffff));
    pthread_mutex_unlock(&g_rmu);
    uint32_t root[18]; memcpy(root, S.root_constants[1][0], sizeof root);
    if (audit) {
        static uint32_t previous[18]; static int seen;
        if (!seen || memcmp(previous, root, sizeof root)) {
            seen = 1; memcpy(previous, root, sizeof root);
            MLOG("upscale audit F%llu: source %lux%lu format%lu usage%lu -> target %lux%lu format%lu usage%lu storage%lu; dispatch %d,%d,%d indirect%llu; input %u,%u %u,%u output %u,%u %u,%u; valid%llx",
                (unsigned long long)atomic_load(&g_cur_frame), input.width, input.height, input.pixelFormat, input.usage,
                output.width, output.height, output.pixelFormat, output.usage, output.storageMode, dispatch->x, dispatch->y, dispatch->z,
                (unsigned long long)dispatch->ind, root[0], root[1], root[2], root[3], root[4], root[5], root[6], root[7], (unsigned long long)S.root_valid[1][0]);
        }
    }
    if (!game_scale_enabled() || !game_scale_full_dispatch(dispatch, root)) return 0;
    NSUInteger shape[4]; if (!game_scale_shape(input, output, root, S.root_valid[1][0], shape)) return 0;
    rp_end(); if (g_blit) { enc_b_end(g_blit); g_blit = nil; }
    int encoded = game_scale_encode(g_cb, input, output, root, S.root_valid[1][0]);
    if (encoded) args_dirty_all();
    return encoded;
}
#else
static int game_scale_dispatch(NvShader *shader, const p_dispatch *dispatch) { (void)shader; (void)dispatch; return 0; }
#endif
