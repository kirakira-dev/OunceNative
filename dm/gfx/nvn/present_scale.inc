// Mac presentation scaling. Work on the valid, correctly oriented SDR image;
// game render targets, simulation timing, and shader math are unchanged.
#if TARGET_OS_OSX
@interface NvPresentScale : NSObject {
@public
    id<MTLFXSpatialScaler> fx3;
    id<MTL4FXSpatialScaler> fx4;
    id<MTLTexture> input, output;
    id<MTLResidencySet> residency;
}
@end
@implementation NvPresentScale @end

static int present_scale_enabled(void) {
    static int enabled = -1;
    if (enabled < 0) {
        const char *s = getenv("DM_UPSCALER");
        enabled = s ? !strcmp(s, "metalfx") : DM_GAME_NX2;
    }
    return enabled;
}

// Return the crop dimensions and fitted output dimensions. Invalid crops are
// left to the ordinary blit path, which reports them and refuses to encode.
static int present_scale_size(id<MTLTexture> src, id<MTLTexture> dst, const int crop[4], NSUInteger size[4]) {
    NSUInteger w = src.width, h = src.height;
    if (crop && (crop[2] || crop[3])) {
        if (crop[0] < 0 || crop[1] < 0 || crop[2] <= 0 || crop[3] <= 0 ||
            (uint64_t)crop[0] + crop[2] > w || (uint64_t)crop[1] + crop[3] > h) return 0;
        w = crop[2]; h = crop[3];
    }
    if (!present_scale_enabled() || w < 16 || h < 16) return 0;
    double scale = fmin((double)dst.width / w, (double)dst.height / h);
    if (scale <= 1.0) return 0;
    size[0] = w; size[1] = h; size[2] = (NSUInteger)round(w * scale); size[3] = (NSUInteger)round(h * scale);
    if (fabs(((double)dst.width / dst.height) / ((double)w / h) - 1) < 0.01) {
        size[2] = dst.width; size[3] = dst.height;
    }
    return size[2] <= 8192 && size[3] <= 8192;
}

static NvPresentScale *present_scale_make(const NSUInteger size[4], int metal4) {
    if (metal4 ? ![MTLFXSpatialScalerDescriptor supportsMetal4FX:g_dev] : ![MTLFXSpatialScalerDescriptor supportsDevice:g_dev]) return nil;
    MTLFXSpatialScalerDescriptor *d = [MTLFXSpatialScalerDescriptor new];
    d.inputWidth = size[0]; d.inputHeight = size[1]; d.outputWidth = size[2]; d.outputHeight = size[3];
    d.colorTextureFormat = d.outputTextureFormat = MTLPixelFormatBGRA8Unorm;
    // The swapchain contains perceptual scan-out values, even when its storage
    // format is sRGB. The crop pass samples its non-sRGB view exactly once.
    d.colorProcessingMode = MTLFXSpatialScalerColorProcessingModePerceptual;
    NvPresentScale *s = [NvPresentScale new];
    if (metal4) {
        static id<MTL4Compiler> compiler;
        if (!compiler) compiler = [g_dev newCompilerWithDescriptor:[MTL4CompilerDescriptor new] error:nil];
        if (!compiler) return nil;
        s->fx4 = [d newSpatialScalerWithDevice:g_dev compiler:compiler];
    } else s->fx3 = [d newSpatialScalerWithDevice:g_dev];
    id<MTLFXSpatialScalerBase> fx = metal4 ? (id<MTLFXSpatialScalerBase>)s->fx4 : s->fx3;
    if (!fx) return nil;
    MTLTextureDescriptor *t = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:d.colorTextureFormat width:size[0] height:size[1] mipmapped:NO];
    t.storageMode = MTLStorageModePrivate;
    t.usage = fx.colorTextureUsage | MTLTextureUsageRenderTarget;
    s->input = [g_dev newTextureWithDescriptor:t];
    t.width = size[2]; t.height = size[3]; t.usage = fx.outputTextureUsage | MTLTextureUsageShaderRead;
    s->output = [g_dev newTextureWithDescriptor:t];
    if (!s->input || !s->output) return nil;
    fx.inputContentWidth = size[0]; fx.inputContentHeight = size[1];
    fx.colorTexture = s->input; fx.outputTexture = s->output;
    if (metal4) {
        s->residency = [g_dev newResidencySetWithDescriptor:[MTLResidencySetDescriptor new] error:nil];
        if (!s->residency) return nil;
        [s->residency addAllocation:s->input]; [s->residency addAllocation:s->output]; [s->residency commit];
    }
    MLOG("MetalFX spatial presentation %lux%lu -> %lux%lu (Metal %d)", size[0], size[1], size[2], size[3], metal4 ? 4 : 3);
    return s;
}

static int present_scale_matches(NvPresentScale *s, const NSUInteger size[4]) {
    return s && s->input.width == size[0] && s->input.height == size[1] &&
        s->output.width == size[2] && s->output.height == size[3];
}
#endif

static int present_encode(id<MTLCommandBuffer> cb, id<MTLTexture> src, id<MTLTexture> dst, const int crop[4]) {
    int flip = atomic_load_explicit(&g_origin_ll, memory_order_relaxed);
#if TARGET_OS_OSX
    NSUInteger size[4];
    if (present_scale_size(src, dst, crop, size)) {
        static NvPresentScale *cached;
        if (!present_scale_matches(cached, size)) cached = present_scale_make(size, 0);
        NvPresentScale *s = cached;
        if (s && present_blit(cb, src, s->input, crop, flip)) {
            [s->fx3 encodeToCommandBuffer:cb];
            // Screenshots may finish asynchronously after a resize replaces the
            // cache. Keep this scaler and its textures through GPU completion.
            [cb addCompletedHandler:^(id<MTLCommandBuffer> done) { (void)done; (void)s; }];
            return present_blit(cb, s->output, dst, NULL, 0);
        }
    }
#endif
    return present_blit(cb, src, dst, crop, flip);
}

static int present_encode_m4(id<MTL4CommandBuffer> cb, id<MTLTexture> src, id<MTLTexture> dst, const int crop[4], int uv_i) {
    int flip = atomic_load_explicit(&g_origin_ll, memory_order_relaxed);
#if TARGET_OS_OSX
    NSUInteger size[4];
    if (present_scale_size(src, dst, crop, size)) {
        // present_now waits for this slot's prior completion before reuse. A
        // resize can therefore replace it without releasing in-flight resources.
        static __strong NvPresentScale *slots[3];
        if (!present_scale_matches(slots[uv_i], size)) slots[uv_i] = present_scale_make(size, 1);
        NvPresentScale *s = slots[uv_i];
        if (s) {
            [cb useResidencySet:s->residency];
            if (present_blit_m4(cb, src, s->input, crop, uv_i, flip)) {
                [s->fx4 encodeToCommandBuffer:cb];
                return present_blit_m4(cb, s->output, dst, NULL, uv_i + 3, 0);
            }
        }
    }
#endif
    return present_blit_m4(cb, src, dst, crop, uv_i, flip);
}
