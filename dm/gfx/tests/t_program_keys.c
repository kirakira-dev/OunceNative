#include "../nvn/hle_nvn.c"
#include <time.h>
uint64_t g_t0_ns;
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { return NULL; }
module_t g_mod[MAX_MOD]; int g_nmod;
void svc_thread_dump(void) {}
int dm_guest_as_contains(uintptr_t address) { return 0; }
uint64_t now_ns(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return (uint64_t)t.tv_sec * 1000000000ull + t.tv_nsec; }
#define CHECK(x) do { if (!(x)) { fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #x); return 1; } } while (0)
static void word(void *p, unsigned off, uint32_t value) { memcpy((uint8_t *)p + off, &value, 4); }

int main(int argc, char **argv) {
    if (argc > 1) setenv("DM_NVN_SHDUMP", "/unused", 1);
    CHECK(DM_GAME_NX2);
    uint8_t ctl[224], code[32], expected[CC_SHA256_DIGEST_LENGTH], got[8];
    NVNprogram program; CHECK(h_nvnProgramInitialize(&program, NULL));
    for (unsigned revision = 0; revision < 64; revision++) {
        memset(ctl, 0, sizeof ctl); word(ctl, 0, 0x98761234); word(ctl, 0x30, sizeof ctl);
        word(ctl, 0x38, sizeof code); word(ctl, 0x44, sizeof code);
        for (unsigned i = 0; i < sizeof code; i++) code[i] = i * 7 + revision;
        CC_SHA256_CTX hash; CC_SHA256_Init(&hash); CC_SHA256_Update(&hash, ctl, sizeof ctl);
        CC_SHA256_Update(&hash, code, sizeof code); CC_SHA256_Final(expected, &hash);
        NVNshaderData data = {.data=(NVNbufferAddress)(uintptr_t)code, .control=ctl};
        CHECK(h_nvnProgramSetShaders(&program, 1, &data));
        CHECK(pk_get(&program, 0)->ok == 0); // Code is deliberately outside registered pools.
        memset(ctl, 0xa5, sizeof ctl);
        CHECK(prog_key((prog_t *)&program, 0, got)); CHECK(!memcmp(got, expected, sizeof got));
    }
    CHECK(!prog_key((prog_t *)&program, 1, got));
    CHECK(h_nvnProgramSetShaders(&program, 0, NULL));
    for (unsigned i = 0; i < 6; i++) CHECK(!pk_get(&program, 0)->control[i]);
    h_nvnProgramFinalize(&program); CHECK(!pk_get(&program, 0));
    printf("PASS 64 deferred shader keys after caller control reuse, replacement and finalize (%s capture)\n", argc > 1 ? "with" : "without");
    return 0;
}
