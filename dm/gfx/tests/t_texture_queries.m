#include "../nvn/nvn_mtl.m"
int prog_key(const prog_t *p, unsigned stage, uint8_t key[8]) { memset(key, 0, 8); return 0; }
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { return NULL; }
module_t g_mod[MAX_MOD]; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
uint64_t nvn_new_serial(void) { static uint64_t serial = 99000; return ++serial; }
#define CHECK(x) do { if (!(x)) { fprintf(stderr, "FAIL line %d: %s (%s)\n", __LINE__, #x, error.description.UTF8String); return 1; } } while (0)

int main(int argc, char **argv) { @autoreleasepool {
    NSError *error = nil; CHECK(argc == 2); mtl_init(); state_reset();
    NvShader *shaders[30]; id<MTLComputePipelineState> pipelines[30];
    for (unsigned i = 0; i < 30; i++) {
        NSString *stem = [NSString stringWithFormat:@"%s/%016x", argv[1], i + 1];
        NSString *source = [NSString stringWithContentsOfFile:[stem stringByAppendingString:@".metal"] encoding:NSUTF8StringEncoding error:&error]; CHECK(source);
        id<MTLLibrary> lib = [g_dev newLibraryWithSource:source options:nil error:&error]; CHECK(lib);
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:[stem stringByAppendingString:@".json"]] options:0 error:&error]; CHECK(json);
        NvShader *sh = [NvShader new]; sh->fn = [lib newFunctionWithName:@"main0"]; sh->stage = 5; char why[256];
        int rejected = nvn_refl_from_json(json, &sh->rf, why, sizeof why);
        if (rejected) fprintf(stderr, "%s\n", why); CHECK(!rejected);
        CHECK(sh->rf.nb == 3 && sh->rf.b[2].kind == (i < 15 ? NVN_RB_TEX_QUERY : NVN_RB_IMG_QUERY));
        sh->ae = [sh->fn newArgumentEncoderWithBufferIndex:0]; sh->arg_len = sh->ae.encodedLength;
        CHECK(sh->arg_len == 24); shaders[i] = sh;
        pipelines[i] = [g_dev newComputePipelineStateWithFunction:sh->fn error:&error]; CHECK(pipelines[i]);
        if (i == 0) for (unsigned bad = 0; bad < 7; bad++) {
            NSMutableDictionary *invalid = [json mutableCopy];
            NSMutableArray *bindings = [json[@"bindings"] mutableCopy]; invalid[@"bindings"] = bindings;
            NSMutableDictionary *binding = [bindings[2] mutableCopy]; bindings[2] = binding;
            if (bad == 0) [invalid removeObjectForKey:@"runtime_texture_queries"];
            if (bad == 1) invalid[@"runtime_texture_queries"] = @{@"version":@2};
            if (bad == 2) binding[@"reg"] = @128;
            if (bad == 3) binding[@"reg"] = @0.5;
            if (bad == 4) binding[@"rw"] = @YES;
            if (bad == 5) binding[@"msl_type"] = @"texture2d<float>";
            if (bad == 6) { binding[@"kind"] = @"img_query"; invalid[@"stage"] = @"pixel"; }
            nvn_refl rf; CHECK(nvn_refl_from_json(invalid, &rf, why, sizeof why));
        }
    }
    enum { LODS = 8, STRIDE = 256, BYTES = 30 * STRIDE + 4096 };
    uint8_t *memory = NULL; CHECK(!posix_memalign((void **)&memory, getpagesize(), 16384)); mtl_pool_add(memory, 16384);
    unsigned cases = 0, values = 0, guards = 0;
    // Target 10 (buffer) creation is not implemented by this runtime. The test
    // covers all its implemented NVN texture targets and a null binding.
    for (unsigned legacy = 0; legacy < 2; legacy++) for (int target = -1; target < 10; target++)
    for (unsigned view_index = 0; view_index < 3; view_index++) {
        BOOL no_lod = target == 5 || target == 6 || target == 7;
        if (no_lod && view_index) continue;
        tex_t t = {.magic = MAGIC('T','E','X',0), .serial = nvn_new_serial()};
        t.d.width = target >= 8 ? 32 : 37; t.d.height = target >= 8 ? 32 : target == 3 ? 7 : 19;
        t.d.depth = target == 2 ? 9 : target == 9 ? 18 : target == 4 || target == 6 ? 7 : 1;
        t.d.levels = no_lod ? 1 : 4; t.d.samples = target == 5 || target == 6 ? 4 : 1;
        t.d.target = target; t.d.format = NVN_FORMAT_RGBA32F;
        view_t view = {.set_levels=1, .base_level=view_index, .nlevels=t.d.levels-view_index};
        if (target == 3 || target == 4) { view.set_layers = 1; view.min_layer = 1; view.nlayers = 3; }
        if (target == 9) { view.set_layers = 1; view.min_layer = 6; view.nlayers = 12; }
        if (target >= 0) CHECK(tex_mtl(&t));
        mtl_reg_tex(300, target >= 0 ? &t : NULL, target >= 0 ? &view : NULL);
        S.tex[5][0] = S.img[5][0] = target >= 0 ? 300 : 0;
        memset(memory, 0xcd, 16384); args_dirty_all(); mtl_sub_begin();
        id<MTLCommandBuffer> cb = legacy ? legacy_begin() : nil;
        id<MTLComputeCommandEncoder> en = legacy ? [cb computeCommandEncoder] : pg_compute("texture-query-regression");
        for (unsigned shader = 0; shader < 30; shader++) {
            // Poison the other table so a texture/image mapping mix-up is observable.
            S.tex[5][0] = target >= 0 && shader < 15 ? 300 : 0;
            S.img[5][0] = target >= 0 && shader >= 15 ? 300 : 0;
            S.ssbo[5][0] = (p_bind_buf){5, 0, (uint64_t)memory + 32 + shader * STRIDE, LODS * 16}; args_dirty_all();
            if (legacy) [en setComputePipelineState:pipelines[shader]]; else enc_c_pso(en, pipelines[shader]);
            CHECK(encode_args_to(en, shaders[shader], 5, legacy ? ARGS_LEGACY_COMPUTE : ARGS_M4_COMPUTE));
            if (legacy) [en dispatchThreadgroups:MTLSizeMake(LODS,1,1) threadsPerThreadgroup:MTLSizeMake(1,1,1)];
            else enc_c_dispatch(en, MTLSizeMake(LODS,1,1), MTLSizeMake(1,1,1));
        }
        // Pending commands must retain the previous dimensions after registration changes.
        mtl_reg_tex(300, NULL, NULL); S.tex[5][0] = S.img[5][0] = 0;
        if (legacy) { [en endEncoding]; legacy_commit(cb); } else enc_c_end(en);
        CHECK(mtl_wait(mtl_sub_commit(), 10000000000ull)); CHECK(!mtl_last_commit_error());
        for (unsigned shader = 0; shader < 30; shader++) for (unsigned lod = 0; lod < LODS; lod++) {
            uint32_t expected[4] = {0}, packed[4] = {0xa5a5a5a5,0xa5a5a5a5,0xa5a5a5a5,0xa5a5a5a5};
            if (target >= 0) {
                expected[3] = t.d.levels - view_index;
                if (no_lod || lod < expected[3]) {
                    unsigned level = no_lod ? 0 : view_index + lod;
                    expected[0] = MAX(1, t.d.width >> level);
                    if (target != 0 && target != 3) expected[1] = MAX(1, t.d.height >> level);
                    if (target == 2) expected[2] = MAX(1, t.d.depth >> level);
                    if (target == 3) expected[1] = 3;
                    if (target == 4) expected[2] = 3;
                    if (target == 6) expected[2] = 7;
                    if (target == 9) expected[2] = 2;
                }
            }
            unsigned out = 0, mask = shader % 15 + 1;
            for (unsigned axis = 0; axis < 4; axis++) if (mask & (1u << axis)) packed[out++] = expected[axis];
            const uint32_t *actual = (const uint32_t *)(memory + 32 + shader * STRIDE + lod * 16);
            for (unsigned c = 0; c < 4; c++) {
                if (actual[c] != packed[c]) fprintf(stderr, "target%d view%u legacy%u mask%x lod%u channel%u: %u != %u\n", target,view_index,legacy,mask,lod,c,actual[c],packed[c]);
                CHECK(actual[c] == packed[c]); values++;
            }
            cases++;
        }
        for (unsigned i = 0; i < 16384; i++) {
            unsigned relative = i % STRIDE;
            if (i < 30 * STRIDE && relative >= 32 && relative < 32 + LODS * 16) continue;
            CHECK(memory[i] == 0xcd); guards++;
        }
        if (target >= 0) mtl_tex_release(&t);
    }
    mtl_pool_del(memory); free(memory);
    printf("PASS %u native TXQ results, %u exact words, %u guard bytes; 30 shaders, every component mask, texture/image bindings, ten targets, nulls, mip/layer views, queued lifetime, Metal 4/legacy\n", cases,values,guards);
    return 0;
}}
