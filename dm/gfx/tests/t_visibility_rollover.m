#include "../nvn/nvn_mtl.m"
int prog_key(const prog_t *p, unsigned stage, uint8_t key[8]) { memset(key, 0, 8); return 0; }
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { return NULL; }
module_t g_mod[MAX_MOD]; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
uint64_t nvn_new_serial(void) { static uint64_t serial = 97000; return ++serial; }
#define CHECK(x) do { if (!(x)) { fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #x); return 1; } } while (0)
typedef struct { uint8_t *bytes; size_t length; } commands;
static void emit(commands *c, unsigned op, const void *data, size_t size) {
    uint32_t total = (size + 15) & ~7u; op_hdr header = {op, total};
    memcpy(c->bytes + c->length, &header, 8);
    if (size) memcpy(c->bytes + c->length + 8, data, size);
    c->length += total;
}
int main(void) { @autoreleasepool {
    mtl_init(); state_reset(); NSError *error = nil;
    id<MTLLibrary> lib = [g_dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\n"
        "vertex float4 vs(uint i [[vertex_id]]) { return float4(i==1?3.0:-1.0,i==2?3.0:-1.0,0,1); }\n"
        "fragment float4 fs() { return float4(1,0,0,1); }" options:nil error:&error]; CHECK(lib);
    prog_t program = {.serial = nvn_new_serial()}; NvProg *p = [NvProg new];
    p->sh[0] = [NvShader new]; p->sh[0]->fn = [lib newFunctionWithName:@"vs"];
    p->sh[1] = [NvShader new]; p->sh[1]->fn = [lib newFunctionWithName:@"fs"];
    p->sh[1]->stage = 1; p->sh[1]->rf.color_mask = 1; serial_put(program.serial, p);
    tex_t target = {.magic = MAGIC('T','E','X',0), .serial = nvn_new_serial()};
    target.d = (nvn_texdesc){.target = NVN_TEXTURE_TARGET_2D, .format = NVN_FORMAT_RGBA8,
        .width = 8, .height = 8, .depth = 1, .levels = 1, .samples = 1};
    enum { QUERIES = VIS_SLOTS + 3 };
    uint64_t (*result)[2] = calloc(QUERIES + 1, sizeof *result); CHECK(result);
    commands c = {.bytes = calloc(1, (QUERIES + 1) * 128 + 4096)}; CHECK(c.bytes);
    p_set_rt rt = {.n = 1}; rt.color[0] = &target; emit(&c, OP_SET_RT, &rt, sizeof rt);
    p_bind_program bind = {&program, 3}; emit(&c, OP_BIND_PROGRAM, &bind, sizeof bind);
    p_draw draw = {.prim = NVN_DRAW_PRIMITIVE_TRIANGLES, .count = 3, .instances = 1};
    emit(&c, OP_DRAW, &draw, sizeof draw); // Counting starts after the pass is open.
    uint64_t type = NVN_COUNTER_TYPE_SAMPLES_PASSED;
    for (unsigned i = 0; i < QUERIES; i++) {
        emit(&c, OP_RESET_COUNTER, &type, 8); emit(&c, OP_DRAW, &draw, sizeof draw);
        uint64_t report[] = {type, (uint64_t)result[i]}; emit(&c, OP_REPORT_COUNTER, report, sizeof report);
    }
    emit(&c, OP_DRAW, &draw, sizeof draw);
    uint64_t report[] = {type, (uint64_t)result[QUERIES]}; emit(&c, OP_REPORT_COUNTER, report, sizeof report);
    emit(&c, OP_END, NULL, 0);
    mtl_sub_begin(); mtl_exec(c.bytes); CHECK(mtl_wait(mtl_sub_commit(), 10000000000ull)); CHECK(!mtl_last_commit_error());
    for (unsigned i = 0; i < QUERIES; i++) {
        if (result[i][0] != 64) fprintf(stderr, "query %u got %llu samples\n", i, (unsigned long long)result[i][0]);
        CHECK(result[i][0] == 64);
    }
    CHECK(result[QUERIES][0] == 128); vis_clear();
    for (unsigned round = 0; round < 10; round++) {
        c.length = 0;
        emit(&c, OP_SET_RT, &rt, sizeof rt);
        if (!round) emit(&c, OP_RESET_COUNTER, &type, 8);
        emit(&c, OP_DRAW, &draw, sizeof draw);
        emit(&c, OP_REPORT_COUNTER, report, sizeof report); emit(&c, OP_END, NULL, 0);
        mtl_sub_begin(); mtl_exec(c.bytes);
        CHECK(mtl_wait(mtl_sub_commit(), 10000000000ull)); CHECK(!mtl_last_commit_error());
        CHECK(result[QUERIES][0] == (round + 1) * 64);
    }
    vis_clear(); free(c.bytes); free(result);
    printf("PASS %u occlusion reports across buffer rollover; mid-pass start, resets, cumulative reports and cumulative samples across 10 submissions\n", QUERIES + 1);
    return 0;
}}
