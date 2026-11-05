#include "../hle_raiders_mods.c"
#include <assert.h>

module_t g_mod[MAX_MOD];int g_nmod;
static uint8_t heap[0x20000];
static void (*callbacks[OBS_MAX])(const uint64_t *);
static unsigned writes;
static uint64_t tick=1000000000,buttons;
static int32_t axis_x,axis_y;
static unsigned positions,velocities;
static float last_body[4][3];
uint64_t now_ns(void) { return tick; }
void dm_input_current(uint64_t *b,int32_t *x,int32_t *y) { *b=buttons;*x=axis_x;*y=axis_y; }
static float radius(uint64_t c) { (void)c;return 1.0f; }
static void body_position(uint64_t b,const float *v) {
    assert(b>=(uintptr_t)(heap+0x12000)&&b<(uintptr_t)(heap+0x12400));
    memcpy(last_body[(b-(uintptr_t)(heap+0x12000))/0x100],v,12);positions++;
}
static void body_velocity(uint64_t b,const float *v,int flags) {
    (void)b;assert(!v[0]&&!v[1]&&!v[2]&&!flags);velocities++;
}
int dm_guest_heap_readable(uint64_t p,size_t n) {
    uintptr_t b=(uintptr_t)heap;return p>=b && n<=sizeof heap && p-b<=sizeof heap-n;
}
void dm_guest_write_prepare(void *p,size_t n) { assert(dm_guest_heap_readable((uintptr_t)p,n));writes++; }
void gate_obs_set(int id,void (*fn)(const uint64_t *)) { assert(id>0&&id<OBS_MAX);callbacks[id]=fn; }
int gate_obs_present(int id) { return id>0&&id<OBS_MAX&&callbacks[id]!=NULL; }
static void put64(void *p,uint64_t v) {memcpy(p,&v,8);}
static void put32(void *p,uint32_t v) {memcpy(p,&v,4);}
static uint32_t get32(void *p) {uint32_t v;memcpy(&v,p,4);return v;}
int main(int argc,char **argv) {
    assert(DM_GAME_PROGRAM_ID==0x0400380020056000ull);
    assert(!dm_raiders_mods_available());
    uint8_t *image=calloc(1,0x4e40000);assert(image);
    g_nmod=1;strcpy(g_mod[0].name,"main");strcpy(g_mod[0].build_id,argc>1?argv[1]:RAIDERS_BUILD);g_mod[0].base=image;
    void (*ready)(const uint64_t *)=callbacks[OBS_RAIDERS_SHOOT_READY];
    callbacks[OBS_RAIDERS_SHOOT_READY]=NULL;assert(!dm_raiders_mods_available());
    dm_raiders_mods_set(3);assert(!dm_raiders_mods_get());callbacks[OBS_RAIDERS_SHOOT_READY]=ready;
    if(argc>1) {assert(!dm_raiders_mods_available());dm_raiders_mods_set(3);assert(!dm_raiders_mods_get());free(image);puts("wrong build rejected");return 0;}
    uint8_t *s=heap+0x4000,*p=heap+0x1000,*owner=heap+0x5000;uint32_t key=0x13735e37;
    put64(image+0x4d24140,(uintptr_t)heap);put32(heap,key);
    put64(s,(uintptr_t)(image+0x4b24de8));put64(p,(uintptr_t)(image+0x4b1f698));put64(s+0x2b0,(uintptr_t)owner);put64(owner+0x108,(uintptr_t)p);put32(p+0xd0,key);
    uint64_t regs[31]={0};regs[19]=(uintptr_t)s;regs[0]=(uintptr_t)p+0x614;
    put32(p+0x614,key^0x3e800000);put32(p+0x61c,key^0x3f000000);
    put32(s+0x68,key^0x3f000000);put32(s+0x6c,0x40800000);
    uint8_t before[sizeof heap];memcpy(before,heap,sizeof heap);
    callbacks[OBS_RAIDERS_SHOOTER](regs);callbacks[OBS_RAIDERS_INK](regs);
    assert(!memcmp(before,heap,sizeof heap)&&writes==0);
    dm_raiders_mods_set(DM_RAIDERS_INFINITE_INK);callbacks[OBS_RAIDERS_SHOOTER](regs);
    assert(get32(p+0x614)==(key^0x3f800000)&&get32(p+0x61c)==(key^0x3f800000));
    assert(get32(s+0x68)==(key^0x3f000000));
    put32(p+0x614,key^0x3e800000);callbacks[OBS_RAIDERS_INK](regs);assert(get32(p+0x614)==(key^0x3f800000));
    dm_raiders_mods_set(DM_RAIDERS_RAPID_FIRE);put32(p+0x614,key^0x3e800000);callbacks[OBS_RAIDERS_SHOOTER](regs);
    // The idle update cannot service a held trigger. The active readiness
    // entry receives the shooter in x0, before the game's cadence check.
    assert(get32(s+0x68)==(key^0x3f000000));
    regs[0]=(uintptr_t)s;callbacks[OBS_RAIDERS_SHOOT_READY](regs);
    assert(get32(s+0x68)==(key^0x3f800000)&&get32(s+0x6c)==0);assert(get32(p+0x614)==(key^0x3e800000));
    dm_raiders_mods_set(0);memcpy(before,heap,sizeof heap);unsigned n=writes;callbacks[OBS_RAIDERS_SHOOTER](regs);callbacks[OBS_RAIDERS_INK](regs);
    callbacks[OBS_RAIDERS_SHOOT_READY](regs);assert(!memcmp(before,heap,sizeof heap)&&writes==n);
    dm_raiders_mods_set(3);put32(p+0xd0,key^1);memcpy(before,heap,sizeof heap);callbacks[OBS_RAIDERS_SHOOTER](regs);callbacks[OBS_RAIDERS_SHOOT_READY](regs);assert(!memcmp(before,heap,sizeof heap));
    put32(p+0xd0,key);put64(s,(uintptr_t)image+0x1234);memcpy(before,heap,sizeof heap);callbacks[OBS_RAIDERS_SHOOTER](regs);assert(!memcmp(before,heap,sizeof heap));
    regs[19]=1;callbacks[OBS_RAIDERS_SHOOTER](regs);regs[0]=1;callbacks[OBS_RAIDERS_INK](regs);callbacks[OBS_RAIDERS_SHOOT_READY](regs);
    assert(writes==n);
    uint8_t *c=heap+0x8000,*wrapper=heap+0x10000,*character=heap+0x10100,*shape=heap+0x11000;
    put64(p+0x1240,(uintptr_t)c);put64(c+0x7428,(uintptr_t)owner);put64(c+0x7438,(uintptr_t)wrapper);
    put64(wrapper+8,(uintptr_t)character);put64(character+0x20,(uintptr_t)(heap+0x12000));
    put64(c+0x28,(uintptr_t)shape);put32(shape+0x2d8,0x3f000000);
    for(int i=1;i<4;i++)put64(c+0x7280+(i-1)*8,(uintptr_t)(heap+0x12000+i*0x100));
    uint8_t *camera=heap+0x13000;put64(p+0x1210,(uintptr_t)camera);put64(camera,(uintptr_t)(image+0x4b20300));
    float orientation[]={1,0,0,0,1,0,0,0,1};memcpy(camera+0x3c,orientation,sizeof orientation);
    float origin[]={10,20,30};memcpy(p+0x10,origin,12);regs[28]=(uintptr_t)p+0x5d8;
    g_body_position=body_position;g_body_velocity=body_velocity;g_collision_radius=radius;
    dm_raiders_mods_set(DM_RAIDERS_FLY);callbacks[OBS_RAIDERS_MOVE](regs);
    uint64_t filtered=DM_BTN_R|DM_BTN_L|DM_BTN_LS|DM_BTN_ZR|DM_BTN_A;int32_t fx=32767,fy=-32767;
    dm_raiders_mods_filter_input(&filtered,&fx,&fy);
    assert(filtered==(DM_BTN_ZR|DM_BTN_A)&&!fx&&!fy);
    assert(positions==4&&velocities==4&&last_body[0][1]==20.5f&&last_body[1][1]==20);
    buttons=DM_BTN_R;tick+=50000000;callbacks[OBS_RAIDERS_MOVE](regs);
    assert(fabsf(last_body[1][1]-20.3f)<0.0001f);
    // A different actor's update must not reset the active local flight.
    uint64_t local=regs[28];regs[28]=1;callbacks[OBS_RAIDERS_MOVE](regs);regs[28]=local;
    assert(g_fly_player==(uintptr_t)p);
    // A physics displacement must not pull an active flight back to a wall.
    memcpy(p+0x10,origin,12);buttons=0;axis_x=32767;tick+=50000000;callbacks[OBS_RAIDERS_MOVE](regs);
    assert(fabsf(last_body[1][0]-10.3f)<0.0001f&&fabsf(last_body[1][1]-20.3f)<0.0001f);
    buttons=DM_BTN_L|DM_BTN_LS;axis_x=0;tick+=50000000;callbacks[OBS_RAIDERS_MOVE](regs);
    assert(fabsf(last_body[1][1]-19.4f)<0.0001f);
    buttons=0;axis_y=32767;tick+=50000000;callbacks[OBS_RAIDERS_MOVE](regs);
    assert(fabsf(last_body[1][2]-29.7f)<0.0001f);
    float yaw90[]={0,0,1,0,1,0,-1,0,0};memcpy(camera+0x3c,yaw90,sizeof yaw90);
    tick+=50000000;callbacks[OBS_RAIDERS_MOVE](regs);
    assert(fabsf(last_body[1][0]-10.6f)<0.0001f&&fabsf(last_body[1][2]-29.7f)<0.0001f);
    axis_y=0;axis_x=32767;tick+=50000000;callbacks[OBS_RAIDERS_MOVE](regs);
    assert(fabsf(last_body[1][2]-30.f)<0.0001f);
    float pitch45[]={1,0,0,0,.70710678f,.70710678f,0,-.70710678f,.70710678f};
    memcpy(camera+0x3c,pitch45,sizeof pitch45);axis_x=0;axis_y=32767;tick+=50000000;callbacks[OBS_RAIDERS_MOVE](regs);
    assert(fabsf(last_body[1][1]-(19.4f+.3f/sqrtf(2)))<0.0001f);
    assert(fabsf(last_body[1][2]-(30.f-.3f/sqrtf(2)))<0.0001f);
    unsigned valid_calls=positions;put32(camera+0x3c,0x7fc00000);tick+=50000000;callbacks[OBS_RAIDERS_MOVE](regs);assert(positions==valid_calls);
    memcpy(camera+0x3c,orientation,sizeof orientation);put64(camera,(uintptr_t)(image+0x1234));tick+=50000000;callbacks[OBS_RAIDERS_MOVE](regs);assert(positions==valid_calls);
    put64(camera,(uintptr_t)(image+0x4b20300));
    dm_raiders_mods_set(0);n=writes;unsigned calls=positions;memcpy(before,heap,sizeof heap);callbacks[OBS_RAIDERS_MOVE](regs);
    filtered=DM_BTN_R|DM_BTN_L|DM_BTN_LS;fx=32767;fy=-32767;
    dm_raiders_mods_filter_input(&filtered,&fx,&fy);
    assert(filtered==(DM_BTN_R|DM_BTN_L|DM_BTN_LS)&&fx==32767&&fy==-32767);
    assert(!memcmp(before,heap,sizeof heap)&&writes==n&&positions==calls);
    dm_raiders_mods_set(DM_RAIDERS_FLY);put32(p+0xd0,key^1);callbacks[OBS_RAIDERS_MOVE](regs);assert(positions==calls);
    put32(p+0xd0,key);put64(owner+0x108,0);callbacks[OBS_RAIDERS_MOVE](regs);assert(positions==calls);
    free(image);puts("Raiders mods: ink, rapid fire, flight, disable, ownership and build guards pass");return 0;
}
