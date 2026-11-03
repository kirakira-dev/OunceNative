#include "../nvn/nvn_mtl.m"
int prog_key(const prog_t *p, unsigned stage, uint8_t key[8]) { memset(key, 0, 8); return 0; }
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { return NULL; }
module_t g_mod[MAX_MOD]; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
uint64_t nvn_new_serial(void) { static uint64_t serial = 99000; return ++serial; }
#define CHECK(x) do { if (!(x)) { fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #x); return 1; } } while (0)
typedef struct { uint8_t *bytes; size_t length; } commands;
static void emit(commands *c, unsigned op, const void *data, size_t size) {
    uint32_t total = (size + 15) & ~7u; op_hdr header = {op, total};
    memcpy(c->bytes + c->length, &header, 8);
    if (size) memcpy(c->bytes + c->length + 8, data, size);
    c->length += total;
}
int main(void) { @autoreleasepool {
    CHECK(DM_GAME_RENDER_COND); mtl_init(); state_reset();
    enum { REPORTS = 8192 };
    uint64_t (*queries)[2] = calloc(REPORTS, sizeof *queries); CHECK(queries);
    tex_t target = {.magic = MAGIC('T','E','X',0), .serial = nvn_new_serial()};
    target.d = (nvn_texdesc){.target = NVN_TEXTURE_TARGET_2D, .format = NVN_FORMAT_RGBA8,
        .width = 8, .height = 8, .depth = 1, .levels = 1, .samples = 1};
    commands c = {.bytes = calloc(1, REPORTS * 24 + 4096)}; CHECK(c.bytes);
    for (unsigned i = 0; i < REPORTS; i++) {
        uint64_t report[] = {NVN_COUNTER_TYPE_SAMPLES_PASSED, (uint64_t)queries[i]};
        emit(&c, OP_REPORT_COUNTER, report, sizeof report);
    }
    uint64_t condition[4] = {1, 0, 0, 0};
    p_set_rt rt = {.n = 1}; rt.color[0] = &target;
    p_render_cond cond = {1, 0, (uint64_t)condition}, enabled = {2, 0, 0};
    p_clear_color red = {.index = 0, .rgba = {1,0,0,1}, .mask = 15};
    p_clear_color black = {.index = 0, .rgba = {0,0,0,1}, .mask = 15};
    uint64_t timestamp[] = {NVN_COUNTER_TYPE_TIMESTAMP_TOP, (uint64_t)condition};
    emit(&c, OP_SET_RT, &rt, sizeof rt); emit(&c, OP_RENDER_COND, &cond, sizeof cond);
    emit(&c, OP_CLEAR_COLOR, &red, sizeof red);
    emit(&c, OP_REPORT_COUNTER, timestamp, sizeof timestamp);
    emit(&c, OP_RENDER_COND, &enabled, sizeof enabled);
    emit(&c, OP_SET_RT, &rt, sizeof rt); emit(&c, OP_RENDER_COND, &cond, sizeof cond);
    emit(&c, OP_CLEAR_COLOR, &black, sizeof black);
    emit(&c, OP_RENDER_COND, &enabled, sizeof enabled); emit(&c, OP_END, NULL, 0);
    mtl_sub_begin(); mtl_exec(c.bytes);
    CHECK(mtl_wait(mtl_sub_commit(), 10000000000ull)); CHECK(!mtl_last_commit_error());
    id<MTLTexture> texture = tex_mtl(&target);
    id<MTLBuffer> pixels = [g_dev newBufferWithLength:8 * 8 * 4 options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> cb = q_cb(); id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
    [blit copyFromTexture:texture sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0)
        sourceSize:MTLSizeMake(8,8,1) toBuffer:pixels destinationOffset:0 destinationBytesPerRow:32 destinationBytesPerImage:256];
    [blit endEncoding]; [cb commit]; [cb waitUntilCompleted]; CHECK(!cb.error);
    const uint8_t *bytes = pixels.contents;
    for (unsigned i = 0; i < 64; i++) CHECK(bytes[i*4] == 255 && !bytes[i*4+1] && !bytes[i*4+2] && bytes[i*4+3] == 255);
    CHECK(!condition[0]); uint64_t value;
    for (unsigned i = 0; i < REPORTS; i++) CHECK(!rc_value((uint64_t)queries[i], &value));
    rc_note((uint64_t)queries[0], 1);
    CHECK(rc_value((uint64_t)queries[0], &value) && value == 0);
    mtl_sub_begin(); condition[0] = 1;
    CHECK(rc_value((uint64_t)condition, &value) && value == 1);
    CHECK(mtl_wait(mtl_sub_commit(), 10000000000ull));
    printf("PASS conditional clear after %u reports; 64 red pixels preserved; pending reset and occlusion history\n", REPORTS);
    free(c.bytes); free(queries); return 0;
}}
