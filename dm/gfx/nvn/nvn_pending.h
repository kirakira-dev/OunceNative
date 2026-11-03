// Exact union of pending GPU buffer writes. Cleared per submission; allocation is
// retained. Adjacent/overlapping writes merge, so repeated uniform updates do not
// make unrelated buffers look GPU-written after a fixed number of commands.
#pragma once
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

typedef struct { uint64_t lo, hi; } nvn_pending_range;
typedef struct { nvn_pending_range *ranges; size_t count, capacity; int all; } nvn_pending;

static inline void nvn_pending_clear(nvn_pending *p) { p->count = 0; p->all = 0; }

static inline void nvn_pending_add(nvn_pending *p, uint64_t a, uint64_t n) {
    if (!n || p->all) return;
    if (n > UINT64_MAX - a) { p->all = 1; return; }
    uint64_t b = a + n;
    size_t first = 0, end = p->count;
    while (first < end) { size_t mid = first + (end - first) / 2;
        if (p->ranges[mid].hi < a) first = mid + 1; else end = mid; }
    end = first;
    while (end < p->count && p->ranges[end].lo <= b) {
        if (p->ranges[end].lo < a) a = p->ranges[end].lo;
        if (p->ranges[end].hi > b) b = p->ranges[end].hi;
        end++;
    }
    if (end == first && p->count == p->capacity) {
        if (p->capacity > SIZE_MAX / (2 * sizeof *p->ranges)) { p->all = 1; return; }
        size_t cap = p->capacity ? p->capacity * 2 : 64;
        nvn_pending_range *r = realloc(p->ranges, cap * sizeof *r);
        if (!r) { p->all = 1; return; } // Allocation failure stays conservative.
        p->ranges = r; p->capacity = cap;
    }
    memmove(p->ranges + first + 1, p->ranges + end, (p->count - end) * sizeof *p->ranges);
    p->ranges[first] = (nvn_pending_range){a, b};
    p->count = p->count - (end - first) + 1;
}

static inline int nvn_pending_hits(const nvn_pending *p, uint64_t a, uint64_t n) {
    if (!n) return 0;
    if (p->all || n > UINT64_MAX - a) return 1;
    size_t lo = 0, hi = p->count;
    while (lo < hi) { size_t mid = lo + (hi - lo) / 2;
        if (p->ranges[mid].hi <= a) lo = mid + 1; else hi = mid; }
    return lo < p->count && p->ranges[lo].lo < a + n;
}
