#include "../nvn/nvn_mtl.m"
int prog_key(const prog_t *p, unsigned stage, uint8_t key[8]) { memset(key, 0, 8); return 0; }
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { return NULL; }
module_t g_mod[MAX_MOD]; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
uint64_t nvn_new_serial(void) { static uint64_t serial = 100000; return ++serial; }
#define CHECK(x) do { if (!(x)) { fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #x); return 1; } } while (0)

int main(void) { @autoreleasepool {
    setenv("DM_NVN_VIEW_CACHE", "1", 1); mtl_init();
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
        width:4096 height:4096 mipmapped:YES];
    d.storageMode = MTLStorageModeShared; d.usage = MTLTextureUsageShaderRead | MTLTextureUsagePixelFormatView;
    id<MTLTexture> base = [g_dev newTextureWithDescriptor:d]; CHECK(base);
    CHECK(base.allocatedSize > SAMPLING_VIEW_CACHE_BYTES / 4 && base.allocatedSize <= SAMPLING_VIEW_CACHE_BYTES / 2);
    id<MTLTexture> views[10]; uint8_t swizzle[4] = {2,3,4,5};
    for (unsigned i = 0; i < 10; i++) {
        uint8_t pixel[] = {i + 1, i + 2, i + 3, 255};
        [base replaceRegion:MTLRegionMake2D(0,0,1,1) mipmapLevel:i withBytes:pixel bytesPerRow:4];
        views[i] = sampling_view(base, (void *)1, base.pixelFormat, MTLTextureType2D, NSMakeRange(i,1), NSMakeRange(0,1), 0, swizzle);
        CHECK(views[i]);
    }
    CHECK(g_sampling_view_map.n == 10 && g_sampling_storage.n == 1 && g_sampling_view_bytes == base.allocatedSize);
    for (unsigned i = 0; i < 10; i++) {
        CHECK(views[i] == sampling_view(base, (void *)1, base.pixelFormat, MTLTextureType2D, NSMakeRange(i,1), NSMakeRange(0,1), 0, swizzle));
        uint8_t pixel[4]; [views[i] getBytes:pixel bytesPerRow:4 fromRegion:MTLRegionMake2D(0,0,1,1) mipmapLevel:0];
        CHECK(pixel[0] == i + 1 && pixel[1] == i + 2 && pixel[2] == i + 3 && pixel[3] == 255);
    }
    id<MTLTexture> alias = [base newTextureViewWithPixelFormat:base.pixelFormat]; CHECK(alias);
    CHECK(sampling_view(alias, (void *)2, base.pixelFormat, MTLTextureType2D, NSMakeRange(0,1), NSMakeRange(0,1), 0, swizzle));
    CHECK(g_sampling_storage.n == 1 && g_sampling_view_bytes == base.allocatedSize);
    sampling_view_drop_pool((void *)1);
    CHECK(g_sampling_view_map.n == 1 && g_sampling_view_bytes == base.allocatedSize);
    sampling_view_drop_pool((void *)2);
    CHECK(!g_sampling_view_map.n && !g_sampling_storage.n && !g_sampling_view_bytes);
    for (unsigned i = 0; i < 4; i++) {
        id<MTLTexture> other = [g_dev newTextureWithDescriptor:d]; CHECK(other);
        CHECK(sampling_view(other, (void *)3, other.pixelFormat, MTLTextureType2D, NSMakeRange(0,1), NSMakeRange(0,1), 0, swizzle));
        CHECK(g_sampling_view_bytes <= SAMPLING_VIEW_CACHE_BYTES);
    }
    CHECK(g_sampling_storage.n == 2);
    sampling_view_drop_pool((void *)3);
    CHECK(!g_sampling_view_map.n && !g_sampling_storage.n && !g_sampling_view_bytes);
    for (unsigned i = 0; i < 1200; i++) {
        uint8_t sw[] = {2 + ((i / 10) & 3), 2 + ((i / 40) & 3), 2 + ((i / 160) & 3), 2 + ((i / 640) & 3)};
        CHECK(sampling_view(base, (void *)4, base.pixelFormat, MTLTextureType2D, NSMakeRange(i % 10,1), NSMakeRange(0,1), 1, sw));
        CHECK(g_sampling_view_map.n <= SAMPLING_VIEW_CACHE_SIZE && g_sampling_view_bytes == base.allocatedSize);
    }
    sampling_view_drop_pool((void *)4);
    CHECK(!g_sampling_view_map.n && !g_sampling_storage.n && !g_sampling_view_bytes);
    puts("PASS shared-storage view retention, mip contents, parent views, pool release, byte budget and entry eviction");
    return 0;
}}
