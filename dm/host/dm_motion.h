#pragma once
#include <stdint.h>

typedef struct {
    uint64_t delta_ns, sampling;
    float acceleration[3], velocity[3], angle[3], direction[3][3];
    uint32_t attributes, reserved;
} dm_motion_state;
_Static_assert(sizeof(dm_motion_state) == 0x60, "six-axis state ABI");

void dm_motion_available(int available);
void dm_motion_rotate(float pitch_radians, float yaw_radians);
void dm_motion_start(uint32_t handle, int started);
int dm_motion_read(dm_motion_state *out, int count, uint32_t handle);
int dm_motion_at_rest(void);
void dm_motion_fusion(uint32_t handle, int enabled);
int dm_motion_fusion_enabled(uint32_t handle);
