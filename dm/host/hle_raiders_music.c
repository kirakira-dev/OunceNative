// Raiders v65536: mute the music groups after their own volume calculation.
// The source volume, ducking, playback position and sound-effect groups remain
// owned by the game. Turning music back on recomputes the current game mix.
#include "dm.h"
#include "dm_raiders_music.h"
#include <stdatomic.h>

#define RAIDERS_MUSIC_BUILD "663c2e087a083f05307f229dfc4042d5"
static _Atomic int g_music = 1;
static pthread_once_t g_music_once = PTHREAD_ONCE_INIT;
static pthread_once_t g_image_once = PTHREAD_ONCE_INIT;
static uint8_t *g_music_main;
static int g_music_diagnostics;
static int g_reported[8];
static const char *const music_groups[] = {
    "Bgm_Default", "Bgm_SceneBridge", "Demo_Bgm", "Demo_BgmSceneBridge",
    "Minigame_Bgm", "WorldBgm", "UI_Jingle", "UI_Fanfare",
};
int dm_guest_heap_readable(uint64_t address, size_t length);

static void music_init(void) {
    const char *s = getenv("DM_MUSIC");
    atomic_store(&g_music, !s || strcmp(s, "0"));
    g_music_diagnostics = getenv("DM_MUSIC_DIAGNOSTICS") != NULL;
    for (unsigned i = 0; i < sizeof g_reported / sizeof *g_reported; i++) g_reported[i] = -1;
}
static void image_init(void) {
    if (DM_GAME_PROGRAM_ID != 0x0400380020056000ull || strcmp(dm_main_build(), RAIDERS_MUSIC_BUILD)) return;
    for (int i = 0; i < g_nmod; i++) if (!strcmp(g_mod[i].name, "main")) g_music_main = g_mod[i].base;
}
int dm_raiders_music_available(void) {
    if (!g_nmod || !gate_obs_present(OBS_RAIDERS_MUSIC_BEGIN) || !gate_obs_present(OBS_RAIDERS_MUSIC_END)) return 0;
    pthread_once(&g_image_once, image_init);
    return g_music_main != NULL;
}
int dm_raiders_music_get(void) {
    pthread_once(&g_music_once, music_init);
    return atomic_load(&g_music);
}
void dm_raiders_music_set(int enabled) {
    pthread_once(&g_music_once, music_init);
    atomic_store(&g_music, !!enabled);
}
static int music_group(uint64_t p) {
    if (!dm_raiders_music_available() || !dm_guest_heap_readable(p, 0x170)) return -1;
    uint64_t vt, name, buffer;
    uint32_t capacity;
    memcpy(&vt, (void *)p, 8);
    memcpy(&name, (void *)(p + 8), 8);
    memcpy(&buffer, (void *)(p + 0x10), 8);
    memcpy(&capacity, (void *)(p + 0x18), 4);
    // Only SoundGroup leaves, with the inline 32-byte name buffer used by this
    // exact executable. Folders, voices and ambience never match the list.
    if (vt != (uint64_t)(g_music_main + 0x4bf14a0) || name != p + 0x1c || buffer != name || capacity != 32) return -1;
    for (unsigned i = 0; i < sizeof music_groups / sizeof *music_groups; i++)
        if (!strncmp((const char *)name, music_groups[i], 32)) return (int)i;
    return -1;
}
static void music_begin(const uint64_t *regs) {
    uint64_t p = regs[0];
    if (music_group(p) < 0) return;
    // main+35c88f0 computes +110 from +90 (default), +d0 (dynamic) and
    // the parent's +110 when +71/+72 is dirty. Force that calculation so
    // a previously muted cached result is restored on the next audio update.
    dm_guest_write_prepare((void *)(p + 0x71), 1);
    *(uint8_t *)(p + 0x71) = 1;
}
static void music_end(const uint64_t *regs) {
    // The caller at main+3537744 advances its group-array pointer before
    // calling the update. Its callee-saved x20 still points one entry past it.
    if (regs[20] < 8 || !dm_guest_heap_readable(regs[20] - 8, 8)) return;
    uint64_t p;
    memcpy(&p, (void *)(regs[20] - 8), 8);
    int index = music_group(p);
    if (index < 0) return;
    int enabled = dm_raiders_music_get();
    float original;
    memcpy(&original, (void *)(p + 0x110), 4);
    if (!enabled) {
        const float zero = 0;
        dm_guest_write_prepare((void *)(p + 0x110), 4);
        memcpy((void *)(p + 0x110), &zero, 4);
    }
    if (g_music_diagnostics && g_reported[index] != enabled) {
        g_reported[index] = enabled;
        LOG("Raiders music: %s %s, game volume %.6f, output %.6f", music_groups[index], enabled ? "on" : "off", original, enabled ? original : 0);
    }
}
__attribute__((constructor)) static void register_music(void) {
    gate_obs_set(OBS_RAIDERS_MUSIC_BEGIN, music_begin);
    gate_obs_set(OBS_RAIDERS_MUSIC_END, music_end);
}
