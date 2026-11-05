// Mac front end: with DM_WINDOW=1 open a window (CAMetalLayer, for the graphics backend to present frames) + keyboard → dm_input; the guest runs on a large-stack thread instead and the main thread belongs to AppKit.
// Without DM_WINDOW: the guest runs directly on the current thread, behaving the same as with no front end (windowless tests use this).
// Keyboard: Ryujinx's default layout, rebindable in the settings window (settings_mac.m, ⌘,): WASD left stick, F press left stick, arrow keys D-pad, - minus, E=L Q=ZL;
// IJKL right stick, H press right stick, Z=A X=B C=X V=Y, = plus, U=R O=ZR. ⌘ shortcuts go to the menus (⌘, settings, ⌃⌘F full screen, ⌘Q quit).
// A connected game controller (GameController framework: Switch Pro, Joy-Con, Xbox, DualSense, ...) is merged in, buttons by position as on iOS (DmGamepad.m) unless the settings say by label.
#import <Cocoa/Cocoa.h>
#import <QuartzCore/CAMetalLayer.h>
#import <QuartzCore/CATransaction.h>
#import <Metal/Metal.h>
#import <GameController/GameController.h>
#include "dm.h"
#include "dm_input.h"
#include "dm_motion.h"
#include "dm_uiscreen.h"
#include "dm_raiders_mods.h"
#include "settings_mac.h"
void mtl_set_ui_rect_fn(void (*fn)(double *y, double *h));
static void ui_rect_frac(double *fy, double *fh) { int x, y, w, h, rw = 0, rh = 0; dm_ui_rect(&x, &y, &w, &h); if (dm_screen_real(&rw, &rh) && rh > 0) { *fy = (double)y / rh; *fh = (double)h / rh; } }   // Same as front_ios.m: vertical position and height of the UI rectangle (as fractions of the frame height)
__attribute__((constructor)) static void ui_shift_reg(void) { mtl_set_ui_rect_fn(ui_rect_frac); }   // Must also take effect when running without a window (screenshots / gate checks), so it is not placed where the layer is created
#include "front.h"
#include "hle.h"
#include <signal.h>

// A Mac bundle launches the native host itself so Launch Services and Game Mode
// identify the running process. Keep per-game paths and defaults in the bundle;
// command-line environments remain authoritative for isolated tests.
void front_configure_app(int *argc, char ***argv) {
    @autoreleasepool {
        NSBundle *bundle = NSBundle.mainBundle;
        NSDictionary *info = bundle.infoDictionary;
        NSDictionary *defaults = info[@"DMNativeEnvironment"];
        if (![defaults isKindOfClass:NSDictionary.class]) return;
        NSDictionary *inherited = NSProcessInfo.processInfo.environment;
        NSString *support = [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject
            stringByAppendingPathComponent:info[@"CFBundleName"] ?: @DM_GAME_NAME];
        for (NSString *key in defaults) {
            id value = defaults[key];
            if (![key isKindOfClass:NSString.class] || ![key hasPrefix:@"DM_"] || ![value isKindOfClass:NSString.class])
                die("[RED] invalid native bundle environment");
            NSString *resolved = [value stringByReplacingOccurrencesOfString:@"${RESOURCES}" withString:bundle.resourcePath];
            resolved = [resolved stringByReplacingOccurrencesOfString:@"${CONTENTS}" withString:[bundle.bundlePath stringByAppendingPathComponent:@"Contents"]];
            resolved = [resolved stringByReplacingOccurrencesOfString:@"${APP_SUPPORT}" withString:support];
            if (setenv(key.UTF8String, resolved.UTF8String, 0)) die("[RED] cannot set native bundle environment");
        }
        const char *settings = getenv("DM_SETTINGS_DIR");
        if (settings) {
            NSString *path = [[NSString stringWithUTF8String:settings] stringByAppendingPathComponent:@"env.txt"];
            NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
            NSCharacterSet *invalid = [[NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_"] invertedSet];
            for (NSString *line in [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
                if (!line.length || [line hasPrefix:@"#"]) continue;
                NSRange eq = [line rangeOfString:@"="];
                if (eq.location == NSNotFound) continue;
                NSString *key = [line substringToIndex:eq.location];
                if (![key hasPrefix:@"DM_"] || [key rangeOfCharacterFromSet:invalid].location != NSNotFound || inherited[key]) continue;
                NSString *value = [line substringFromIndex:eq.location + 1];
                if (setenv(key.UTF8String, value.UTF8String, 1)) die("[RED] cannot set native app preference");
            }
        }
        const char *scene = getenv("DM_SCENE_HEIGHT"), *overlays = getenv("DM_SCENE_OVERLAY_ROOT");
        if (DM_GAME_PROGRAM_ID == 0x0400380020056000ull && scene && overlays &&
            (!strcmp(scene, "720") || !strcmp(scene, "900"))) {
            NSString *path = [@(overlays) stringByAppendingPathComponent:@(scene)];
            if ([NSFileManager.defaultManager fileExistsAtPath:[path stringByAppendingPathComponent:@"Gyml/Default.game__gfx__parameter__ModuleParam.bgyml"]]) {
                const char *existing = getenv("DM_ROMFS_OVERLAY");
                NSString *roots = existing && *existing ? [NSString stringWithFormat:@"%s:%@", existing, path] : path;
                setenv("DM_ROMFS_OVERLAY", roots.UTF8String, 1);
                LOG("Raiders handheld scene height %s; HUD 1080", scene);
            } else LOG("[RED] scene resolution overlay is missing: %s", path.fileSystemRepresentation);
        }
        if (*argc != 1) return;
        for (NSString *key in @[@"DM_ROOT", @"DM_SAVE", @"DM_TEMP", @"DM_SETTINGS_DIR"]) {
            const char *value = getenv(key.UTF8String);
            if (value && ![NSFileManager.defaultManager createDirectoryAtPath:[NSString stringWithUTF8String:value]
                withIntermediateDirectories:YES attributes:nil error:nil]) die("[RED] cannot create native app directory for %s", key.UTF8String);
        }
        NSString *modules = info[@"DMNativeModuleDirectory"];
        if (![modules isKindOfClass:NSString.class] || !modules.length) die("[RED] native bundle module directory is missing");
        if (!modules.isAbsolutePath) modules = [bundle.resourcePath stringByAppendingPathComponent:modules];
        static char *args[3];
        args[0] = (*argv)[0]; args[1] = strdup(modules.fileSystemRepresentation);
        *argc = 2; *argv = args;
        const char *root = getenv("DM_ROOT");
        if (root) {
            NSString *logs = [[NSString stringWithUTF8String:root] stringByAppendingPathComponent:@"logs"];
            NSError *error = nil;
            if (![NSFileManager.defaultManager createDirectoryAtPath:logs withIntermediateDirectories:YES attributes:nil error:&error])
                die("[RED] cannot create native app log directory: %s", error.description.UTF8String);
            NSString *name = [NSString stringWithFormat:@"native-app-%lld-%d.log", (long long)time(NULL), getpid()];
            NSString *path = [logs stringByAppendingPathComponent:name];
            if (!freopen(path.fileSystemRepresentation, "a", stderr) || dup2(fileno(stderr), STDOUT_FILENO) < 0)
                die("[RED] cannot open native app log");
        }
    }
}

static CAMetalLayer *g_layer;
int dm_thermal_now(void) { return (int)NSProcessInfo.processInfo.thermalState; }
// Keep Metal's drawable in backing pixels when the window resizes or moves
// between displays. A stale drawable is stretched by AppKit after presentation.
@interface DmGameView : NSView
- (void)updateDrawableSize;
@end
@implementation DmGameView
- (void)updateDrawableSize {
    if (![self.layer isKindOfClass:CAMetalLayer.class]) return;
    CAMetalLayer *layer = (CAMetalLayer *)self.layer;
    NSSize pixels = [self convertSizeToBacking:self.bounds.size];
    if (pixels.width < 1 || pixels.height < 1) return;
    const char *output = getenv("DM_OUTPUT_RES");
    if (output && !strcmp(output, "3840x2160")) pixels = NSMakeSize(3840, 2160);
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    layer.contentsScale = self.window.backingScaleFactor ?: 1;
    CGSize size = CGSizeMake(round(pixels.width), round(pixels.height));
    if (!CGSizeEqualToSize(layer.drawableSize, size)) {
        layer.drawableSize = size;
        LOG("presentation output %.0fx%.0f pixels", size.width, size.height);
    }
    [CATransaction commit];
}
- (void)setFrameSize:(NSSize)size { [super setFrameSize:size]; [self updateDrawableSize]; }
- (void)viewDidChangeBackingProperties { [super viewDidChangeBackingProperties]; [self updateDrawableSize]; }
- (void)viewDidMoveToWindow { [super viewDidMoveToWindow]; [self updateDrawableSize]; }
@end
static uint8_t g_down[128];   // keyboard state by macOS virtual key code
static uint64_t g_pad_btn;
static uint64_t g_mouse_btn;
static int g_mouse_captured;
static NSWindow *g_mouse_window;
static NSPoint g_mouse_location;
static int32_t g_pad_lx, g_pad_ly, g_pad_rx, g_pad_ry;
static pthread_mutex_t g_mu = PTHREAD_MUTEX_INITIALIZER;

void *front_metal_layer(void) { return (__bridge void *)g_layer; }
// The original game's 16:9 constants, behavior unchanged; DM_GAME_RES=<width>x<height> (docked mode; handheld scaled by 720/900) is only for side-by-side comparison with iOS widescreen
uint64_t front_game_res(int docked) {
    unsigned w, h; const char *e = getenv("DM_GAME_RES");
    if (e && sscanf(e, "%ux%u", &w, &h) == 2) return docked ? (uint64_t)h << 32 | w : (uint64_t)(h * 4 / 5) << 32 | (w * 4 / 5 + 3) / 4 * 4;
    return docked ? 900ull << 32 | 1600 : 720ull << 32 | 1280;
}

static int32_t clamp_axis(int32_t a, int32_t b) { int32_t v = a + b; return v > 32767 ? 32767 : v < -32767 ? -32767 : v; }
static int held(int act) { uint16_t c = g_dmset_bind[act]; return c < 128 && g_down[c]; }
static void push(void) {
    pthread_mutex_lock(&g_mu);
    uint64_t b = g_pad_btn | g_mouse_btn;
    for (int i = 0; i < 16; i++) if (held(i)) b |= 1ull << i;   // the first 16 actions are the dm_input.h button bits
    int32_t lx = clamp_axis((held(DMB_LRIGHT) - held(DMB_LLEFT)) * 32767, g_pad_lx), ly = clamp_axis((held(DMB_LUP) - held(DMB_LDOWN)) * 32767, g_pad_ly);
    int32_t rx = clamp_axis((held(DMB_RRIGHT) - held(DMB_RLEFT)) * 32767, g_pad_rx), ry = clamp_axis((held(DMB_RUP) - held(DMB_RDOWN)) * 32767, g_pad_ry);
    pthread_mutex_unlock(&g_mu);
    dm_input_set(b, lx, ly, rx, ry);
}
static int32_t axis(float v) { return (int32_t)(v * 32767.0f); }
static void read_pad(GCExtendedGamepad *g) {   // same mapping as dm/ios/Sources/DmGamepad.m
    uint64_t m = 0;
    #define K(btn, bit) if (btn.isPressed) m |= 1ull << bit
    if (g_dmset_pad_by_label) { K(g.buttonA, DMB_A); K(g.buttonB, DMB_B); K(g.buttonX, DMB_X); K(g.buttonY, DMB_Y); }   // by label: the button marked A is A
    else { K(g.buttonB, DMB_A); K(g.buttonA, DMB_B); K(g.buttonY, DMB_X); K(g.buttonX, DMB_Y); }                       // by position: right A, bottom B, top X, left Y
    K(g.leftShoulder, DMB_L); K(g.rightShoulder, DMB_R); K(g.leftTrigger, DMB_ZL); K(g.rightTrigger, DMB_ZR);
    K(g.buttonMenu, DMB_PLUS); if (g.buttonOptions) K(g.buttonOptions, DMB_MINUS);
    if (g.leftThumbstickButton) K(g.leftThumbstickButton, DMB_LS); if (g.rightThumbstickButton) K(g.rightThumbstickButton, DMB_RS);
    K(g.dpad.left, DMB_DLEFT); K(g.dpad.up, DMB_DUP); K(g.dpad.right, DMB_DRIGHT); K(g.dpad.down, DMB_DDOWN);
    #undef K
    pthread_mutex_lock(&g_mu);
    g_pad_btn = m; g_pad_lx = axis(g.leftThumbstick.xAxis.value); g_pad_ly = axis(g.leftThumbstick.yAxis.value);
    g_pad_rx = axis(g.rightThumbstick.xAxis.value); g_pad_ry = axis(g.rightThumbstick.yAxis.value);
    pthread_mutex_unlock(&g_mu);
    push();
}
static void pads_changed(void) {
    int any = 0;
    for (GCController *c in GCController.controllers) if (c.extendedGamepad) {
        any = 1; LOG("controller: %s", c.vendorName.UTF8String ?: "?");
        c.extendedGamepad.valueChangedHandler = ^(GCExtendedGamepad *g, GCControllerElement *el) { (void)el; read_pad(g); };
        read_pad(c.extendedGamepad);
    }
    if (!any) { pthread_mutex_lock(&g_mu); g_pad_btn = 0; g_pad_lx = g_pad_ly = g_pad_rx = g_pad_ry = 0; pthread_mutex_unlock(&g_mu); push(); }
}
static void settings_changed(void) { pads_changed(); }   // re-read the controllers with the new mapping, then push the keyboard with the new bindings
static void on_key(NSEvent *e, int down) {
    unsigned short c = e.keyCode;
    if (c < 128) g_down[c] = (uint8_t)down;
    push();
}
static void on_flags(NSEvent *e) {   // a modifier key bound on its own (Shift / Control / Option): down while its flag is set
    NSEventModifierFlags m;
    switch (e.keyCode) { case 56: case 60: m = NSEventModifierFlagShift; break; case 59: case 62: m = NSEventModifierFlagControl; break; case 58: case 61: m = NSEventModifierFlagOption; break; default: return; }
    g_down[e.keyCode] = (e.modifierFlags & m) != 0;
    push();
}
static void release_keys(void) {
    memset(g_down, 0, sizeof g_down);
    pthread_mutex_lock(&g_mu);g_mouse_btn=0;pthread_mutex_unlock(&g_mu);push();
}   // focus lost: a key released elsewhere sends no key up here
static void mouse_capture(int capture) {
    capture=!!capture;
    if(capture==g_mouse_captured)return;
    if(capture) {
        if(!g_mouse_window.keyWindow || !NSApp.active)return;
        if(CGAssociateMouseAndMouseCursorPosition(false)!=kCGErrorSuccess) { LOG("mouse capture unavailable");return; }
        g_mouse_location=g_mouse_window.mouseLocationOutsideOfEventStream;
        [NSCursor hide];
    } else {
        CGAssociateMouseAndMouseCursorPosition(true);[NSCursor unhide];
    }
    g_mouse_captured=capture;release_keys();
    LOG("mouse gyro aim %s",capture?"captured (Escape releases)":"released");
}
static void mouse_button(uint64_t button,int down) {
    pthread_mutex_lock(&g_mu);
    if(down)g_mouse_btn|=button;else g_mouse_btn&=~button;
    pthread_mutex_unlock(&g_mu);push();
}
static void mouse_motion(NSEvent *e) {
    CGFloat dx=e.deltaX,dy=e.deltaY;
    NSPoint location=e.locationInWindow;
    // Remote and accessibility pointers can supply positions without device
    // deltas. A captured physical pointer normally stays at one position.
    if(g_mouse_captured && dx==0 && dy==0) {
        dx=location.x-g_mouse_location.x;dy=g_mouse_location.y-location.y;
    }
    g_mouse_location=location;
    dm_motion_rotate((float)dy*.003f,(float)dx*.003f);
}

static NSMenuItem *menu_item(NSString *title, SEL sel, NSString *key, NSEventModifierFlags mods, id target) {
    NSMenuItem *i = [[NSMenuItem alloc] initWithTitle:title action:sel keyEquivalent:key];
    i.keyEquivalentModifierMask = mods; i.target = target; return i;
}
@interface DmMenuTarget : NSObject
@end
@implementation DmMenuTarget
- (void)settings:(id)s { (void)s; mouse_capture(0);dmset_show(); }
- (void)mouseAim:(id)s { (void)s;mouse_capture(!g_mouse_captured); }
- (void)raidersMod:(NSMenuItem *)item {
    unsigned bit=[item.representedObject unsignedIntValue];
    dm_raiders_mods_set(bit ? dm_raiders_mods_get()^bit : 0);
}
- (void)raidersHelp:(id)sender {
    (void)sender;
    mouse_capture(0);
    NSAlert *a=[NSAlert new];a.messageText=@"Raiders Mods";
    a.informativeText=@"Player Flight / Noclip\nLeft stick: fly relative to the camera, including its pitch\nR / L: ascend / descend\nLeft-stick click: move faster\n\nClick the game to capture the mouse for gyro aiming. Move the mouse to look, left-click to fire, and right-click to swim. Escape releases the mouse; Command-Shift-M toggles capture.\n\nDefault keys: WASD to fly, U / E up / down, F to boost, IJKL to look. Rebindings in Settings also apply.\n\nInfinite Ink keeps both ink reserves full. Rapid Fire removes the shooter's repeat delay while firing. Disable All Mods restores normal movement and weapon behavior. Mods start disabled on each launch.";
    [a addButtonWithTitle:@"OK"];[a runModal];
}
- (BOOL)validateMenuItem:(NSMenuItem *)item {
    if(item.action==@selector(mouseAim:)) {item.state=g_mouse_captured?NSControlStateValueOn:NSControlStateValueOff;return YES;}
    if(item.action==@selector(raidersMod:)) {
        unsigned bit=[item.representedObject unsignedIntValue];
        item.state=bit && (dm_raiders_mods_get()&bit) ? NSControlStateValueOn : NSControlStateValueOff;
        return dm_raiders_mods_available();
    }
    return YES;
}
@end
static void build_menus(NSString *name) {
    static DmMenuTarget *t; t = [DmMenuTarget new];
    NSMenu *bar = [NSMenu new];
    NSMenu *app = [[NSMenu alloc] initWithTitle:name];
    [app addItem:menu_item([@"About " stringByAppendingString:name], @selector(orderFrontStandardAboutPanel:), @"", 0, NSApp)];
    [app addItem:NSMenuItem.separatorItem];
    [app addItem:menu_item(@"Settings…", @selector(settings:), @",", NSEventModifierFlagCommand, t)];
    [app addItem:NSMenuItem.separatorItem];
    [app addItem:menu_item([@"Hide " stringByAppendingString:name], @selector(hide:), @"h", NSEventModifierFlagCommand, NSApp)];
    [app addItem:menu_item(@"Hide Others", @selector(hideOtherApplications:), @"h", NSEventModifierFlagCommand | NSEventModifierFlagOption, NSApp)];
    [app addItem:menu_item(@"Show All", @selector(unhideAllApplications:), @"", 0, NSApp)];
    [app addItem:NSMenuItem.separatorItem];
    [app addItem:menu_item([@"Quit " stringByAppendingString:name], @selector(terminate:), @"q", NSEventModifierFlagCommand, NSApp)];
    NSMenuItem *ai = [NSMenuItem new]; ai.submenu = app; [bar addItem:ai];
    NSMenu *view = [[NSMenu alloc] initWithTitle:@"View"];
    [view addItem:menu_item(@"Enter Full Screen", @selector(toggleFullScreen:), @"f", NSEventModifierFlagCommand | NSEventModifierFlagControl, nil)];
    if(DM_GAME_PROGRAM_ID==0x0400380020056000ull)
        [view addItem:menu_item(@"Capture Mouse for Gyro Aim",@selector(mouseAim:),@"m",NSEventModifierFlagCommand|NSEventModifierFlagShift,t)];
    NSMenuItem *vi = [NSMenuItem new]; vi.submenu = view; [bar addItem:vi];
    if(DM_GAME_PROGRAM_ID==0x0400380020056000ull) {
        NSMenu *mods=[[NSMenu alloc] initWithTitle:@"Mods"];
        NSArray *labels=@[@"Player Flight / Noclip",@"Infinite Ink",@"Rapid Fire",@"Disable All Mods"];
        NSArray *keys=@[@"f",@"i",@"r",@"0"];
        unsigned bits[]={DM_RAIDERS_FLY,DM_RAIDERS_INFINITE_INK,DM_RAIDERS_RAPID_FIRE,0};
        for(unsigned i=0;i<4;i++) {
            if(i==3)[mods addItem:NSMenuItem.separatorItem];
            NSMenuItem *item=menu_item(labels[i],@selector(raidersMod:),keys[i],NSEventModifierFlagCommand|NSEventModifierFlagShift,t);
            item.representedObject=@(bits[i]);[mods addItem:item];
        }
        [mods addItem:NSMenuItem.separatorItem];
        [mods addItem:menu_item(@"Mod Controls…",@selector(raidersHelp:),@"",0,t)];
        NSMenuItem *mi=[NSMenuItem new];mi.submenu=mods;[bar addItem:mi];
    }
    NSMenu *win = [[NSMenu alloc] initWithTitle:@"Window"];
    [win addItem:menu_item(@"Minimize", @selector(performMiniaturize:), @"m", NSEventModifierFlagCommand, nil)];
    NSMenuItem *wi = [NSMenuItem new]; wi.submenu = win; [bar addItem:wi];
    NSApp.mainMenu = bar; NSApp.windowsMenu = win;
}

typedef struct { void (*fn)(void); } guest_arg;
static void *guest_tramp(void *p) {
    static char alt[65536];                       // The signal alternate stack is per thread; crash printing must also work on the guest thread
    stack_t ss = {.ss_sp = alt, .ss_size = sizeof alt}; sigaltstack(&ss, 0);
    ((guest_arg *)p)->fn(); LOG("guest thread finished"); exit(0);
}

void front_run(void (*guest)(void)) {
    if (!getenv("DM_WINDOW")) { guest(); return; }
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        dmset_load(); dmset_on_change(settings_changed);
        NSString *name = NSBundle.mainBundle.infoDictionary[@"CFBundleName"] ?: @DM_GAME_NAME;
        build_menus(name);
        NSRect r = NSMakeRect(0, 0, 1280, 720);
        NSWindow *win = [[NSWindow alloc] initWithContentRect:r
                                                    styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
                                                      backing:NSBackingStoreBuffered defer:NO];
        win.title = @DM_GAME_NAME;   // the game profile's name (game name label)
        DmGameView *v = [[DmGameView alloc] initWithFrame:r];
        win.contentView = v;
        g_mouse_window=win;win.acceptsMouseMovedEvents=YES;
        v.wantsLayer = YES;
        g_layer = [CAMetalLayer layer];
        g_layer.device = MTLCreateSystemDefaultDevice();
        g_layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
        g_layer.framebufferOnly = NO;   // MetalFX can write the drawable directly, including its reconstruction reads.
        g_layer.contentsScale = win.backingScaleFactor;
        v.layer = g_layer;
        [v updateDrawableSize];
        win.collectionBehavior = NSWindowCollectionBehaviorFullScreenPrimary;
        win.contentAspectRatio = NSMakeSize(16, 9);
        [win center];
        [win setFrameAutosaveName:@"GameWindow"];
        [win makeKeyAndOrderFront:nil];
        dm_motion_available(1);
        if (dmset_fullscreen()) [win toggleFullScreen:nil];
        [NSApp activateIgnoringOtherApps:YES];
        [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown | NSEventMaskKeyUp handler:^NSEvent *(NSEvent *e) {
            if (e.window != win) return e;   // Only swallow keys for the game window; other windows such as the software keyboard input box receive typing as usual
            if(g_mouse_captured && e.keyCode==53) {if(e.type==NSEventTypeKeyDown)mouse_capture(0);return nil;}
            if (e.modifierFlags & NSEventModifierFlagCommand) { if (e.type == NSEventTypeKeyDown) release_keys(); return e; }   // ⌘ shortcuts go to the menus
            if ((e.modifierFlags & NSEventModifierFlagOption) && e.keyCode >= 123 && e.keyCode <= 126) {
                if (e.type == NSEventTypeKeyDown) {
                    float pitch = e.keyCode == 125 ? 0.025f : e.keyCode == 126 ? -0.025f : 0;
                    float yaw = e.keyCode == 123 ? -0.025f : e.keyCode == 124 ? 0.025f : 0;
                    dm_motion_rotate(pitch, yaw);
                }
                return nil;
            }
            if (!e.isARepeat) on_key(e, e.type == NSEventTypeKeyDown);
            return nil;   // Swallow it to avoid the system beep
        }];
        [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskFlagsChanged handler:^NSEvent *(NSEvent *e) { if (e.window == win) on_flags(e); return e; }];
        // Mouse as a single-point touchscreen (for testing touch on the local machine, front.h dm_touch_set): left button down / drag = finger 0 at the normalized coordinates, release = lifted
        [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown | NSEventMaskLeftMouseDragged | NSEventMaskLeftMouseUp handler:^NSEvent *(NSEvent *e) {
            if (e.window != win) return e;
            if(DM_GAME_PROGRAM_ID==0x0400380020056000ull) {
                if(!g_mouse_captured) {
                    NSPoint p=[v convertPoint:e.locationInWindow fromView:nil];
                    if(e.type==NSEventTypeLeftMouseDown && NSPointInRect(p,v.bounds)) {mouse_capture(1);return nil;}
                    return e;
                }
                if(e.type==NSEventTypeLeftMouseDown)mouse_button(DM_BTN_ZR,1);
                if(e.type==NSEventTypeLeftMouseUp)mouse_button(DM_BTN_ZR,0);
                if(e.type==NSEventTypeLeftMouseDragged)mouse_motion(e);
                return nil;
            }
            if (e.type == NSEventTypeLeftMouseUp) { dm_touch_set(NULL, 0); return nil; }
            NSPoint p = [v convertPoint:e.locationInWindow fromView:nil]; NSSize sz = v.bounds.size;
            if (sz.width <= 0 || sz.height <= 0) return e;
            dm_touch t = {0, (float)(p.x / sz.width), (float)(1.0 - p.y / sz.height)};   // The AppKit view origin is at bottom left, the touchscreen origin is at top left
            dm_touch_set(&t, 1); return nil;
        }];
        GCController.shouldMonitorBackgroundEvents = NO;
        [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskMouseMoved | NSEventMaskRightMouseDown | NSEventMaskRightMouseDragged | NSEventMaskRightMouseUp handler:^NSEvent *(NSEvent *e) {
            if (e.window != win) return e;
            if(g_mouse_captured) {
                if(e.type==NSEventTypeRightMouseDown)mouse_button(DM_BTN_ZL,1);
                if(e.type==NSEventTypeRightMouseUp)mouse_button(DM_BTN_ZL,0);
                if(e.type==NSEventTypeMouseMoved || e.type==NSEventTypeRightMouseDragged)
                    mouse_motion(e);
                return nil;
            }
            if(e.type!=NSEventTypeRightMouseDragged)return e;
            dm_motion_rotate((float)e.deltaY * 0.003f, (float)e.deltaX * 0.003f);
            return nil;
        }];
        [[NSNotificationCenter defaultCenter] addObserverForName:GCControllerDidConnectNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) { (void)n; pads_changed(); }];
        [[NSNotificationCenter defaultCenter] addObserverForName:GCControllerDidDisconnectNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) { (void)n; pads_changed(); }];
        pads_changed();
        [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowWillCloseNotification object:win queue:nil
                                                      usingBlock:^(NSNotification *n) { (void)n;mouse_capture(0);exit(0); }];
        // Lifecycle (hle.h / dm.h): focus lost → 2, focus regained → 1; minimized → 3 + audio paused + GPU suspended, restored → resume (followed by focus regained → 1)
        NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
        [nc addObserverForName:NSApplicationWillTerminateNotification object:NSApp queue:nil usingBlock:^(NSNotification *n) { (void)n;mouse_capture(0); }];
        [nc addObserverForName:NSApplicationDidBecomeActiveNotification object:NSApp queue:nil usingBlock:^(NSNotification *n) { (void)n; LOG("Mac app became active"); }];
        [nc addObserverForName:NSApplicationDidResignActiveNotification object:NSApp queue:nil usingBlock:^(NSNotification *n) { (void)n;mouse_capture(0);LOG("Mac app resigned active"); }];
        LOG("Mac app active after window setup: %d", NSApp.active);
        [nc addObserverForName:NSWindowDidResignKeyNotification object:win queue:nil usingBlock:^(NSNotification *n) { (void)n;mouse_capture(0);release_keys(); if (!win.miniaturized) dm_focus_set(2); }];
        [nc addObserverForName:NSWindowDidBecomeKeyNotification object:win queue:nil usingBlock:^(NSNotification *n) { (void)n; dm_focus_set(1); }];
        [nc addObserverForName:NSWindowDidMiniaturizeNotification object:win queue:nil usingBlock:^(NSNotification *n) { (void)n; dm_focus_set(3); dm_audio_suspend(1); dm_gfx_suspend(1); }];
        [nc addObserverForName:NSWindowDidDeminiaturizeNotification object:win queue:nil usingBlock:^(NSNotification *n) { (void)n; dm_gfx_suspend(0); dm_audio_suspend(0); dm_focus_set(2); }];
        // Guest thread: 64 MiB stack (the Switch main thread stack is specified by npdm; the host gives plenty)
        static guest_arg ga; ga.fn = guest;
        pthread_attr_t a; pthread_attr_init(&a); pthread_attr_setstacksize(&a, 64u << 20);
        pthread_t th; if (pthread_create(&th, &a, guest_tramp, &ga)) die("pthread_create guest");
        [NSApp run];
    }
}

// Software keyboard input box (front.h): the main thread shows an NSAlert + text field and the guest thread waits synchronously for the result. Not shown in windowless mode (returns -1, the caller treats it as cancel)
int front_text_input(const char *title, const char *sub, const char *guide, const char *initial, int max_chars, char *out, int out_cap) {
    if (!g_layer) return -1;
    __block int r = 0;
    __block NSString *text = nil;
    dispatch_sync(dispatch_get_main_queue(), ^{
        NSAlert *a = [NSAlert new];
        a.messageText = title && *title ? @(title) : @"Input";
        NSString *info = [NSString stringWithFormat:@"%s%s%s", sub ? sub : "", sub && *sub && guide && *guide ? "\n" : "", guide ? guide : ""];
        a.informativeText = info;
        [a addButtonWithTitle:@"OK"]; [a addButtonWithTitle:@"Cancel"];
        NSTextField *f = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 300, 24)];
        f.stringValue = initial ? @(initial) : @"";
        if (guide && *guide) f.placeholderString = @(guide);
        a.accessoryView = f; a.window.initialFirstResponder = f;
        r = [a runModal] == NSAlertFirstButtonReturn;
        text = f.stringValue;
    });
    if (!r) return 0;
    (void)max_chars;                              // Truncation is done uniformly in hle_swkbd.c in UTF-16 units
    snprintf(out, out_cap, "%s", text.UTF8String);
    return 1;
}
