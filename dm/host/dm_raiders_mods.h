#pragma once
#include <stdint.h>
enum { DM_RAIDERS_INFINITE_INK=1, DM_RAIDERS_RAPID_FIRE=2, DM_RAIDERS_FLY=4 };
int dm_raiders_mods_available(void);
unsigned dm_raiders_mods_get(void);
void dm_raiders_mods_set(unsigned flags);
void dm_raiders_mods_filter_input(uint64_t *buttons,int32_t *lx,int32_t *ly);
