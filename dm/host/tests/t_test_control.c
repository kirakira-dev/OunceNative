// Exercise the real FIFO and frame gate, including split and queued commands.
#include <assert.h>
#include <stdatomic.h>
#include <signal.h>
#include <time.h>
#include "../dm_test_control.c"

static _Atomic int input_writes, frozen, calls;
static uint64_t buttons;
static int32_t axes[4];
static struct { uint64_t buttons; int32_t axes[4]; } published[8];
static char shot_path[1024];
uint64_t now_ns(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC,&t); return (uint64_t)t.tv_sec*1000000000ull+t.tv_nsec; }
void dm_input_set(uint64_t b, int32_t lx, int32_t ly, int32_t rx, int32_t ry) {
    buttons=b; axes[0]=lx; axes[1]=ly; axes[2]=rx; axes[3]=ry;
    int i=atomic_load(&input_writes); assert(i<8);
    published[i].buttons=b; memcpy(published[i].axes,axes,sizeof axes);
    atomic_fetch_add(&input_writes, 1);
}
void guest_clock_freeze_for(int reason, int on) { assert(reason == 3); atomic_store(&frozen, on); }
void dm_gfx_shot_at(long k, const char *path) { assert(k == 1); snprintf(shot_path,sizeof shot_path,"%s",path); }
static void *drive(void *unused) {
    (void)unused;
    for (uint64_t f=1; f<=5; f++) { dm_test_control_frame(f); atomic_store(&calls,(int)f); }
    return NULL;
}
static void wait_at(int f) {
    for (int n=0; n<2000 && !(atomic_load(&calls)==f && atomic_load(&frozen)); n++) usleep(1000);
    assert(atomic_load(&calls)==f && atomic_load(&frozen));
}
static void put(int fd,const char *s) { assert(write(fd,s,strlen(s))==(ssize_t)strlen(s)); }
int main(void) {
    alarm(10);
    dm_motion_state sensor;
    dm_motion_start(0,1);
    unsetenv("DM_TEST_CONTROL"); dm_test_control_frame(0);
    assert(!input_writes && !frozen && !dm_motion_read(&sensor,1,0)); g_control_init=0;
    char dir[]="/tmp/dm-test-control-XXXXXX"; assert(mkdtemp(dir));
    char path[256]; snprintf(path,sizeof path,"%s/commands",dir); assert(!mkfifo(path,0600));
    setenv("DM_TEST_CONTROL",path,1); setenv("DM_TEST_CONTROL_START","2",1);
    int fd=open(path,O_RDWR|O_NONBLOCK); assert(fd>=0);
    pthread_t th; assert(!pthread_create(&th,NULL,drive,NULL)); wait_at(1);
    put(fd,"step 3 512 12 -34 56 -78 0.1"); usleep(10000);
    assert(calls==1 && frozen && buttons==0); // no newline: no partial input
    put(fd," -0.2\n"); wait_at(4);
    // Frames 2, 3, 4 ran and frame 5 is waiting with input released.
    assert(buttons==0 && input_writes==3 && dm_motion_read(&sensor,1,0)==1);
    assert(fabsf(sensor.direction[2][1]-sinf(.1f))<1e-6f && fabsf(sensor.direction[1][0]-sinf(.2f))<1e-6f);
    assert(published[1].buttons==512 && published[1].axes[0]==12 && published[1].axes[1]==-34 &&
           published[1].axes[2]==56 && published[1].axes[3]==-78);
    put(fd,"step 0 0 0 0 0 0 0 0\nstep 2 0 0 0 0 0 nan 0\nstep 2 0 32768 0 0 0 0 0\n");
    put(fd,"step 2 65536 0 0 0 0 0 0\nstep 2 0 0 0 0 0 0 0 trailing\n");
    put(fd,"step 2 0 4294967296 0 0 0 0 0\nstep -1 0 0 0 0 0 0 0\n");
    char huge[2200]; memset(huge,'x',sizeof huge); assert(write(fd,huge,sizeof huge)==sizeof huge); put(fd,"\n");
    const char nul[]="step 2 0 0 0 0 0 0 0\0ignored\n"; assert(write(fd,nul,sizeof nul-1)==sizeof nul-1);
    put(fd,"shot /tmp/control shot.png\nstep 1 1 1 2 3 4 0 0\n");
    pthread_join(th,NULL);
    assert(calls==5 && !frozen && buttons==1 && axes[0]==1 && axes[1]==2 && axes[2]==3 && axes[3]==4);
    assert(!strcmp(shot_path,"/tmp/control shot.png"));
    assert(g_control_end==6 && input_writes==4);
    close(fd); close(g_control_fd); unlink(path); rmdir(dir);
    puts("PASS test control: disabled path, start frame, exact step, release, partial/queued input, motion, screenshot, malformed commands");
}
