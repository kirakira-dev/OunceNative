// Exercise the actual screenshot and Metal 4 presentation paths, including
// crop/origin/color handling and replacement of each in-flight cache slot.
#include "../nvn/nvn_mtl.m"
int prog_key(const prog_t *p, unsigned stage, uint8_t key[8]) { memset(key, 0, 8); return 0; }
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { return NULL; }
module_t g_mod[MAX_MOD]; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
uint64_t nvn_new_serial(void) { static uint64_t n = 90000; return ++n; }
#define CHECK(x) do { if (!(x)) { fprintf(stderr, "FAIL %d: %s\n", __LINE__, #x); return 1; } } while (0)
static unsigned calls;
static int run(int metal4, MTLPixelFormat format, int flip, int bars, int stripes, int large, int direct) {
    NSUInteger sw = large ? 1920 : 96, sh = large ? 1080 : 80;
    int crop[4] = {16, 16, 64, 32};
    if (large) memcpy(crop, (int[4]){0,0,1920,1080}, sizeof crop);
    NSUInteger dw = large ? 3840 : 256, dh = large ? 2160 : bars ? 256 : 128;
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format width:sw height:sh mipmapped:NO];
    d.storageMode = MTLStorageModeShared; d.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> src = [g_dev newTextureWithDescriptor:d]; CHECK(src);
    uint8_t *pixels = calloc(sw * sh, 4); CHECK(pixels);
    const uint8_t colors[2][4] = {{128,64,200,255},{24,180,80,255}};
    for (NSUInteger y = 0; y < sh; y++) for (NSUInteger x = 0; x < sw; x++) {
        uint8_t *p = pixels + 4 * (y * sw + x);
        if (x >= crop[0] && x < crop[0] + crop[2] && y >= crop[1] && y < crop[1] + crop[3])
            memcpy(p, colors[stripes && y >= crop[1] + crop[3] / 2], 4);
        else { p[1] = 255; p[3] = 255; }   // Poison outside the crop must never bleed into the output.
    }
    [src replaceRegion:MTLRegionMake2D(0,0,sw,sh) mipmapLevel:0 withBytes:pixels bytesPerRow:sw*4]; free(pixels);
    d.pixelFormat = MTLPixelFormatRGBA8Unorm; d.width = dw; d.height = dh; d.usage = MTLTextureUsageRenderTarget;
    if (direct) { d.pixelFormat = MTLPixelFormatBGRA8Unorm; d.usage |= MTLTextureUsageShaderRead; d.storageMode = MTLStorageModePrivate; }
    id<MTLTexture> dst = [g_dev newTextureWithDescriptor:d]; CHECK(dst);
    atomic_store(&g_origin_ll, flip);
    if (metal4) {
        NSError *error = nil;
        id<MTL4CommandAllocator> allocator = [g_dev newCommandAllocatorWithDescriptor:[MTL4CommandAllocatorDescriptor new] error:&error]; CHECK(allocator);
        id<MTL4CommandBuffer> cb = [g_dev newCommandBuffer]; CHECK(cb);
        [cb beginCommandBufferWithAllocator:allocator];
        res_add(src); res_add(dst); res_commit();
        CHECK(present_encode_m4(cb, src, dst, crop, calls++ % 3));
        [cb endCommandBuffer];
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        __block NSError *gpu_error = nil; __block double ms = 0;
        MTL4CommitOptions *options = [MTL4CommitOptions new];
        [options addFeedbackHandler:^(id<MTL4CommitFeedback> f) { gpu_error = f.error; ms = (f.GPUEndTime - f.GPUStartTime) * 1000; dispatch_semaphore_signal(done); }];
        id<MTL4CommandBuffer> buffers[] = {cb}; [g_q4 commit:buffers count:1 options:options];
        CHECK(!dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC)));
        if (gpu_error) fprintf(stderr, "%s\n", gpu_error.description.UTF8String);
        CHECK(!gpu_error); res_remove(src); res_remove(dst); res_commit();
        if (large) printf("1080p -> 4K presentation GPU %.3f ms (direct %d)\n", ms, direct);
    } else {
        id<MTLCommandBuffer> cb = [g_q commandBuffer]; CHECK(present_encode(cb, src, dst, crop));
        [cb commit]; [cb waitUntilCompleted]; CHECK(cb.status == MTLCommandBufferStatusCompleted);
    }
    uint8_t *out = malloc(dw * dh * 4); CHECK(out);
    if (direct) {
        id<MTLBuffer> read = [g_dev newBufferWithLength:dw*dh*4 options:MTLResourceStorageModeShared]; CHECK(read);
        id<MTLCommandBuffer> cb = [g_q commandBuffer]; id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
        [blit copyFromTexture:dst sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(dw,dh,1)
            toBuffer:read destinationOffset:0 destinationBytesPerRow:dw*4 destinationBytesPerImage:dw*dh*4];
        [blit endEncoding]; [cb commit]; [cb waitUntilCompleted]; CHECK(cb.status == MTLCommandBufferStatusCompleted);
        memcpy(out, read.contents, dw*dh*4);
    } else [dst getBytes:out bytesPerRow:dw*4 fromRegion:MTLRegionMake2D(0,0,dw,dh) mipmapLevel:0];
    int bad = 0, worst = 0;
    NSUInteger top = bars ? 64 : 0, height = bars ? 128 : dh;
    for (NSUInteger y = 0; y < dh; y++) for (NSUInteger x = 0; x < dw; x++) {
        uint8_t *p = out + 4 * (y * dw + x);
        if (y < top || y >= top + height) { bad += p[0] || p[1] || p[2] || p[3] != 255; continue; }
        // The spatial filter deliberately reconstructs a transition. Check the
        // known constant regions, outside a small band around the step edge.
        NSUInteger yy = y - top;
        if (stripes && abs((int)yy - (int)height / 2) < 8) continue;
        int color = stripes && ((yy >= height / 2) != flip);
        for (int c = 0; c < 3; c++) { int delta = abs(p[direct ? 2-c : c] - colors[color][c]); if (delta > worst) worst = delta; bad += delta > 2; }
    }
    free(out);
    printf("Metal %d format %lu flip %d bars %d stripes %d direct %d %lux%lu: error <= %d, bad %d\n", metal4 ? 4 : 3, format, flip, bars, stripes, direct, dw, dh, worst, bad);
    CHECK(!bad); return 0;
}
int main(void) { @autoreleasepool {
    setenv("DM_UPSCALER", "metalfx", 1); mtl_init();
    CHECK([MTLFXSpatialScalerDescriptor supportsMetal4FX:g_dev]);
    for (int api = 0; api < 2; api++) for (int srgb = 0; srgb < 2; srgb++) for (int flip = 0; flip < 2; flip++)
        for (int direct = 0; direct < 2; direct++)
            CHECK(!run(api, srgb ? MTLPixelFormatRGBA8Unorm_sRGB : MTLPixelFormatRGBA8Unorm, flip, srgb, flip, 0, direct));
    for (int direct = 0; direct < 2; direct++) for (int i = 0; i < 6; i++)
        CHECK(!run(1, MTLPixelFormatRGBA8Unorm, i & 1, 0, 0, !(i & 1), direct));
    puts("MetalFX crop, orientation, color, letterbox, resize and 4K checks passed"); return 0;
} }
