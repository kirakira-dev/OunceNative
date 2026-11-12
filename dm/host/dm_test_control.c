// Opt-in frame stepping for windowless gameplay validation. The caller owns
// the FIFO; normal app launches do not open a file or publish any input.
// Lines: step FRAMES BUTTON_BITS LX LY RX RY PITCH YAW, or shot ABSOLUTE_PATH.
// Steps use 1..36000 frames, 16 button bits, signed 16-bit axes excluding -32768,
// and a single finite gyro rotation of at most pi radians on each axis.
#include "dm.h"
#include "dm_input.h"
#include "dm_motion.h"
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <poll.h>
#include <sys/stat.h>
#include <unistd.h>

static int g_control_fd = -1, g_control_init;
static uint64_t g_control_start, g_control_end;
static char g_control_buf[2048];
static size_t g_control_len;
static int g_control_discard;

static int control_line(char *line, uint64_t frame) {
    unsigned long long frames, buttons;
    long long lx, ly, rx, ry; int n = 0;
    float pitch, yaw;
    if (sscanf(line, "step %llu %llu %lld %lld %lld %lld %f %f %n",
               &frames, &buttons, &lx, &ly, &rx, &ry, &pitch, &yaw, &n) == 8 &&
        n && !line[n] && frames >= 1 && frames <= 36000 && buttons <= 65535 &&
        lx >= -32767 && lx <= 32767 && ly >= -32767 && ly <= 32767 &&
        rx >= -32767 && rx <= 32767 && ry >= -32767 && ry <= 32767 &&
        isfinite(pitch) && isfinite(yaw) && fabsf(pitch) <= 3.141593f && fabsf(yaw) <= 3.141593f) {
        dm_input_set(buttons, lx, ly, rx, ry);
        if (pitch || yaw) dm_motion_rotate(pitch, yaw);
        g_control_end = frame + frames;
        LOG("test control: step frame %llu -> %llu buttons %llu axes %lld,%lld,%lld,%lld motion %.6f,%.6f",
            (unsigned long long)frame, (unsigned long long)g_control_end,
            buttons, lx, ly, rx, ry, pitch, yaw);
        return 1;
    }
    if (!strncmp(line, "shot /", 6) && strlen(line + 5) < 1024) {
        dm_gfx_shot_at(1, line + 5);
        return 0;
    }
    LOG("[RED] test control: invalid command");
    return 0;
}

void dm_test_control_frame(uint64_t frame) {
    if (!g_control_init) {
        g_control_init = 1;
        const char *path = getenv("DM_TEST_CONTROL");
        if (!path || !*path) return;
        int fd = open(path, O_RDWR | O_NONBLOCK | O_CLOEXEC);
        struct stat st;
        if (fd < 0 || fstat(fd, &st) || !S_ISFIFO(st.st_mode)) {
            if (fd >= 0) close(fd);
            LOG("[RED] test control: DM_TEST_CONTROL must name an existing FIFO");
            return;
        }
        g_control_fd = fd;
        // The window normally enables the virtual sensor. Windowless hosts
        // need the same source when this diagnostic channel is selected.
        dm_motion_available(1);
        const char *start = getenv("DM_TEST_CONTROL_START");
        g_control_start = start ? strtoull(start, NULL, 10) : 0;
    }
    if (g_control_fd < 0 || frame < g_control_start || frame < g_control_end) return;
    dm_input_set(0, 0, 0, 0, 0);
    guest_clock_freeze_for(3, 1);
    LOG("test control: waiting frame %llu", (unsigned long long)frame);
    for (;;) {
        // Read one byte at a time only while explicitly paused. This preserves
        // queued commands across steps and consumes malformed long lines fully.
        char c;
        ssize_t got = read(g_control_fd, &c, 1);
        if (got == 1) {
            if (c == '\n') {
                g_control_buf[g_control_len] = 0;
                int advance = !g_control_discard && control_line(g_control_buf, frame);
                g_control_len = 0; g_control_discard = 0;
                if (advance) { guest_clock_freeze_for(3, 0); return; }
            } else if (!g_control_discard) {
                if (!c || g_control_len == sizeof(g_control_buf) - 1) {
                    g_control_discard = 1;
                    LOG("[RED] test control: oversized or NUL-containing command");
                } else g_control_buf[g_control_len++] = c;
            }
            continue;
        }
        if (got < 0 && errno != EAGAIN && errno != EINTR) {
            LOG("[RED] test control: FIFO read failed (%d)", errno);
            close(g_control_fd); g_control_fd = -1;
            guest_clock_freeze_for(3, 0); return;
        }
        struct pollfd p = {g_control_fd, POLLIN, 0};
        poll(&p, 1, 100);
    }
}
