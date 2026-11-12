#include "dm_motion_gamecontroller.h"
#include "dm_motion.h"
static GCController *motion_pad;

void dm_motion_gamecontroller_update(NSArray<GCController *> *controllers) {
    GCController *next = motion_pad && [controllers containsObject:motion_pad] ? motion_pad : nil;
    if (!next) for (GCController *c in controllers) if (c.extendedGamepad && c.motion.hasRotationRate) { next = c; break; }
    if (next == motion_pad) return;
    motion_pad.motion.valueChangedHandler = nil;
    if (motion_pad.motion.sensorsRequireManualActivation) motion_pad.motion.sensorsActive = NO;
    dm_motion_sensor_connected(0);
    motion_pad = next;
    if (!next) return;
    dm_motion_sensor_connected(1);
    next.handlerQueue = dispatch_get_main_queue();
    next.motion.valueChangedHandler = ^(GCMotion *motion) {
        if (motion == motion_pad.motion) dm_motion_gamecontroller_read(motion);
    };
    if (next.motion.sensorsRequireManualActivation) next.motion.sensorsActive = YES;
    dm_motion_gamecontroller_read(next.motion);
}

void dm_motion_gamecontroller_read(GCMotion *motion) {
    if (!motion || !motion.hasRotationRate) return;
    GCRotationRate r = motion.rotationRate;
    GCAcceleration a = motion.acceleration, g = motion.gravity;
    // GCMotion -> SDL sensor axes -> guest axes: gyro XYZ stays XYZ, while
    // acceleration maps (x, -z, y). Keep radians/s here; the HID layer uses turns/s.
    float rate[3] = {r.x, r.y, r.z};
    float accel[3] = {a.x, -a.z, a.y}, gravity[3] = {g.x, -g.z, g.y};
    dm_motion_sensor_update(accel, rate, motion.hasGravityAndUserAcceleration ? gravity : NULL);
}
