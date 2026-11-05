#pragma once
#include <stdint.h>
enum { DM_RAIDERS_INFINITE_INK=1, DM_RAIDERS_RAPID_FIRE=2, DM_RAIDERS_FLY=4, DM_RAIDERS_SWIM=8 };
int dm_raiders_mods_available(void);
unsigned dm_raiders_mods_get(void);
void dm_raiders_mods_set(unsigned flags);
void dm_raiders_mods_filter_input(uint64_t *buttons,int32_t *lx,int32_t *ly);
unsigned dm_raiders_weapon_count(void);
const char *dm_raiders_weapon_family(unsigned index);
const char *dm_raiders_weapon_label(unsigned index);
unsigned dm_raiders_weapon_get(void);
void dm_raiders_weapon_set(unsigned index);
