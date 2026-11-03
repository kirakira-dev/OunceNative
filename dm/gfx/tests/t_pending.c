#include "../nvn/nvn_pending.h"
#include <assert.h>
#include <stdio.h>

int main(void) {
    nvn_pending p = {0};
    // Exceed the old 256-write limit without making the gaps pending.
    for (unsigned i = 0; i < 8192; i++) nvn_pending_add(&p, 16ull * i, 4);
    for (unsigned i = 0; i < 8192; i++) {
        assert(nvn_pending_hits(&p, 16ull * i, 4));
        assert(!nvn_pending_hits(&p, 16ull * i + 4, 12));
    }
    nvn_pending_add(&p, 2, 8192 * 16 - 2);
    assert(p.count == 1 && p.ranges[0].lo == 0 && p.ranges[0].hi == 8192 * 16);
    assert(!nvn_pending_hits(&p, 8192 * 16, 1));
    uint32_t rng = 1; unsigned checks = 0;
    for (unsigned trial = 0; trial < 32; trial++) {
        unsigned char bytes[4096] = {0}; nvn_pending_clear(&p);
        for (unsigned i = 0; i < 512; i++) {
            rng = rng * 1664525 + 1013904223; unsigned a = rng % sizeof bytes;
            rng = rng * 1664525 + 1013904223; unsigned n = rng % 31;
            if (a + n > sizeof bytes) n = sizeof bytes - a;
            nvn_pending_add(&p, a, n); memset(bytes + a, 1, n);
            for (unsigned q = 0; q < 16; q++) {
                rng = rng * 1664525 + 1013904223; unsigned x = rng % sizeof bytes;
                rng = rng * 1664525 + 1013904223; unsigned len = rng % 51, hit = 0;
                if (x + len > sizeof bytes) len = sizeof bytes - x;
                for (unsigned j = 0; j < len; j++) hit |= bytes[x + j];
                assert(nvn_pending_hits(&p, x, len) == (int)hit); checks++;
            }
        }
    }
    nvn_pending_clear(&p); assert(!nvn_pending_hits(&p, 0, UINT64_MAX));
    nvn_pending_add(&p, UINT64_MAX - 4, 4);
    assert(nvn_pending_hits(&p, UINT64_MAX - 1, 1));
    assert(!nvn_pending_hits(&p, UINT64_MAX - 5, 1));
    nvn_pending_add(&p, UINT64_MAX, 1); assert(p.all && nvn_pending_hits(&p, 0, 1));
    assert(!nvn_pending_hits(&p, 0, 0));
    nvn_pending_clear(&p); assert(!nvn_pending_hits(&p, 0, 1)); free(p.ranges);
    printf("PASS 8192 disjoint writes, merging, reset, overflow and %u bitmap comparisons\n", checks);
}
