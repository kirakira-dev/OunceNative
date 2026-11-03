#include "../dm_motion.h"
#include <math.h>
#include <stdio.h>
#include <string.h>
static uint64_t clock_ns = 1000000000;
uint64_t now_ns(void) { return clock_ns; }
#define CHECK(x) do { if (!(x)) { fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #x); return 1; } } while (0)
static int near(float a, float b) { return fabsf(a-b) < 0.00001f; }
int main(void) {
    dm_motion_state state[2], previous;
    memset(state, 0xa5, sizeof state); previous = state[0];
    dm_motion_start(0, 1); CHECK(!dm_motion_read(state, 1, 0)); CHECK(!memcmp(state, &previous, sizeof previous));
    dm_motion_available(1); CHECK(dm_motion_read(state, 2, 0) == 1);
    CHECK(state[0].attributes == 1 && state[0].sampling == 1 && state[0].delta_ns == 5000000);
    CHECK(!memcmp(&state[1], &previous, sizeof previous));
    CHECK(near(state[0].acceleration[2], -1));
    for (int i = 0; i < 3; i++) for (int j = 0; j < 3; j++) CHECK(near(state[0].direction[i][j], i == j));
    CHECK(!dm_motion_read(state, 0, 0)); CHECK(!dm_motion_read(state, 1, 0x2000));
    dm_motion_start(0x2000, 1); CHECK(dm_motion_read(state, 1, 0x2000) == 1);
    dm_motion_rotate(0, 1.5707963267948966f); clock_ns += 100000000;
    CHECK(dm_motion_read(state, 1, 0) == 1); CHECK(near(state[0].angle[2], -.25f)); CHECK(near(state[0].velocity[2], -2.5f));
    CHECK(near(state[0].direction[0][1], 1) && near(state[0].direction[1][0], -1));
    CHECK(near(state[0].acceleration[0], 0) && near(state[0].acceleration[2], -1)); CHECK(!dm_motion_at_rest());
    dm_motion_state recent[17]; memset(recent, 0xa5, sizeof recent);
    CHECK(dm_motion_read(recent, 17, 0) == 16);
    for (int i = 0; i < 16; i++) {
        CHECK(recent[i].sampling == 21u - i && recent[i].delta_ns == 5000000);
        CHECK(near(recent[i].angle[2], -.25f * (20 - i) / 20));
        CHECK(near(recent[i].velocity[2], -2.5f));
    }
    CHECK(!memcmp(&recent[16], &state[1], sizeof recent[16]));
    previous = state[0]; CHECK(dm_motion_read(state, 1, 0) == 1); CHECK(!memcmp(state, &previous, sizeof previous));
    clock_ns += 5000000; CHECK(dm_motion_read(state, 1, 0) == 1); CHECK(near(state[0].velocity[2], 0)); CHECK(dm_motion_at_rest());
    dm_motion_rotate(.3f, -.7f); clock_ns += 5000000; CHECK(dm_motion_read(state, 1, 0) == 1);
    for (int i = 0; i < 3; i++) for (int j = 0; j < 3; j++) {
        float dot = 0; for (int k = 0; k < 3; k++) dot += state[0].direction[i][k] * state[0].direction[j][k];
        CHECK(near(dot, i == j));
    }
    previous = state[0]; dm_motion_rotate(NAN, 1); clock_ns += 5000000; CHECK(dm_motion_read(state, 1, 0) == 1);
    CHECK(!memcmp(state[0].direction, previous.direction, sizeof previous.direction));
    dm_motion_fusion(0, 0); CHECK(!dm_motion_fusion_enabled(0)); CHECK(dm_motion_fusion_enabled(0x2000));
    dm_motion_start(0, 0); CHECK(!dm_motion_read(state, 1, 0)); CHECK(dm_motion_read(state, 1, 0x2000) == 1);
    dm_motion_available(0); CHECK(!dm_motion_read(state, 1, 0x2000)); CHECK(!dm_motion_read(state, 1, 0x0100));
    puts("PASS motion ABI, handles, 200 Hz history, rotation, angular velocity, gravity, rest and invalid input");
    return 0;
}
