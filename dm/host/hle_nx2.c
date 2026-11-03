#include "hle.h"

#if DM_GAME_NX2
HLE_FORCE("_ZN2nn3hid14InitializeJcmsEPvm", "Joy-Con mouse sensor initialization (no connected sensor)", void,
          h_nx2_jcms_init, void *memory, size_t size) { (void)memory; (void)size; }
HLE_FORCE("_ZN2nn3hid12FinalizeJcmsEv", "Joy-Con mouse sensor finalization", void, h_nx2_jcms_fini, void) {}
// No mouse is connected; Npad input is handled by hle_hid.
HLE_FORCE("_ZN2nn3hid16InitializeNmouseEPvmii", "NX2 mouse initialization (no connected mouse)", void,
          h_nx2_mouse_init, void *memory, size_t size, int width, int height) {
    (void)memory; (void)size; (void)width; (void)height;
}
HLE_FORCE("_ZN2nn3hid14FinalizeNmouseEv", "NX2 mouse finalization", void, h_nx2_mouse_fini, void) {}
HLE_FORCE("_ZN2nn3hid26SetMergedNmouseSourceTypesENS_4util10BitFlagSetILi32ENS0_10NmouseTypeEEE", "NX2 mouse selection (no connected mouse)", void,
          h_nx2_mouse_sources, uint32_t mask) { (void)mask; }
HLE_FORCE("_ZN2nn3hid32SetNmouseButtonConfigJoyLeftJcmsERKNS0_29NmouseButtonConfigJoyLeftJcmsE", "NX2 mouse button configuration", void,
          h_nx2_mouse_left, const void *config) { (void)config; }
HLE_FORCE("_ZN2nn3hid33SetNmouseButtonConfigJoyRightJcmsERKNS0_30NmouseButtonConfigJoyRightJcmsE", "NX2 mouse button configuration", void,
          h_nx2_mouse_right, const void *config) { (void)config; }
HLE_FORCE("_ZN2nn3hid21GetMergedNmouseHandleEPNS0_12NmouseHandleE", "NX2 mouse handle: not connected", int,
          h_nx2_mouse_merged, void *out) { (void)out; return 0; }
HLE_FORCE("_ZN2nn3hid16GetNmouseHandlesEPNS0_12NmouseHandleEij", "NX2 mouse enumeration: no devices", int,
          h_nx2_mouse_handles, void *out, int capacity, uint32_t id) { (void)out; (void)capacity; (void)id; return 0; }
HLE_FORCE("_ZN2nn3hid15GetNmouseStatesEPiPNS0_11NmouseStateEiNS0_12NmouseHandleE", "NX2 mouse states: not connected", int,
          h_nx2_mouse_states, int *count, void *out, int capacity, uint64_t handle) {
    (void)out; (void)capacity; (void)handle; *count = 0; return 0;
}
HLE_FORCE("_ZN2nn3hid16GetNmouseTypeSetEPNS_4util10BitFlagSetILi32ENS0_10NmouseTypeEEENS0_12NmouseHandleE", "NX2 mouse types: not connected", int,
          h_nx2_mouse_types, uint32_t *out, uint64_t handle) { (void)handle; *out = 0; return 0; }
// Match PokeDinner's stpl:u command 300: no work memory for offline play.
HLE_FORCE("_ZN2nn10streamplay21GetRequiredMemorySizeENS0_14StreamPlayTypeENS0_13StreamingModeEi", "offline streamplay has no work memory", size_t,
          h_nx2_streamplay_size, int type, int mode, int count) {
    LOG("streamplay work memory type=%d mode=%d guests=%d: 0 (offline)", type, mode, count);
    return 0;
}
HLE_FORCE("_ZN2nn10streamplay24CreateIndividualDisplaysEi", "offline streamplay has no remote display", void,
          h_nx2_streamplay_displays, int count) { LOG("streamplay displays=%d (offline)", count); }
HLE_FORCE("_ZN2nn10streamplay21GetNativeWindowHandleENS0_7GuestIdE", "offline streamplay has no native remote window", void *,
          h_nx2_streamplay_window, int guest) { (void)guest; return NULL; }
// The SDK maps PokeDinner's service value 10 to public scale enum 0.
HLE_FORCE("_ZN2nn2oe23GetCurrentGraphicsScaleEv", "fixed NX2 graphics scale", int,
          h_nx2_graphics_scale, void) { return 0; }
HLE_FORCE("_ZN2nn2oe42SetGraphicsScaleChangedNotificationEnabledEb", "fixed NX2 graphics scale has no transitions", void,
          h_nx2_graphics_scale_notifications, int enabled) {
    LOG("oe::SetGraphicsScaleChangedNotificationEnabled %d (fixed scale)", enabled);
}
HLE_FORCE("_ZN2nn3vi252SetLayerNextHdrExtendedContentLuminanceRangeMetadataEPNS0_9LayerTypeEtt", "HDR metadata on the host SDR layer", Result,
          h_nx2_hdr_extended, void *layer, unsigned short minimum, unsigned short maximum) {
    (void)layer;
    LOG("vi2 HDR extended luminance %u..%u (SDR layer)", minimum, maximum);
    return RES_OK;
}
HLE_FORCE("_ZN2nn3vi252SetLayerNextHdrStandardContentLuminanceRangeMetadataEPNS0_9LayerTypeEtt", "HDR metadata on the host SDR layer", Result,
          h_nx2_hdr_standard, void *layer, unsigned short minimum, unsigned short maximum) {
    (void)layer;
    LOG("vi2 HDR standard luminance %u..%u (SDR layer)", minimum, maximum);
    return RES_OK;
}
#endif
