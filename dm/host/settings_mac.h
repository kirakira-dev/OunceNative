// Mac front end settings (settings_mac.m): keyboard bindings (Ryujinx's defaults), controller options and the launch options the app's launcher reads from env.txt.
#pragma once
#include <stdint.h>

// Bindable actions. The first 16 are the button bits of dm_input.h, the rest are the two sticks' directions
enum {
    DMB_A, DMB_B, DMB_X, DMB_Y, DMB_LS, DMB_RS, DMB_L, DMB_R, DMB_ZL, DMB_ZR, DMB_PLUS, DMB_MINUS,
    DMB_DLEFT, DMB_DUP, DMB_DRIGHT, DMB_DDOWN,
    DMB_LUP, DMB_LDOWN, DMB_LLEFT, DMB_LRIGHT, DMB_RUP, DMB_RDOWN, DMB_RLEFT, DMB_RRIGHT,
    DMSET_N
};
#define DMSET_UNBOUND 0xFFFF

extern uint16_t g_dmset_bind[DMSET_N];   // macOS virtual key code per action, DMSET_UNBOUND for none
extern int g_dmset_pad_by_label;         // controller: 0 = by position (Nintendo layout, the default), 1 = by label (Xbox / PlayStation A is A)

void dmset_load(void);                   // read the bindings from the user defaults (Ryujinx's defaults when none are saved)
void dmset_show(void);                   // open the settings window (main thread)
int dmset_capturing(void);               // the settings window is waiting for a key to bind
int dmset_fullscreen(void);              // start in full screen
void dmset_on_change(void (*fn)(void));  // called on the main thread after a binding or controller option changes
