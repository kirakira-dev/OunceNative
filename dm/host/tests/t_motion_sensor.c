#include "../dm_motion.h"
#include <math.h>
#include <stdio.h>
#include <string.h>
static uint64_t clock_ns = 1000000000;
uint64_t now_ns(void) { return clock_ns; }
#define CHECK(x) do { if (!(x)) { fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #x); return 1; } } while (0)
static int near(float a, float b) { return fabsf(a-b) < .00002f; }
static void reset(void) { dm_motion_sensor_connected(0); dm_motion_sensor_connected(1); clock_ns += 1000000000; }
int main(void) {
    dm_motion_state state[17];
    float accel[3] = {0,0,-1}, rate[3] = {0}, no_gravity[3] = {0};
    dm_motion_available(1); dm_motion_start(0,1);
    for (int axis = 0; axis < 3; axis++) {
        reset(); memset(rate,0,sizeof rate); rate[axis] = 1.5707963267948966;
        dm_motion_sensor_update(accel,rate,no_gravity);
        for (int tick = 1; tick <= 200; tick++) {
            clock_ns += 5000000;
            dm_motion_sensor_update(accel,rate,no_gravity);
            CHECK(dm_motion_read(state,1,0) == 1);
            CHECK(near(state[0].angle[axis], tick/800.f));
            CHECK(near(state[0].velocity[axis], .25f));
            CHECK(near(state[0].acceleration[2], -1));
            for (int i=0;i<3;i++) for (int j=0;j<3;j++) {
                float dot=0;for(int k=0;k<3;k++)dot+=state[0].direction[i][k]*state[0].direction[j][k];
                CHECK(near(dot,i==j));
            }
        }
        int b=(axis+1)%3,c=(axis+2)%3;
        CHECK(near(state[0].direction[axis][axis],1));
        CHECK(near(state[0].direction[b][c],-1));
        CHECK(near(state[0].direction[c][b],1));
        memset(&state[16],0xa5,sizeof state[16]); dm_motion_state guard=state[16];
        CHECK(dm_motion_read(state,17,0)==16); CHECK(!memcmp(&state[16],&guard,sizeof guard));
        for(int i=0;i<16;i++) { CHECK(state[i].sampling==state[0].sampling-i); CHECK(state[i].delta_ns==5000000); }
        CHECK(!dm_motion_at_rest());
        // A delayed consumer integrates only the 100 ms freshness allowance.
        clock_ns+=10000000000ull;
        CHECK(dm_motion_read(state,1,0)==1);
        CHECK(near(state[0].angle[axis],.275f)); CHECK(near(state[0].velocity[axis],0));
        CHECK(dm_motion_at_rest());
    }
    // Body-axis composition is noncommutative: an X quarter-turn followed by
    // a Y quarter-turn must produce Rx*Ry, not Ry*Rx.
    reset(); memset(rate,0,sizeof rate); rate[0]=1.5707963267948966;
    dm_motion_sensor_update(accel,rate,no_gravity);
    for(int axis=0;axis<2;axis++) {
        memset(rate,0,sizeof rate);rate[axis]=1.5707963267948966;
        dm_motion_sensor_update(accel,rate,no_gravity);
        for(int tick=0;tick<200;tick++) { clock_ns+=5000000;dm_motion_sensor_update(accel,rate,no_gravity); }
    }
    CHECK(dm_motion_read(state,1,0)==1);
    const float composed[3][3]={{0,0,1},{1,0,0},{0,1,0}};
    for(int i=0;i<3;i++)for(int j=0;j<3;j++)CHECK(near(state[0].direction[i][j],composed[i][j]));
    // Gravity initializes arbitrary tilt, including the anti-parallel case.
    memset(rate,0,sizeof rate);
    const float gravity[][3]={{0,-1,0},{1,0,0},{0,0,1},{0,0,-1}};
    for (unsigned n=0;n<sizeof gravity/sizeof gravity[0];n++) {
        reset(); dm_motion_sensor_update(gravity[n],rate,gravity[n]); clock_ns+=5000000;
        CHECK(dm_motion_read(state,1,0)==1);
        for(int i=0;i<3;i++) CHECK(near(-state[0].direction[2][i],gravity[n][i]));
    }
    reset(); dm_motion_sensor_update(accel,rate,accel);
    for(int tick=0;tick<1200;tick++) { clock_ns+=5000000; dm_motion_sensor_update(gravity[0],rate,gravity[0]); }
    CHECK(dm_motion_read(state,1,0)==1); CHECK(-state[0].direction[2][1] < -.999f);
    // Reject an invalid callback atomically; don't contaminate the gyro or accel.
    float invalid[3]={NAN,0,0}; dm_motion_sensor_update(accel,invalid,accel);clock_ns+=5000000;
    CHECK(dm_motion_read(state,1,0)==1);
    CHECK(near(state[0].velocity[0],0)); CHECK(near(state[0].acceleration[1],-1));
    dm_motion_sensor_connected(0); clock_ns+=5000000; CHECK(dm_motion_read(state,1,0)==1);
    for(int i=0;i<3;i++)for(int j=0;j<3;j++) CHECK(near(state[0].direction[i][j],i==j));
    dm_motion_rotate(0,.1f);clock_ns+=5000000;CHECK(dm_motion_read(state,1,0)==1);CHECK(state[0].velocity[2]<0);
    puts("PASS physical motion: XYZ integration, orientation, 200 Hz history, gravity, stale data, invalid callbacks and virtual fallback");
    return 0;
}
