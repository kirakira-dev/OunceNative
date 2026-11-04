#include "../nvn/nvn_mtl.m"
int prog_key(const prog_t *p, unsigned stage, uint8_t key[8]) { memset(key, 0, 8); return 0; }
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { return NULL; }
module_t g_mod[MAX_MOD]; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
uint64_t nvn_new_serial(void) { static uint64_t serial = 98000; return ++serial; }
#define CHECK(x) do { if (!(x)) { fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #x); return 1; } } while (0)
typedef struct { uint8_t *bytes; size_t length; } commands;
static void emit(commands *c, unsigned op, const void *data, size_t size) {
    uint32_t total = (size + 15) & ~7u; op_hdr header = {op, total};
    memcpy(c->bytes + c->length, &header, 8);
    if (size) memcpy(c->bytes + c->length + 8, data, size);
    c->length += total;
}
static void mask(commands *c, uint32_t value) {
    p_bind_state b = {.kind = 2}; memcpy(b.bytes, &value, 4); emit(c, OP_BIND_STATE, &b, sizeof b);
}
static void update(commands *c, uint64_t address, float value) {
    struct { uint64_t address, size; float value; } u = {address, 4, value};
    emit(c, OP_UPDATE_UB, &u, 20);
}
int main(int argc, char **argv) { @autoreleasepool {
    int merge = argc == 1 || strcmp(argv[1], "off");
    int footprint = argc < 3;
    setenv("DM_NVN_QUERY_MERGE", merge ? "1" : "0", 1); setenv("DM_NVN_TBDR", "0", 1);
    mtl_init(); state_reset(); S.ds.dw = 0; NSError *error = nil;
    id<MTLLibrary> lib = [g_dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\n"
        "struct A { texture2d<float, access::read> tex [[id(0)]]; constant float *cb [[id(1)]]; };\n"
        "vertex float4 vs(uint i [[vertex_id]]) { return float4(i==1?3.0:-1.0,i==2?3.0:-1.0,0,1); }\n"
        "vertex float4 vs_query(uint i [[vertex_id]], constant A &a [[buffer(0)]]) { return float4(i==1?3.0:-1.0,i==2?3.0:-1.0,a.cb[7]<0.5?-1.0:0.0,1); }\n"
        "fragment float4 query(float4 p [[position]], constant A &a [[buffer(0)]]) { if(a.tex.read(uint2(p.xy)).r<0.5 || p.x>=a.cb[1] || a.cb[7]<0.5) discard_fragment(); return float4(0); }\n"
        "fragment float4 write_zero() { return float4(0); }" options:nil error:&error]; CHECK(lib);
    prog_t programs[2] = {{.serial = nvn_new_serial()}, {.serial = nvn_new_serial()}};
    NvProg *p[2];
    for (int i = 0; i < 2; i++) {
        p[i] = [NvProg new]; p[i]->sh[0] = [NvShader new]; p[i]->sh[1] = [NvShader new];
        p[i]->sh[0]->fn = [lib newFunctionWithName:i ? @"vs" : @"vs_query"]; p[i]->sh[0]->range_ro = 1;
        p[i]->sh[1]->fn = [lib newFunctionWithName:i ? @"write_zero" : @"query"];
        p[i]->sh[1]->stage = 1; p[i]->sh[1]->range_ro = 1; p[i]->sh[1]->rf.color_mask = 1;
        serial_put(programs[i].serial, p[i]);
    }
    NvShader *q = p[0]->sh[1]; q->ae = [q->fn newArgumentEncoderWithBufferIndex:0]; q->arg_len = q->ae.encodedLength;
    q->rf.nb = 2; q->rf.b[0] = (nvn_rbind){.kind = NVN_RB_TEX, .aid = 0, .dtt = MTLTextureType2D};
    NSMutableDictionary *binding = [@{@"kind":@"cbuf", @"arg_id":@1, @"reg":@0, @"read_words":@[@1,@7]} mutableCopy];
    NSDictionary *reflection = @{@"route":@"B", @"bindings":@[binding]}; nvn_refl parsed; char err[128];
    CHECK(!nvn_refl_from_json(reflection, &parsed, err, sizeof err));
    CHECK(parsed.b[0].cb_span == 32 && parsed.b[0].cb_words[0] == ((1ull << 1) | (1ull << 7)));
    q->rf.b[1] = parsed.b[0];
    if (!footprint) q->rf.b[1].cb_span = 0;
    NvShader *qv = p[0]->sh[0]; qv->ae = [qv->fn newArgumentEncoderWithBufferIndex:0]; qv->arg_len = qv->ae.encodedLength;
    qv->rf.nb = 1; qv->rf.b[0] = (nvn_rbind){.kind = NVN_RB_CBUF, .aid = 1, .reg = 0,
        .cb_span = footprint ? 32 : 0, .cb_words = {1ull << 7}};
    for (id bad in @[@[], @[@1,@1], @[@256], @[@1.5], @"1,7"]) {
        binding[@"read_words"] = bad; CHECK(nvn_refl_from_json(reflection, &parsed, err, sizeof err));
    }
    void *uniforms = NULL; CHECK(!posix_memalign(&uniforms, 16384, 65536)); memset(uniforms, 0, 65536);
    mtl_pool_add(uniforms, 65536);
    tex_t target = {.magic = MAGIC('T','E','X',0), .serial = nvn_new_serial()};
    target.d = (nvn_texdesc){.target = NVN_TEXTURE_TARGET_2D, .format = NVN_FORMAT_RGBA8,
        .width = 8, .height = 8, .depth = 1, .levels = 1, .samples = 1};
    mtl_reg_tex(1, &target, NULL); CHECK(tex_mtl(&target));
    tex_t depth_target = target; depth_target.serial = nvn_new_serial(); depth_target.d.format = NVN_FORMAT_DEPTH32F;
    enum { QUERIES = VIS_SLOTS + 3 };
    uint64_t (*result)[2] = calloc(QUERIES, sizeof *result); CHECK(result);
    uint64_t expected[QUERIES];
    commands c = {.bytes = calloc(1, (QUERIES + 16) * 1024)}; CHECK(c.bytes);
    p_set_rt rt = {.n = 1, .depth = &depth_target}; rt.color[0] = &target;
    p_bind_program query = {&programs[0], 3}, writer = {&programs[1], 3};
    p_bind_handles tex = {.stage = 1, .n = 1}; tex.h[0] = 1;
    p_draw draw = {.prim = NVN_DRAW_PRIMITIVE_TRIANGLES, .count = 3, .instances = 1};
    p_clear_color white = {.index = 0, .rgba = {1,1,1,1}, .mask = 15};
    p_scissor full = {0,0,8,8};
    p_bind_state depth = {.kind = 5}; memcpy(depth.bytes, &S.ds, sizeof S.ds); emit(&c, OP_BIND_STATE, &depth, sizeof depth);
    emit(&c, OP_SET_RT, &rt, sizeof rt); emit(&c, OP_CLEAR_COLOR, &white, sizeof white);
    emit(&c, OP_BIND_TEX, &tex, sizeof tex);
    p_bind_buf uniform = {.stage = 1, .index = 0, .addr = (uint64_t)uniforms, .size = 65536};
    emit(&c, OP_BIND_UBO, &uniform, sizeof uniform);
    uniform.stage = 0; emit(&c, OP_BIND_UBO, &uniform, sizeof uniform);
    uint64_t type = NVN_COUNTER_TYPE_SAMPLES_PASSED; int nonzero = 1;
    for (unsigned i = 0; i < QUERIES; i++) {
        emit(&c, OP_SET_RT, &rt, sizeof rt);
        if (i == 16) { // A writer following merged queries must start a new pass.
            emit(&c, OP_SCISSOR, &full, sizeof full); mask(&c, 15);
            emit(&c, OP_BIND_PROGRAM, &writer, sizeof writer); emit(&c, OP_DRAW, &draw, sizeof draw);
            emit(&c, OP_SET_RT, &rt, sizeof rt); nonzero = 0;
        }
        if (i == 32) { // A clear must become visible to the following texture reads.
            emit(&c, OP_SCISSOR, &full, sizeof full); emit(&c, OP_CLEAR_COLOR, &white, sizeof white);
            emit(&c, OP_SET_RT, &rt, sizeof rt); nonzero = 1;
        }
        mask(&c, 0); emit(&c, OP_BIND_PROGRAM, &query, sizeof query);
        unsigned width = i & 1 ? 2 : 6, enabled = i % 3 != 0;
        update(&c, (uint64_t)uniforms + 4, width); update(&c, (uint64_t)uniforms + 28, enabled);
        p_scissor sc = {0,0,i & 1 ? 4 : 8,8}; emit(&c, OP_SCISSOR, &sc, sizeof sc);
        emit(&c, OP_RESET_COUNTER, &type, 8); emit(&c, OP_DRAW, &draw, sizeof draw);
        uint64_t report[] = {type, (uint64_t)result[i]}; emit(&c, OP_REPORT_COUNTER, report, sizeof report);
        expected[i] = nonzero && enabled ? width * 8 : 0;
    }
    emit(&c, OP_END, NULL, 0);
    for (unsigned round = 0; round < 3; round++) {
        memset(result, 0xff, QUERIES * sizeof *result);
        mtl_sub_begin(); mtl_exec(c.bytes);
        CHECK(mtl_wait(mtl_sub_commit(), 10000000000ull)); CHECK(!mtl_last_commit_error());
        for (unsigned i = 0; i < QUERIES; i++) {
            if (result[i][0] != expected[i]) fprintf(stderr, "round %u query %u got %llu expected %llu\n", round, i, result[i][0], expected[i]);
            CHECK(result[i][0] == expected[i]);
        }
    }
    fprintf(stderr, "%llu passes, %llu merges\n", g_stat_pass, g_query_merges);
    CHECK(merge && footprint ? g_query_merges > 3 * (QUERIES - 100) && g_stat_pass < 140 : g_stat_pass >= 3 * QUERIES);
    CHECK(merge || !g_query_merges);
    CHECK(((float *)uniforms)[1] == ((QUERIES - 1) & 1 ? 2 : 6));
    CHECK(((float *)uniforms)[7] == ((QUERIES - 1) % 3 != 0));
    // Compare final storage after overlapping, adjacent and disjoint updates.
    uint8_t expected_bytes[65536]; memcpy(expected_bytes, uniforms, sizeof expected_bytes);
    uint32_t random = 12345;
    mtl_sub_begin();
    for (unsigned batch = 0; batch < 8; batch++) {
        CHECK(rp_begin_ex(0));
        for (unsigned i = 0; i < 128; i++) {
            random = random * 1664525u + 1013904223u;
            unsigned offset = 128 + 4 * (random % 512), length = 4 * (1 + (random >> 20) % 16);
            uint32_t data[16]; for (unsigned j = 0; j < 16; j++) data[j] = random ^ j * 7919;
            mtl_sub_update(data, (uint64_t)uniforms + offset, length);
            memcpy(expected_bytes + offset, data, length);
        }
        rp_end();
    }
    CHECK(mtl_wait(mtl_sub_commit(), 10000000000ull)); CHECK(!mtl_last_commit_error());
    CHECK(!memcmp(expected_bytes, uniforms, sizeof expected_bytes));
    // Adjacent guest pools remain distinct Metal buffers. Combining their
    // update ranges must not drop both writes during copyback.
    void *adjacent = NULL; CHECK(!posix_memalign(&adjacent, 16384, 32768));
    memset(adjacent, 0, 32768);
    mtl_pool_add(adjacent, 16384); mtl_pool_add((uint8_t *)adjacent + 16384, 16384);
    uint32_t pair[2] = {0x12345678, 0x9abcdef0};
    mtl_sub_begin(); CHECK(rp_begin_ex(0));
    mtl_sub_update(pair, (uint64_t)adjacent + 16380, 4);
    mtl_sub_update(pair + 1, (uint64_t)adjacent + 16384, 4);
    CHECK(g_nubd == 2 && g_ubd_ranges.count == 1);
    CHECK(mtl_wait(mtl_sub_commit(), 10000000000ull)); CHECK(!mtl_last_commit_error());
    CHECK(!memcmp((uint8_t *)adjacent + 16380, pair, sizeof pair));
    mtl_pool_del(adjacent); mtl_pool_del((uint8_t *)adjacent + 16384); free(adjacent);
    printf("PASS 3 rounds of %u attachment-sampling queries, sparse uniform snapshots, writable draw, clear, scissor and rollover (%s: %llu passes, %llu merges)\n", QUERIES, merge ? "on" : "off", g_stat_pass, g_query_merges);
    vis_clear(); free(c.bytes); free(result); mtl_pool_del(uniforms); free(uniforms); return 0;
}}
