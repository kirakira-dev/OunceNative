// The real warm-up worker must deduplicate concurrent shader dependencies and
// hand usable render/compute pipelines to the submit-thread caches.
#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t g_mod[MAX_MOD]; int g_nmod;
void svc_thread_dump(void) {}
int prog_key(const prog_t *p, unsigned stage, uint8_t key[8]) { (void)p; (void)stage; memset(key, 0, 8); return 0; }
uint64_t now_ns(void) { return bp_now(); }
uint64_t nvn_new_serial(void) { static uint64_t serial = 90000; return ++serial; }
#define CHECK(x) do { if (!(x)) { fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #x); return 1; } } while (0)

// Validate a game's recorded manifest with the real package and Metal compiler.
// This does not render a scene; the fixture below separately checks GPU results.
static int check_manifest(const char *package, const char *path, const char *workers) {
    NSString *source = [NSString stringWithContentsOfFile:@(path) encoding:NSUTF8StringEncoding error:nil];
    CHECK(source); CHECK(atoi(workers) >= 1 && atoi(workers) <= 8);
    NSMutableSet<NSString *> *seen = [NSMutableSet set], *shaders = [NSMutableSet set];
    unsigned ns = 0, nr = 0, nc = 0;
    for (NSString *line in [source componentsSeparatedByString:@"\n"]) {
        if (!line.length || [line hasPrefix:@"#"] || [seen containsObject:line]) continue;
        [seen addObject:line];
        NSArray<NSString *> *c = [line componentsSeparatedByString:@"\t"];
        if ([c[0] isEqualToString:@"S"]) {
            CHECK(c.count == 3 && c[1].length && c[2].length == 1 && [@"012345" containsString:c[2]]);
            [shaders addObject:c[1]]; ns++;
        } else if ([c[0] isEqualToString:@"C"]) {
            CHECK(c.count == 2 && c[1].length); [shaders addObject:c[1]]; nc++;
        } else {
            CHECK([c[0] isEqualToString:@"R"] && c.count == 2);
            pso_skey sk; CHECK(!pso_skey_parse(c[1].UTF8String, &sk));
            NSString *v = warm_key(sk.vs, sizeof sk.vs), *f = warm_key(sk.fs, sizeof sk.fs);
            CHECK(v.length && f); [shaders addObject:v]; if (f.length) [shaders addObject:f]; nr++;
        }
    }
    CHECK(seen.count);
    setenv("DM_PSO_WORKERS", workers, 1); setenv("DM_PSO_STARTUP_WAIT_MS", "120000", 1);
    setenv("DM_PSO_MANIFEST", path, 1);
    mtl_init(); g_msl_dir = @(package); warm_start(); warm_startup_wait();
    CHECK(!atomic_load(&g_warm_running)); CHECK(g_warm_done == seen.count && g_warm_total == seen.count);
    CHECK(g_warm_shaders == ns && g_warm_rps == nr && g_warm_cps == nc && !g_warm_skip_fz);
    for (NSString *key in shaders) CHECK(g_shcache[key]);
    printf("PSO_MANIFEST PASS %u shader rows / %u render pipelines / %u compute pipelines; %lu shader dependencies retained, %u render / %u compute cache entries\n",
        ns, nr, nc, (unsigned long)shaders.count, g_pso.n, g_cps.n);
    return 0;
}

int main(int argc, char **argv) { @autoreleasepool {
    if (argc == 5 && !strcmp(argv[1], "--manifest")) return check_manifest(argv[2], argv[3], argv[4]);
    CHECK(argc == 3); mtl_init();
    g_msl_dir = @(argv[1]);
    setenv("DM_PSO_WORKERS", argv[2], 1);
    setenv("DM_PSO_STARTUP_WAIT_MS", "30000", 1);
    NSArray *names = @[@"warm-v", @"warm-f", @"warm-c"];
    NSArray *entries = @[@"triangle", @"color", @"compute"];
    for (unsigned i = 0; i < 3; i++) {
        NSString *dst = [g_msl_dir stringByAppendingPathComponent:[names[i] stringByAppendingString:@".metallib"]];
        CHECK([NSFileManager.defaultManager copyItemAtPath:[g_msl_dir stringByAppendingPathComponent:@"fixture.metallib"] toPath:dst error:nil]);
        NSDictionary *j = @{@"route": @"B", @"chain": @DMSH_CHAIN, @"bindings": @[], @"entry": entries[i], @"varying_outputs": @0};
        CHECK([[NSJSONSerialization dataWithJSONObject:j options:0 error:nil] writeToFile:[g_msl_dir stringByAppendingPathComponent:[names[i] stringByAppendingString:@".json"]] atomically:YES]);
    }
    NvShader *v = [NvShader new], *f = [NvShader new];
    strcpy(v->key, "warm-v"); strcpy(f->key, "warm-f"); f->stage = 1;
    NSMutableString *manifest = [NSMutableString string];
    // Put dependent pipelines first: several workers race to load the same two shaders.
    for (unsigned mask = 1; mask <= 15; mask++) {
        pso_key key = {.cfmt = {MTLPixelFormatRGBA32Float}, .samples = 1, .chmask = mask, .alpha_func = NVN_ALPHA_FUNC_ALWAYS};
        pso_skey sk; char hex[sizeof sk * 2 + 1]; pso_skey_from(&key, v, f, 0, NULL, &sk); pso_skey_hex(&sk, hex);
        [manifest appendFormat:@"R\t%s\n", hex];
    }
    [manifest appendString:@"S\twarm-v\t0\nS\twarm-f\t1\nS\twarm-c\t5\nC\twarm-c\nR\t0000\n"];
    [manifest appendString:[manifest copy]];
    NSString *path = [g_msl_dir stringByAppendingPathComponent:@"manifest.tsv"];
    CHECK([manifest writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil]);
    setenv("DM_PSO_MANIFEST", path.fileSystemRepresentation, 1);
    warm_start();
    warm_startup_wait();
    CHECK(!atomic_load(&g_warm_running)); CHECK(g_warm_done == 19 && g_warm_total == 19);
    CHECK(g_warm_shaders == 3 && g_warm_rps == 15 && g_warm_cps == 1);
    CHECK(g_vs_loaded == 1 && g_shcache.count == 3); CHECK(g_pso.n == 15 && g_cps.n == 1);
    CHECK(g_warm_claim_rps == 15 && g_warm_claim_cps == 1);
    v = g_shcache[@"warm-v"]; f = g_shcache[@"warm-f"];
    pso_key key = {.vs = (__bridge void *)v, .fs = (__bridge void *)f,
        .cfmt = {MTLPixelFormatRGBA32Float}, .samples = 1, .chmask = 15, .alpha_func = NVN_ALPHA_FUNC_ALWAYS};
    id<MTLRenderPipelineState> render = hm_get_id(&g_pso, &key); CHECK(render);
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float width:4 height:4 mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget; td.storageMode = MTLStorageModeShared;
    id<MTLTexture> target = [g_dev newTextureWithDescriptor:td]; CHECK(target);
    MTLRenderPassDescriptor *pd = [MTLRenderPassDescriptor renderPassDescriptor];
    pd.colorAttachments[0].texture = target; pd.colorAttachments[0].loadAction = MTLLoadActionClear;
    pd.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLCommandQueue> queue = [g_dev newCommandQueue]; id<MTLCommandBuffer> cb = [queue commandBuffer];
    id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:pd];
    [re setRenderPipelineState:render]; [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [re endEncoding];
    NvShader *cs = g_shcache[@"warm-c"]; const void *ck = (__bridge void *)cs;
    id<MTLComputePipelineState> compute = hm_get_id(&g_cps, &ck); CHECK(compute);
    uint32_t initial[18]; for (int i = 0; i < 18; i++) initial[i] = 0xfeedface;
    id<MTLBuffer> buffer = [g_dev newBufferWithBytes:initial length:sizeof initial options:MTLResourceStorageModeShared];
    id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder]; [ce setComputePipelineState:compute];
    [ce setBuffer:buffer offset:4 atIndex:0]; [ce dispatchThreads:MTLSizeMake(16, 1, 1) threadsPerThreadgroup:MTLSizeMake(16, 1, 1)]; [ce endEncoding];
    [cb commit]; [cb waitUntilCompleted]; CHECK(!cb.error);
    float pixels[64]; [target getBytes:pixels bytesPerRow:64 fromRegion:MTLRegionMake2D(0, 0, 4, 4) mipmapLevel:0];
    const float expected[] = {.25f, .5f, .75f, 1};
    for (int i = 0; i < 64; i++) CHECK(pixels[i] == expected[i % 4]);
    const uint32_t *values = buffer.contents; CHECK(values[0] == 0xfeedface && values[17] == 0xfeedface);
    for (int i = 0; i < 16; i++) CHECK(values[i + 1] == 0x12340000u + i);
    printf("PSO_WARM PASS %s workers: 19 unique rows, one vertex load, 15 render/1 compute pipelines, 80 exact GPU values and guards\n", argv[2]);
    return 0;
} }
