#include "dm_motion.h"
#include <math.h>
#include <pthread.h>
#include <string.h>

uint64_t now_ns(void);
static pthread_mutex_t motion_lock = PTHREAD_MUTEX_INITIALIZER;
static int available, started[4], fusion[4] = {1,1,1,1};
static double pitch, yaw, previous_pitch, previous_yaw;
static uint64_t sampled_at, moved_at;
static dm_motion_state sample;
static dm_motion_state history[16];
static unsigned history_head, history_count;

static int slot(uint32_t handle) {
    unsigned id = handle >> 8, side = handle & 255;
    return side < 2 && (id == 0 || id == 0x20) ? (id == 0x20 ? 2 : 0) + side : -1;
}
void dm_motion_available(int value) {
    pthread_mutex_lock(&motion_lock); available = value;
    if (!value) {
        memset(started, 0, sizeof started); sampled_at = 0; memset(&sample, 0, sizeof sample);
        history_head = history_count = 0;
    }
    pthread_mutex_unlock(&motion_lock);
}
void dm_motion_rotate(float dp, float dy) {
    if (!isfinite(dp) || !isfinite(dy)) return;
    pthread_mutex_lock(&motion_lock);
    pitch += dp; yaw -= dy;
    if (dp || dy) moved_at = now_ns();
    pthread_mutex_unlock(&motion_lock);
}
void dm_motion_start(uint32_t handle, int value) {
    int i = slot(handle); if (i < 0) return;
    pthread_mutex_lock(&motion_lock); started[i] = value; pthread_mutex_unlock(&motion_lock);
}
static void record(double p, double y, double dp, double dy) {
    const double tau = 6.2831853071795864769;
    sample.delta_ns = 5000000; sample.sampling++;
    double sp = sin(p), cp = cos(p), sy = sin(y), cy = cos(y);
    // The resting controller has gravity on -Z. Horizontal aim turns about
    // world Z; express its angular velocity in the pitched controller frame.
    sample.velocity[0] = dp / tau * 200;
    sample.velocity[1] = dy * sp / tau * 200;
    sample.velocity[2] = dy * cp / tau * 200;
    for (int axis = 0; axis < 3; axis++) sample.angle[axis] += sample.velocity[axis] / 200;
    float direction[3][3] = {{cy, -sy * cp, sy * sp}, {sy, cy * cp, -cy * sp}, {0, sp, cp}};
    memcpy(sample.direction, direction, sizeof direction);
    for (int axis = 0; axis < 3; axis++) sample.acceleration[axis] = -direction[2][axis];
    sample.attributes = 1;
    history[history_head] = sample; history_head = (history_head + 1) % 16;
    if (history_count < 16) history_count++;
}
int dm_motion_read(dm_motion_state *out, int count, uint32_t handle) {
    int i = slot(handle); if (!out || count <= 0 || i < 0) return 0;
    pthread_mutex_lock(&motion_lock);
    if (!available || !started[i]) { pthread_mutex_unlock(&motion_lock); return 0; }
    uint64_t now = now_ns();
    if (!sampled_at) {
        record(pitch, yaw, 0, 0); sampled_at = now; previous_pitch = pitch; previous_yaw = yaw;
    } else {
        uint64_t steps = (now - sampled_at) / 5000000;
        if (steps) {
            double dp = (pitch - previous_pitch) / steps, dy = (yaw - previous_yaw) / steps;
            uint64_t first = steps > 16 ? steps - 15 : 1;
            sample.sampling += first - 1;
            if (first > 1) {
                double skip_pitch = dp * (first - 1), skip_yaw = dy * (first - 1);
                double end_pitch = previous_pitch + skip_pitch;
                const double tau = 6.2831853071795864769;
                sample.angle[0] += skip_pitch / tau;
                sample.angle[1] += skip_yaw / tau * (fabs(skip_pitch) < 1e-8 ? sin(previous_pitch) :
                    (cos(previous_pitch) - cos(end_pitch)) / skip_pitch);
                sample.angle[2] += skip_yaw / tau * (fabs(skip_pitch) < 1e-8 ? cos(previous_pitch) :
                    (sin(end_pitch) - sin(previous_pitch)) / skip_pitch);
            }
            for (uint64_t step = first; step <= steps; step++)
                record(previous_pitch + dp * step, previous_yaw + dy * step, dp, dy);
            previous_pitch = pitch; previous_yaw = yaw; sampled_at += steps * 5000000;
        }
    }
    if ((unsigned)count > history_count) count = (int)history_count;
    for (int j = 0; j < count; j++) out[j] = history[(history_head + 15 - j) % 16];
    pthread_mutex_unlock(&motion_lock); return count;
}
int dm_motion_at_rest(void) {
    pthread_mutex_lock(&motion_lock); int rest = !moved_at || now_ns() - moved_at > 100000000;
    pthread_mutex_unlock(&motion_lock); return rest;
}
void dm_motion_fusion(uint32_t handle, int enabled) {
    int i = slot(handle); if (i < 0) return;
    pthread_mutex_lock(&motion_lock); fusion[i] = !!enabled; pthread_mutex_unlock(&motion_lock);
}
int dm_motion_fusion_enabled(uint32_t handle) {
    int i = slot(handle); if (i < 0) return 0;
    pthread_mutex_lock(&motion_lock); int value = fusion[i]; pthread_mutex_unlock(&motion_lock); return value;
}
