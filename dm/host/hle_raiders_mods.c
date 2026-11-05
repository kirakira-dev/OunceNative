// Raiders v65536 state hooks. Addresses belong to this exact owned executable;
// no source-level or memory-layout assumptions are shared with other games.
#include "dm.h"
#include "dm_raiders_mods.h"
#include "dm_input.h"
#include <stdatomic.h>
#include <math.h>

#define RAIDERS_BUILD "663c2e087a083f05307f229dfc4042d5"
#include "dm_raiders_weapons.inc"
static _Atomic unsigned g_mods;
static _Atomic unsigned g_weapon;
static _Atomic uint64_t g_player;
static uint8_t *g_main;
static pthread_once_t g_once=PTHREAD_ONCE_INIT;
static void (*g_body_position)(uint64_t,const float *);
static void (*g_body_velocity)(uint64_t,const float *,int);
static float (*g_collision_radius)(uint64_t);
static uint64_t g_fly_player,g_fly_body,g_fly_time;
static float g_fly_position[3];
static unsigned g_fly_mode;
static uint64_t g_weapon_player,g_weapon_manager;
static unsigned g_weapon_applied;
static uint32_t g_weapon_original;
static uint32_t g_weapon_original_variant;
static void (*g_equip)(uint64_t,uint64_t,uint64_t,uint64_t,unsigned,uint32_t,unsigned,unsigned);
static int g_diagnostics;
static uint64_t g_report_time;
static uint64_t g_shot_player,g_shot_time;
static unsigned g_shot_count,g_shot_checks;
static uint32_t g_shot_sequence;
int dm_guest_heap_readable(uint64_t address,size_t length);

static void init(void) {
    if (DM_GAME_PROGRAM_ID!=0x0400380020056000ull || strcmp(dm_main_build(),RAIDERS_BUILD)) return;
    for(int i=0;i<g_nmod;i++) if(!strcmp(g_mod[i].name,"main")) g_main=g_mod[i].base;
    if(!g_main)return;
    g_diagnostics=getenv("DM_RAIDERS_MOD_DIAGNOSTICS")!=NULL;
    g_body_position=(void *) (g_main+0x39fb5f0);
    g_body_velocity=(void *) (g_main+0x39fc200);
    g_collision_radius=(void *) (g_main+0x246c520);
    g_equip=(void *)(g_main+0x2420d20);
    const char *s=getenv("DM_RAIDERS_MODS");
    if(s) { unsigned f=0; char *copy=strdup(s),*save=NULL;
        for(char *p=strtok_r(copy,",",&save);p;p=strtok_r(NULL,",",&save)) {
            if(!strcmp(p,"ink"))f|=DM_RAIDERS_INFINITE_INK;
            else if(!strcmp(p,"rapid"))f|=DM_RAIDERS_RAPID_FIRE;
            else if(!strcmp(p,"fly"))f|=DM_RAIDERS_FLY;
            else if(!strcmp(p,"swim"))f|=DM_RAIDERS_SWIM;
        }
        free(copy);atomic_store(&g_mods,f);
    }
    s=getenv("DM_RAIDERS_WEAPON");
    if(s)for(unsigned i=1;i<sizeof weapons/sizeof weapons[0];i++)
        if(!strcmp(s,weapons[i].row))atomic_store(&g_weapon,i);
}
int dm_raiders_mods_available(void) {
    // Menus can be constructed before modules are loaded; do not latch that
    // temporary absence into pthread_once.
    if(!g_nmod || !gate_obs_present(OBS_RAIDERS_INK) || !gate_obs_present(OBS_RAIDERS_SHOOTER) ||
       !gate_obs_present(OBS_RAIDERS_MOVE) || !gate_obs_present(OBS_RAIDERS_SHOOT_READY))return 0;
    pthread_once(&g_once,init);
    return g_main!=NULL;
}
unsigned dm_raiders_mods_get(void) { return atomic_load(&g_mods); }
void dm_raiders_mods_filter_input(uint64_t *buttons,int32_t *lx,int32_t *ly) {
    unsigned flags=atomic_load(&g_mods);
    if(flags&DM_RAIDERS_FLY) {
        *buttons&=~(uint64_t)(DM_BTN_L|DM_BTN_R|DM_BTN_LS);
        *lx=*ly=0;
    } else if((flags&DM_RAIDERS_SWIM) && (*buttons&DM_BTN_ZL)) {
        *buttons&=~(uint64_t)(DM_BTN_L|DM_BTN_R|DM_BTN_LS);
    }
}
void dm_raiders_mods_set(unsigned flags) {
    if(dm_raiders_mods_available()) {
        flags&=DM_RAIDERS_INFINITE_INK|DM_RAIDERS_RAPID_FIRE|DM_RAIDERS_FLY|DM_RAIDERS_SWIM;
        atomic_store(&g_mods,flags);
        if(g_diagnostics)LOG("Raiders mods flags: %u",flags);
    }
}
unsigned dm_raiders_weapon_count(void) {return sizeof weapons/sizeof weapons[0];}
const char *dm_raiders_weapon_family(unsigned index) {return index<dm_raiders_weapon_count()?weapons[index].family:"";}
const char *dm_raiders_weapon_label(unsigned index) {return index<dm_raiders_weapon_count()?weapons[index].label:"";}
unsigned dm_raiders_weapon_get(void) {return atomic_load(&g_weapon);}
void dm_raiders_weapon_set(unsigned index) {
    if(index<dm_raiders_weapon_count() && dm_raiders_mods_available())atomic_store(&g_weapon,index);
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
static void weapon_update(uint64_t player) {
    uint64_t manager,slot,vt;uint32_t kind;
    unsigned desired=atomic_load(&g_weapon);
    if(!desired && !g_weapon_player)return;
    if(!read64(player+0x13e0,&manager) || !dm_guest_heap_readable(manager,0x480) ||
       !read64(manager,&vt) || vt!=(uint64_t)(g_main+0x4a5cef8) ||
       !read64(manager+0x130,&slot))return;
    if(g_weapon_player!=player || g_weapon_manager!=manager) {
        if(!dm_guest_heap_readable(slot,0x20))return;
        memcpy(&kind,(void *)(slot+0x10),4);if(kind!=1)return;
        // Slot 1 is the main weapon. The game's equip request stores its
        // numeric weapon enum at +14 and variation at +18 in the active resource slot.
        memcpy(&g_weapon_original,(void *)(slot+0x14),4);
        memcpy(&g_weapon_original_variant,(void *)(slot+0x18),4);
        g_weapon_player=player;g_weapon_manager=manager;g_weapon_applied=0;
    }
    if(desired==g_weapon_applied) {
        // Once restoration has finished, a later override must capture the
        // game's current loadout, including changes made through its own UI.
        if(!desired && dm_guest_heap_readable(slot,0x20)) {
            uint32_t id;memcpy(&id,(void *)(slot+0x14),4);
            if(id==g_weapon_original) {g_weapon_player=0;g_weapon_manager=0;}
        }
        return;
    }
    uint32_t id=desired?weapons[desired].id:g_weapon_original;
    // Same request path as PlayerNetEvent 6c2b6a00 -> 2406910. This retires
    // the current action and requests its replacement through the game.
    // It runs on the player's update thread, never the Cocoa menu thread.
    g_equip(player+0x11c4,manager,player+0x518,manager,1,id,desired?0:g_weapon_original_variant,1);
    g_weapon_applied=desired;
    if(g_diagnostics)LOG("Raiders weapon request: %s (%08x)",desired?weapons[desired].row:"game loadout",id);
}
static void ink(const uint64_t *regs) {
    if(!dm_raiders_mods_available() || !(atomic_load(&g_mods)&DM_RAIDERS_INFINITE_INK))return;
    uint64_t p=regs[0]-0x614;uint32_t key;
    if(p!=atomic_load(&g_player) || !scalar_key(&key) || !player_valid(p,key))return;
    refill(p,key);
}
static int shooter_owner(uint64_t s,uint64_t *player,uint32_t *key) {
    uint64_t owner;
    if(!dm_guest_heap_readable(s,0x2e0) || !read64(s+0x2b0,&owner) || !read64(owner+0x108,player) ||
       !scalar_key(key) || !player_valid(*player,*key))return 0;
    uint64_t vt;memcpy(&vt,(void *)s,8);
    return vt==(uint64_t)(g_main+0x4b24de8);
}
static void shooter(const uint64_t *regs) {
    if(!dm_raiders_mods_available())return;
    uint64_t player;uint32_t key;
    if(!shooter_owner(regs[19],&player,&key))return;
    atomic_store(&g_player,player);
    if(atomic_load(&g_mods)&DM_RAIDERS_INFINITE_INK)refill(player,key);
}
static void shoot_ready(const uint64_t *regs) {
    if(!dm_raiders_mods_available())return;
    uint64_t s=regs[0],player;uint32_t key;
    if(!shooter_owner(s,&player,&key))return;
    atomic_store(&g_player,player);
    unsigned flags=atomic_load(&g_mods);
    if(flags&DM_RAIDERS_INFINITE_INK)refill(player,key);
    if(flags&DM_RAIDERS_RAPID_FIRE) {
        // main+250bfa0 checks this accumulator through +24de130 while firing.
        // The old +25099f8 observation only runs on the non-firing branch.
        // Keep the game's ink, weapon-state and projectile-creation checks.
        word(s+0x68,key^0x3f800000u);word(s+0x6c,0);
    }
    if(g_diagnostics) {
        // +98 counts emitted shots (+250a4fc..504). +91 is a repeating
        // spread-pattern index and cannot be used as a shot counter.
        uint64_t tick=now_ns();uint32_t sequence;memcpy(&sequence,(const void *)(s+0x98),4);
        if(g_shot_player!=s || tick-g_shot_time>2000000000ull) {
            g_shot_player=s;g_shot_sequence=sequence;g_shot_time=tick;g_shot_count=g_shot_checks=0;
        }
        g_shot_count+=sequence>=g_shot_sequence ? sequence-g_shot_sequence : sequence;
        g_shot_sequence=sequence;g_shot_checks++;
        if(tick-g_shot_time>=1000000000ull) {
            LOG("Raiders firing: %u shots / %u readiness checks in %.3f s; rapid %u",g_shot_count,g_shot_checks,(tick-g_shot_time)*1e-9,!!(flags&DM_RAIDERS_RAPID_FIRE));
            g_shot_count=g_shot_checks=0;g_shot_time=tick;
        }
    }
}
static int camera_basis(uint64_t player,float right[3],float forward[3]) {
    uint64_t camera,vt;
    // main+22e49a0 creates spl:PlayerCamera and stores it at player+1210.
    // Its constructor (+245c7a0) initializes the world orientation at +3c.
    if(!read64(player+0x1210,&camera) || !dm_guest_heap_readable(camera,0x94) ||
       !read64(camera,&vt) || vt!=(uint64_t)(g_main+0x4b20300))return 0;
    memcpy(right,(void *)(camera+0x3c),12);memcpy(forward,(void *)(camera+0x54),12);
    float rr=0,ff=0,rf=0;
    for(int i=0;i<3;i++) {
        forward[i]=-forward[i];
        if(!isfinite(right[i]) || !isfinite(forward[i]))return 0;
        rr+=right[i]*right[i];ff+=forward[i]*forward[i];rf+=right[i]*forward[i];
    }
    if(rr<0.8f || rr>1.2f || ff<0.8f || ff>1.2f || fabsf(rf)>0.05f)return 0;
    for(int i=0;i<3;i++) {right[i]/=sqrtf(rr);forward[i]/=sqrtf(ff);}
    return 1;
}
static void flight(const uint64_t *regs) {
    if(!dm_raiders_mods_available())return;
    unsigned flags=atomic_load(&g_mods);
    uint64_t buttons;int32_t lx,ly;dm_input_current(&buttons,&lx,&ly);
    unsigned mode=(flags&DM_RAIDERS_FLY)?1:((flags&DM_RAIDERS_SWIM) && (buttons&DM_BTN_ZL)?2:0);
    uint64_t player=regs[28]-0x5d8,collision,owner,back,wrapper,character,shape,bodies[4];uint32_t key;
    if(!scalar_key(&key) || !player_valid(player,key))return;
    atomic_store(&g_player,player);
    if(flags&DM_RAIDERS_INFINITE_INK)refill(player,key);
    weapon_update(player);
    if(!mode) {
        g_fly_player=0;g_fly_body=0;g_fly_time=0;g_report_time=0;g_fly_mode=0;return;
    }
    if(!read64(player+0x1240,&collision) || !dm_guest_heap_readable(collision,0x7440) ||
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
    if(g_fly_player!=player || g_fly_body!=bodies[0] || g_fly_mode!=mode) {
        memcpy(g_fly_position,(void *)(player+0x10),sizeof g_fly_position);
        g_fly_player=player;g_fly_body=bodies[0];g_fly_time=tick;g_fly_mode=mode;
    }
    float dt=fminf((tick-g_fly_time)*1e-9,0.05);g_fly_time=tick;
    float right[3],forward[3],v[3];
    if(!camera_basis(player,right,forward))return;
    float x=lx/32767.f,y=ly/32767.f;
    if(fabsf(x)<0.15f)x=0;if(fabsf(y)<0.15f)y=0;
    for(int i=0;i<3;i++)v[i]=right[i]*x+forward[i]*y;
    v[1]+=!!(buttons&DM_BTN_R)-!!(buttons&DM_BTN_L);
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
        LOG("Raiders %s: position %.3f %.3f %.3f, input %.2f %.2f %.2f",mode==2?"swim":"flight",next[0],next[1],next[2],v[0],v[1],v[2]);
    }
}
__attribute__((constructor))static void register_mods(void) {
    gate_obs_set(OBS_RAIDERS_INK,ink);gate_obs_set(OBS_RAIDERS_SHOOTER,shooter);
    gate_obs_set(OBS_RAIDERS_MOVE,flight);gate_obs_set(OBS_RAIDERS_SHOOT_READY,shoot_ready);
}
