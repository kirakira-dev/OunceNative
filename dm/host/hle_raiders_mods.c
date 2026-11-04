// Raiders v65536 state hooks. Addresses belong to this exact owned executable;
// no source-level or memory-layout assumptions are shared with other games.
#include "dm.h"
#include "dm_raiders_mods.h"
#include "dm_input.h"
#include <stdatomic.h>
#include <math.h>

#define RAIDERS_BUILD "663c2e087a083f05307f229dfc4042d5"
static _Atomic unsigned g_mods;
static _Atomic uint64_t g_player;
static uint8_t *g_main;
static pthread_once_t g_once=PTHREAD_ONCE_INIT;
static void (*g_body_position)(uint64_t,const float *);
static void (*g_body_velocity)(uint64_t,const float *,int);
static float (*g_collision_radius)(uint64_t);
static uint64_t g_fly_player,g_fly_body,g_fly_time;
static float g_fly_position[3];
static int g_diagnostics;
static uint64_t g_report_time;
int dm_guest_heap_readable(uint64_t address,size_t length);

static void init(void) {
    if (DM_GAME_PROGRAM_ID!=0x0400380020056000ull || strcmp(dm_main_build(),RAIDERS_BUILD)) return;
    for(int i=0;i<g_nmod;i++) if(!strcmp(g_mod[i].name,"main")) g_main=g_mod[i].base;
    if(!g_main)return;
    g_diagnostics=getenv("DM_RAIDERS_MOD_DIAGNOSTICS")!=NULL;
    g_body_position=(void *) (g_main+0x39fb5f0);
    g_body_velocity=(void *) (g_main+0x39fc200);
    g_collision_radius=(void *) (g_main+0x246c520);
    const char *s=getenv("DM_RAIDERS_MODS");
    if(s) { unsigned f=0; char *copy=strdup(s),*save=NULL;
        for(char *p=strtok_r(copy,",",&save);p;p=strtok_r(NULL,",",&save)) {
            if(!strcmp(p,"ink"))f|=DM_RAIDERS_INFINITE_INK;
            else if(!strcmp(p,"rapid"))f|=DM_RAIDERS_RAPID_FIRE;
            else if(!strcmp(p,"fly"))f|=DM_RAIDERS_FLY;
        }
        free(copy);atomic_store(&g_mods,f);
    }
}
int dm_raiders_mods_available(void) {
    // Menus can be constructed before modules are loaded; do not latch that
    // temporary absence into pthread_once.
    if(!g_nmod || !gate_obs_present(OBS_RAIDERS_INK) || !gate_obs_present(OBS_RAIDERS_SHOOTER) || !gate_obs_present(OBS_RAIDERS_MOVE))return 0;
    pthread_once(&g_once,init);
    return g_main!=NULL;
}
unsigned dm_raiders_mods_get(void) { return atomic_load(&g_mods); }
void dm_raiders_mods_filter_input(uint64_t *buttons,int32_t *lx,int32_t *ly) {
    if(atomic_load(&g_mods)&DM_RAIDERS_FLY) {
        *buttons&=~(uint64_t)(DM_BTN_L|DM_BTN_R|DM_BTN_LS);
        *lx=*ly=0;
    }
}
void dm_raiders_mods_set(unsigned flags) {
    if(dm_raiders_mods_available()) {
        flags&=DM_RAIDERS_INFINITE_INK|DM_RAIDERS_RAPID_FIRE|DM_RAIDERS_FLY;
        atomic_store(&g_mods,flags);
        if(g_diagnostics)LOG("Raiders mods flags: %u",flags);
    }
}
static int read64(uint64_t p,uint64_t *out) {
    if(!dm_guest_heap_readable(p,8))return 0;
    memcpy(out,(const void *)p,8);return 1;
}
static int scalar_key(uint32_t *out) {
    uint64_t p;memcpy(&p,g_main+0x4d24140,8);
    if(!dm_guest_heap_readable(p,4))return 0;
    memcpy(out,(const void *)p,4);return 1;
}
static void word(uint64_t p,uint32_t value) {
    dm_guest_write_prepare((void *)p,4);memcpy((void *)p,&value,4);
}
static void refill(uint64_t player,uint32_t key) {
    // Constructors at main+22ed494 and +23ee3bc initialize both magazines
    // with the encoded float 1.0. The consumption path selects +614 or +61c.
    word(player+0x614,key^0x3f800000u);word(player+0x61c,key^0x3f800000u);
}
static int player_valid(uint64_t player,uint32_t key) {
    uint64_t vt;uint32_t slot;
    if(!dm_guest_heap_readable(player,0x1400))return 0;
    memcpy(&vt,(const void *)player,8);memcpy(&slot,(const void *)(player+0xd0),4);
    return vt==(uint64_t)(g_main+0x4b1f698) && (slot^key)==0;
}
static void ink(const uint64_t *regs) {
    if(!dm_raiders_mods_available() || !(atomic_load(&g_mods)&DM_RAIDERS_INFINITE_INK))return;
    uint64_t p=regs[0]-0x614;uint32_t key;
    if(p!=atomic_load(&g_player) || !scalar_key(&key) || !player_valid(p,key))return;
    refill(p,key);
}
static void shooter(const uint64_t *regs) {
    if(!dm_raiders_mods_available())return;
    uint64_t s=regs[19],owner,player;uint32_t key;
    if(!dm_guest_heap_readable(s,0x2e0) || !read64(s+0x2b0,&owner) || !read64(owner+0x108,&player) ||
       !scalar_key(&key) || !player_valid(player,key))return;
    uint64_t vt;memcpy(&vt,(void *)s,8);
    if(vt!=(uint64_t)(g_main+0x4b24de8))return;
    atomic_store(&g_player,player);
    unsigned flags=atomic_load(&g_mods);
    if(flags&DM_RAIDERS_INFINITE_INK)refill(player,key);
    if(flags&DM_RAIDERS_RAPID_FIRE) {
        // +68 is the encoded [0,1] repeat accumulator; +6c is its remaining
        // frame count, produced by main+25093b0 immediately before this hook.
        word(s+0x68,key^0x3f800000u);word(s+0x6c,0);
    }
}
static void flight(const uint64_t *regs) {
    if(!dm_raiders_mods_available() || !(atomic_load(&g_mods)&DM_RAIDERS_FLY)) {
        g_fly_player=0;g_fly_body=0;g_fly_time=0;g_report_time=0;return;
    }
    uint64_t player=regs[28]-0x5d8,collision,owner,back,wrapper,character,shape,bodies[4];uint32_t key;
    if(!scalar_key(&key) || !player_valid(player,key) ||
       !read64(player+0x1240,&collision) || !dm_guest_heap_readable(collision,0x7440) ||
       !read64(collision+0x7428,&owner) || !read64(owner+0x108,&back) || back!=player ||
       !read64(collision+0x7438,&wrapper) || !read64(wrapper+8,&character) ||
       !read64(character+0x20,bodies) || !read64(collision+0x28,&shape) || !dm_guest_heap_readable(shape,0x2e8)) {
        // This observation also runs for other players and NPCs. They must not
        // reset the local player's independent flight position.
        return;
    }
    for(int i=1;i<4;i++)if(!read64(collision+0x7280+(i-1)*8,bodies+i))return;
    for(int i=0;i<4;i++)if(!dm_guest_heap_readable(bodies[i],0x110))return;
    uint64_t tick=now_ns();
    if(g_fly_player!=player || g_fly_body!=bodies[0]) {
        memcpy(g_fly_position,(void *)(player+0x10),sizeof g_fly_position);
        g_fly_player=player;g_fly_body=bodies[0];g_fly_time=tick;
    }
    float dt=fminf((tick-g_fly_time)*1e-9,0.05);g_fly_time=tick;
    uint64_t buttons;int32_t lx,ly;dm_input_current(&buttons,&lx,&ly);
    float v[3]={lx/32767.f,!!(buttons&DM_BTN_R)-!!(buttons&DM_BTN_L),-ly/32767.f};
    if(fabsf(v[0])<0.15f)v[0]=0;if(fabsf(v[2])<0.15f)v[2]=0;
    float len=sqrtf(v[0]*v[0]+v[1]*v[1]+v[2]*v[2]);
    float step=6.f*dt*(buttons&DM_BTN_LS?3.f:1.f)/fmaxf(1.f,len);
    float next[3],center[3];float radius=g_collision_radius(collision);
    if(!isfinite(radius)||radius<0||radius>2000)return;
    for(int i=0;i<3;i++) {
        float offset;memcpy(&offset,(void *)(shape+0x2cc+i*12),4);
        next[i]=g_fly_position[i]+v[i]*step;center[i]=next[i]+offset*radius;
        if(!isfinite(next[i])||!isfinite(center[i])||fabsf(next[i])>1000000)return;
    }
    const float zero[3]={0};
    for(int i=0;i<4;i++) {g_body_position(bodies[i],i?next:center);g_body_velocity(bodies[i],zero,0);}
    dm_guest_write_prepare((void *)(player+0x10),12);memcpy((void *)(player+0x10),next,12);
    memcpy(g_fly_position,next,12);
    if(g_diagnostics && tick-g_report_time>=1000000000ull) {
        g_report_time=tick;
        LOG("Raiders flight: position %.3f %.3f %.3f, input %.2f %.2f %.2f",next[0],next[1],next[2],v[0],v[1],v[2]);
    }
}
__attribute__((constructor))static void register_mods(void) {
    gate_obs_set(OBS_RAIDERS_INK,ink);gate_obs_set(OBS_RAIDERS_SHOOTER,shooter);
    gate_obs_set(OBS_RAIDERS_MOVE,flight);
}
