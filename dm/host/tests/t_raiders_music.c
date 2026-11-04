#include "../hle_raiders_music.c"
#include <assert.h>

module_t g_mod[MAX_MOD];
int g_nmod;
static uint8_t heap[0x1000];
static void (*callbacks[OBS_MAX])(const uint64_t *);
int dm_guest_heap_readable(uint64_t p, size_t n) {
    uintptr_t start = (uintptr_t)heap;
    return p >= start && n <= sizeof heap && p - start <= sizeof heap - n;
}
void dm_guest_write_prepare(void *p, size_t n) { assert(dm_guest_heap_readable((uintptr_t)p, n)); }
void gate_obs_set(int id, void (*fn)(const uint64_t *)) { assert(id > 0 && id < OBS_MAX); callbacks[id] = fn; }
int gate_obs_present(int id) { return id > 0 && id < OBS_MAX && callbacks[id] != NULL; }
static void put64(uint8_t *p, uint64_t x) { memcpy(p, &x, 8); }
static void put32(uint8_t *p, uint32_t x) { memcpy(p, &x, 4); }
static void putf(uint8_t *p, float x) { memcpy(p, &x, 4); }
static float getf(uint8_t *p) { float x; memcpy(&x, p, 4); return x; }
static void group(uint8_t *p, uint8_t *image, const char *name) {
    memset(p, 0, 0x170);
    put64(p, (uintptr_t)(image + 0x4bf14a0));
    put64(p + 8, (uintptr_t)(p + 0x1c)); put64(p + 0x10, (uintptr_t)(p + 0x1c));
    put32(p + 0x18, 32); snprintf((char *)p + 0x1c, 32, "%s", name);
    putf(p + 0x90, .75f); putf(p + 0xd0, .5f); putf(p + 0x110, .375f);
    putf(p + 0x94, 1.2f); putf(p + 0x114, 1.2f);
}
// The two original multiply operations at main+353c3e0/+353c100 are
// between the hooks. Model the dirty-cache behavior to catch failure to
// recover a previously zeroed result when music is re-enabled.
static void update(uint8_t *p, float parent) {
    uint64_t regs[31] = {0}; regs[0] = (uintptr_t)p;
    put64(heap + 0x800, (uintptr_t)p); regs[20] = (uintptr_t)(heap + 0x808);
    callbacks[OBS_RAIDERS_MUSIC_BEGIN](regs);
    p[0x73] = 0;
    if (p[0x71] || p[0x72]) { putf(p + 0x110, getf(p + 0x90) * getf(p + 0xd0) * parent); p[0x73] = 1; }
    callbacks[OBS_RAIDERS_MUSIC_END](regs);
    p[0x71] = p[0x72] = 0;
}
int main(int argc, char **argv) {
    assert(!dm_raiders_music_available());
    uint8_t *image = calloc(1, 0x4e40000); assert(image);
    g_nmod = 1; strcpy(g_mod[0].name, "main"); g_mod[0].base = image;
    strcpy(g_mod[0].build_id, argc > 1 ? argv[1] : RAIDERS_MUSIC_BUILD);
    if (argc > 1) { assert(!dm_raiders_music_available()); free(image); puts("music: wrong build rejected"); return 0; }
    assert(dm_raiders_music_available());
    setenv("DM_MUSIC", "0", 1); assert(!dm_raiders_music_get());
    for (unsigned i = 0; i < sizeof music_groups / sizeof *music_groups; i++) {
        group(heap, image, music_groups[i]);
        dm_raiders_music_set(0); update(heap, .25f);
        assert(getf(heap + 0x110) == 0 && heap[0x73] == 1);
        assert(getf(heap + 0x90) == .75f && getf(heap + 0xd0) == .5f && getf(heap + 0x114) == 1.2f);
        // Game ducking can change while muted; restore the new value, not 1.
        putf(heap + 0xd0, .125f); dm_raiders_music_set(1); update(heap, .5f);
        assert(getf(heap + 0x110) == .046875f);
        dm_raiders_music_set(0); update(heap, .5f); assert(getf(heap + 0x110) == 0);
    }
    const char *effects[] = {"Script_Voice", "Demo_Default", "Actor_Default", "InkSpray", "Ambience_Default", "UI_Default", "Bgm_Default_extra"};
    for (unsigned i = 0; i < sizeof effects / sizeof *effects; i++) {
        group(heap, image, effects[i]); uint8_t before[0x170]; memcpy(before, heap, sizeof before);
        update(heap, .5f); assert(!memcmp(before, heap, sizeof before));
    }
    group(heap, image, "Bgm_Default"); put64(heap, (uintptr_t)(image + 0x4bf1358));
    update(heap, 1); assert(getf(heap + 0x110) == .375f);
    group(heap, image, "Bgm_Default"); put64(heap + 8, 1);
    update(heap, 1); assert(getf(heap + 0x110) == .375f);
    uint64_t regs[31] = {0}; regs[0] = 1; regs[20] = 1;
    callbacks[OBS_RAIDERS_MUSIC_BEGIN](regs); callbacks[OBS_RAIDERS_MUSIC_END](regs);
    free(image); puts("music: eight groups, live mute/restore, ducking, effects and invalid-object guards pass");
}
