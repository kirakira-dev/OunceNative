#include "../dm_motion_gamecontroller.h"
#include <math.h>
#include <stdio.h>
static float got_a[3], got_r[3], got_g[3]; static int calls, has_g;
static int connected, connection_changes;
void dm_motion_sensor_connected(int value) { connected=value;connection_changes++; }
@interface FixtureMotion : GCMotion
@property BOOL rotationSupported;
@property BOOL gravitySupported;
@property BOOL enabled;
@property(copy) GCMotionValueChangedHandler fixtureHandler;
@end
@implementation FixtureMotion
- (BOOL)hasRotationRate { return self.rotationSupported; }
- (BOOL)hasGravityAndUserAcceleration { return self.gravitySupported; }
- (BOOL)sensorsRequireManualActivation { return YES; }
- (BOOL)sensorsActive { return self.enabled; }
- (void)setSensorsActive:(BOOL)value { self.enabled=value; }
- (GCMotionValueChangedHandler)valueChangedHandler { return self.fixtureHandler; }
- (void)setValueChangedHandler:(GCMotionValueChangedHandler)value { self.fixtureHandler=value; }
- (GCAcceleration)acceleration { return (GCAcceleration){.4,-.8,-.2}; }
- (GCAcceleration)gravity { return (GCAcceleration){.1,-.9,.2}; }
- (GCRotationRate)rotationRate { return (GCRotationRate){.5,-.6,.7}; }
@end
@interface FixtureController : GCController
@property FixtureMotion *fixtureMotion;
@property GCController *snapshot;
@end
@implementation FixtureController
- (GCMotion *)motion { return self.fixtureMotion; }
- (GCExtendedGamepad *)extendedGamepad { return self.snapshot.extendedGamepad; }
@end
void dm_motion_sensor_update(const float a[3], const float r[3], const float g[3]) {
    memcpy(got_a,a,sizeof got_a);memcpy(got_r,r,sizeof got_r);has_g=g!=NULL;
    if(g)memcpy(got_g,g,sizeof got_g);calls++;
}
#define CHECK(x) do { if (!(x)) { fprintf(stderr,"FAIL line %d: %s\n",__LINE__,#x);return 1;} } while(0)
int main(void) { @autoreleasepool {
    // Apple's generic snapshot does not expose a motion-capable profile on this
    // SDK. Exercise the adapter with controlled public GCMotion accessors.
    FixtureMotion *m=[FixtureMotion new];m.rotationSupported=YES;m.gravitySupported=YES;
    dm_motion_gamecontroller_read(m);CHECK(calls==1 && has_g);
    CHECK(fabs(got_a[0]-.4)<1e-6 && fabs(got_a[1]-.2)<1e-6 && fabs(got_a[2]+.8)<1e-6);
    CHECK(fabs(got_r[0]-.5)<1e-6 && fabs(got_r[1]+.6)<1e-6 && fabs(got_r[2]-.7)<1e-6);
    CHECK(fabs(got_g[0]-.1)<1e-6 && fabs(got_g[1]+.2)<1e-6 && fabs(got_g[2]+.9)<1e-6);
    m.gravitySupported=NO;dm_motion_gamecontroller_read(m);CHECK(calls==2 && !has_g);
    m.rotationSupported=NO;dm_motion_gamecontroller_read(m);CHECK(calls==2);
    dm_motion_gamecontroller_read(nil);CHECK(calls==2);
    FixtureController *a=[FixtureController new], *b=[FixtureController new];
    a.snapshot=[GCController controllerWithExtendedGamepad];b.snapshot=a.snapshot;
    a.fixtureMotion=m;b.fixtureMotion=[FixtureMotion new];b.fixtureMotion.rotationSupported=YES;
    dm_motion_gamecontroller_update(@[]);CHECK(connection_changes==0);
    dm_motion_gamecontroller_update(@[a]);CHECK(connection_changes==0); // unsupported
    m.rotationSupported=YES;
    dm_motion_gamecontroller_update(@[a,b]);CHECK(connected && m.enabled && !b.motion.sensorsActive);
    CHECK(connection_changes==2 && calls==3 && m.valueChangedHandler);
    GCMotionValueChangedHandler old=m.valueChangedHandler;
    old(m);CHECK(calls==4);
    dm_motion_gamecontroller_update(@[b,a]);CHECK(connection_changes==2 && calls==4); // stable selection
    dm_motion_gamecontroller_update(@[b]);CHECK(connection_changes==4 && calls==5);
    CHECK(!m.enabled && !m.valueChangedHandler && b.motion.sensorsActive);
    old(m);CHECK(calls==5); // an already-queued callback from the old device
    dm_motion_gamecontroller_update(@[]);CHECK(!connected && connection_changes==5);
    CHECK(!b.motion.sensorsActive && !b.motion.valueChangedHandler);
    puts("PASS GameController fixture: axes/units, capabilities, activation, selection, disconnect and stale callbacks");
    return 0;
} }
