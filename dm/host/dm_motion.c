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
static int sensor_connected, sensor_valid;
static uint64_t sensor_at;
static float sensor_accel[3], sensor_rate[3], sensor_gravity[3];
static int sensor_has_gravity;
static double sensor_q[4] = {0, 0, 0, 1}; // body to world, x/y/z/w
static void advance(uint64_t now);

static void save_sample(void) {
    history[history_head] = sample; history_head = (history_head + 1) % 16;
    if (history_count < 16) history_count++;
}
static void sensor_matrix(void) {
    double x = sensor_q[0], y = sensor_q[1], z = sensor_q[2], w = sensor_q[3];
    float r[3][3] = {{1-2*(y*y+z*z), 2*(x*y-z*w), 2*(x*z+y*w)},
                     {2*(x*y+z*w), 1-2*(x*x+z*z), 2*(y*z-x*w)},
                     {2*(x*z-y*w), 2*(y*z+x*w), 1-2*(x*x+y*y)}};
    memcpy(sample.direction, r, sizeof r);
}
static void sensor_integrate(double dt) {
    double v[3] = {sensor_rate[0], sensor_rate[1], sensor_rate[2]};
    const float *g = sensor_has_gravity ? sensor_gravity : sensor_accel;
    double length = sqrt(g[0]*g[0] + g[1]*g[1] + g[2]*g[2]);
    // Correct tilt only when gravity is usable. Yaw remains relative; integrating
    // all three gyro axes preserves roll and avoids Euler-angle singularities.
    if (length > .9 && length < 1.1) {
        double m[3] = {g[0]/length, g[1]/length, g[2]/length};
        double p[3] = {-sample.direction[2][0], -sample.direction[2][1], -sample.direction[2][2]};
        for (int i = 0; i < 3; i++) v[i] += 2 * (m[(i+1)%3]*p[(i+2)%3] - m[(i+2)%3]*p[(i+1)%3]);
    }
    double speed = sqrt(v[0]*v[0] + v[1]*v[1] + v[2]*v[2]);
    double factor = speed > 1e-12 ? sin(speed*dt/2)/speed : dt/2;
    double a[4]; memcpy(a, sensor_q, sizeof a);
    double b[4] = {v[0]*factor, v[1]*factor, v[2]*factor, cos(speed*dt/2)};
    sensor_q[0] = a[3]*b[0] + a[0]*b[3] + a[1]*b[2] - a[2]*b[1];
    sensor_q[1] = a[3]*b[1] - a[0]*b[2] + a[1]*b[3] + a[2]*b[0];
    sensor_q[2] = a[3]*b[2] + a[0]*b[1] - a[1]*b[0] + a[2]*b[3];
    sensor_q[3] = a[3]*b[3] - a[0]*b[0] - a[1]*b[1] - a[2]*b[2];
    double norm = 0; for (int i = 0; i < 4; i++) norm += sensor_q[i]*sensor_q[i];
    norm = sqrt(norm); for (int i = 0; i < 4; i++) sensor_q[i] /= norm;
    for (int i = 0; i < 3; i++) sample.angle[i] += sensor_rate[i] * dt / 6.2831853071795864769;
    sensor_matrix();
}
static void record_sensor(uint64_t time, uint64_t span, int save) {
    // Stop extrapolating a lost Bluetooth stream after 100 ms. Do not integrate
    // a stale angular velocity indefinitely while the game keeps polling.
    uint64_t end = sensor_at + 100000000, start = time - span;
    uint64_t active_end = time < end ? time : end;
    if (sensor_valid && active_end > start) sensor_integrate((active_end-start)*1e-9);
    int fresh = sensor_valid && time <= end;
    for (int i = 0; i < 3; i++) {
        sample.acceleration[i] = sensor_valid ? sensor_accel[i] : (i == 2 ? -1 : 0);
        sample.velocity[i] = fresh ? sensor_rate[i] / 6.2831853071795864769 : 0;
    }
    sample.delta_ns = 5000000; sample.attributes = 1;
    if (save) { sample.sampling++; save_sample(); }
}
void dm_motion_sensor_connected(int connected) {
    pthread_mutex_lock(&motion_lock);
    if (sensor_connected != !!connected) {
        sensor_connected = !!connected; sensor_valid = 0; sensor_at = 0;
        sampled_at = 0; history_head = history_count = 0;
        uint64_t sampling = sample.sampling;
        memset(&sample, 0, sizeof sample); sample.sampling = sampling;
        memset(sensor_q, 0, sizeof sensor_q); sensor_q[3] = 1; sensor_matrix();
    }
    pthread_mutex_unlock(&motion_lock);
}
void dm_motion_sensor_update(const float accel[3], const float rate[3], const float gravity[3]) {
    if (!accel || !rate) return;
    for (int i = 0; i < 3; i++) if (!isfinite(accel[i]) || !isfinite(rate[i]) || (gravity && !isfinite(gravity[i]))) return;
    pthread_mutex_lock(&motion_lock);
    if (!sensor_connected) { pthread_mutex_unlock(&motion_lock); return; }
    uint64_t now = now_ns(); advance(now);
    memcpy(sensor_accel, accel, sizeof sensor_accel); memcpy(sensor_rate, rate, sizeof sensor_rate);
    sensor_has_gravity = gravity != NULL;
    if (gravity) memcpy(sensor_gravity, gravity, sizeof sensor_gravity);
    if (!sensor_valid) {
        const float *g = gravity ? gravity : accel;
        double length = sqrt(g[0]*g[0] + g[1]*g[1] + g[2]*g[2]);
        if (length > .9 && length < 1.1) {
            // Shortest rotation taking measured gravity onto world -Z.
            double q[4] = {-g[1]/length, g[0]/length, 0, 1-g[2]/length};
            double norm = sqrt(q[0]*q[0] + q[1]*q[1] + q[3]*q[3]);
            if (norm < 1e-8) { q[0] = 1; q[1] = q[2] = q[3] = 0; norm = 1; }
            for (int i = 0; i < 4; i++) sensor_q[i] = q[i]/norm;
            sensor_matrix();
        }
    }
    sensor_valid = 1; sensor_at = now;
    double motion = 0, acceleration = 0;
    for (int i = 0; i < 3; i++) { motion += rate[i]*rate[i]; acceleration += accel[i]*accel[i]; }
    if (motion > .0004 || acceleration < .81 || acceleration > 1.21) moved_at = now;
    pthread_mutex_unlock(&motion_lock);
}

static int slot(uint32_t handle) {
    unsigned id = handle >> 8, side = handle & 255;
    return side < 2 && (id == 0 || id == 0x20) ? (id == 0x20 ? 2 : 0) + side : -1;
}
void dm_motion_available(int value) {
    pthread_mutex_lock(&motion_lock); available = value;
    if (!value) {
        memset(started, 0, sizeof started); sampled_at = 0; memset(&sample, 0, sizeof sample);
        history_head = history_count = 0;
        sensor_valid = 0; memset(sensor_q, 0, sizeof sensor_q); sensor_q[3] = 1;
        if (sensor_connected) sensor_matrix();
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
    save_sample();
}
static void advance(uint64_t now) {
    if (!sampled_at) {
        if (sensor_connected) record_sensor(now, 0, 1);
        else record(pitch, yaw, 0, 0);
        sampled_at = now; previous_pitch = pitch; previous_yaw = yaw;
    } else {
        uint64_t steps = (now - sampled_at) / 5000000;
        if (steps) {
            if (sensor_connected) {
                uint64_t skip = steps > 16 ? steps-16 : 0;
                if (skip) { record_sensor(sampled_at+skip*5000000, skip*5000000, 0); sample.sampling += skip; }
                for (uint64_t step = skip+1; step <= steps; step++) record_sensor(sampled_at+step*5000000, 5000000, 1);
                sampled_at += steps*5000000; return;
            }
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
}
int dm_motion_read(dm_motion_state *out, int count, uint32_t handle) {
    int i = slot(handle); if (!out || count <= 0 || i < 0) return 0;
    pthread_mutex_lock(&motion_lock);
    if (!available || !started[i]) { pthread_mutex_unlock(&motion_lock); return 0; }
    advance(now_ns());
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
