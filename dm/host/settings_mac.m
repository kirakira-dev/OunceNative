// Mac front end settings window (⌘,): keyboard bindings with Ryujinx's defaults, controller button mapping, and launch options.
// Bindings and controller options live in the user defaults and apply at once. Console mode, language and sound are environment switches read once at startup:
// they go to <DM_SETTINGS_DIR>/env.txt (the app's launcher exports its lines) and apply after a restart.
#import <Cocoa/Cocoa.h>
#import <GameController/GameController.h>
#include "settings_mac.h"
#include "game_profile.h"

uint16_t g_dmset_bind[DMSET_N];
int g_dmset_pad_by_label;
static void (*g_change_fn)(void);
void dmset_on_change(void (*fn)(void)) { g_change_fn = fn; }

// ---------- actions and Ryujinx's default keyboard layout (Ryujinx ConfigurationState: left stick WASD + F, D-pad arrows, - minus, E L, Q ZL;
// right stick IJKL + H, Z A, X B, C X, V Y, = plus, U R, O ZR) ----------
static const struct { const char *id, *label; uint16_t def; } k_act[DMSET_N] = {
    [DMB_A] = {"A", "A", 6},              [DMB_B] = {"B", "B", 7},             [DMB_X] = {"X", "X", 8},          [DMB_Y] = {"Y", "Y", 9},
    [DMB_LS] = {"LStick", "Stick Button", 3}, [DMB_RS] = {"RStick", "Stick Button", 4},
    [DMB_L] = {"L", "L", 14},             [DMB_R] = {"R", "R", 32},            [DMB_ZL] = {"ZL", "ZL", 12},      [DMB_ZR] = {"ZR", "ZR", 31},
    [DMB_PLUS] = {"Plus", "+", 24},       [DMB_MINUS] = {"Minus", "−", 27},
    [DMB_DLEFT] = {"DLeft", "D-Pad Left", 123}, [DMB_DUP] = {"DUp", "D-Pad Up", 126}, [DMB_DRIGHT] = {"DRight", "D-Pad Right", 124}, [DMB_DDOWN] = {"DDown", "D-Pad Down", 125},
    [DMB_LUP] = {"LUp", "Stick Up", 13},  [DMB_LDOWN] = {"LDown", "Stick Down", 1}, [DMB_LLEFT] = {"LLeft", "Stick Left", 0}, [DMB_LRIGHT] = {"LRight", "Stick Right", 2},
    [DMB_RUP] = {"RUp", "Stick Up", 34},  [DMB_RDOWN] = {"RDown", "Stick Down", 40}, [DMB_RLEFT] = {"RLeft", "Stick Left", 38}, [DMB_RRIGHT] = {"RRight", "Stick Right", 37},
};
static const int k_left[] = {DMB_LUP, DMB_LDOWN, DMB_LLEFT, DMB_LRIGHT, DMB_LS, DMB_DUP, DMB_DDOWN, DMB_DLEFT, DMB_DRIGHT, DMB_L, DMB_ZL, DMB_MINUS};
static const int k_right[] = {DMB_RUP, DMB_RDOWN, DMB_RLEFT, DMB_RRIGHT, DMB_RS, DMB_A, DMB_B, DMB_X, DMB_Y, DMB_R, DMB_ZR, DMB_PLUS};
#define NROWS (int)(sizeof k_left / sizeof *k_left)

static NSString *key_name(uint16_t c) {
    static NSString *const t[128] = {
        [0] = @"A", [1] = @"S", [2] = @"D", [3] = @"F", [4] = @"H", [5] = @"G", [6] = @"Z", [7] = @"X", [8] = @"C", [9] = @"V", [10] = @"§", [11] = @"B",
        [12] = @"Q", [13] = @"W", [14] = @"E", [15] = @"R", [16] = @"Y", [17] = @"T", [18] = @"1", [19] = @"2", [20] = @"3", [21] = @"4", [22] = @"6", [23] = @"5",
        [24] = @"=", [25] = @"9", [26] = @"7", [27] = @"-", [28] = @"8", [29] = @"0", [30] = @"]", [31] = @"O", [32] = @"U", [33] = @"[", [34] = @"I", [35] = @"P",
        [36] = @"Return", [37] = @"L", [38] = @"J", [39] = @"'", [40] = @"K", [41] = @";", [42] = @"\\", [43] = @",", [44] = @"/", [45] = @"N", [46] = @"M", [47] = @".",
        [48] = @"Tab", [49] = @"Space", [50] = @"`", [51] = @"Delete", [53] = @"Esc", [54] = @"Right ⌘", [55] = @"⌘", [56] = @"Shift", [57] = @"Caps Lock",
        [58] = @"Option", [59] = @"Control", [60] = @"Right Shift", [61] = @"Right Option", [62] = @"Right Control", [63] = @"fn",
        [65] = @"Keypad .", [67] = @"Keypad *", [69] = @"Keypad +", [71] = @"Clear", [75] = @"Keypad /", [76] = @"Enter", [78] = @"Keypad -", [81] = @"Keypad =",
        [82] = @"Keypad 0", [83] = @"Keypad 1", [84] = @"Keypad 2", [85] = @"Keypad 3", [86] = @"Keypad 4", [87] = @"Keypad 5", [88] = @"Keypad 6", [89] = @"Keypad 7",
        [91] = @"Keypad 8", [92] = @"Keypad 9", [96] = @"F5", [97] = @"F6", [98] = @"F7", [99] = @"F3", [100] = @"F8", [101] = @"F9", [103] = @"F11", [109] = @"F10",
        [111] = @"F12", [115] = @"Home", [116] = @"Page Up", [117] = @"Forward Delete", [118] = @"F4", [119] = @"End", [120] = @"F2", [121] = @"Page Down", [122] = @"F1",
        [123] = @"←", [124] = @"→", [125] = @"↓", [126] = @"↑",
    };
    if (c == DMSET_UNBOUND) return @"Unbound";
    return c < 128 && t[c] ? t[c] : [NSString stringWithFormat:@"Key %u", c];
}

// ---------- persistence ----------
static NSUserDefaults *ud(void) { return NSUserDefaults.standardUserDefaults; }
void dmset_load(void) {
    NSDictionary *b = [ud() dictionaryForKey:@"KeyBindings"];
    for (int i = 0; i < DMSET_N; i++) { NSNumber *n = b[@(k_act[i].id)]; g_dmset_bind[i] = n ? (uint16_t)n.unsignedIntValue : k_act[i].def; }
    g_dmset_pad_by_label = (int)[ud() integerForKey:@"PadByLabel"];
}
static void save_bindings(void) {
    NSMutableDictionary *b = [NSMutableDictionary dictionary];
    for (int i = 0; i < DMSET_N; i++) b[@(k_act[i].id)] = @(g_dmset_bind[i]);
    [ud() setObject:b forKey:@"KeyBindings"];
    if (g_change_fn) g_change_fn();
}
int dmset_fullscreen(void) { return [ud() boolForKey:@"StartFullScreen"]; }

// env.txt: KEY=VALUE lines; the keys this window manages are rewritten, every other line is kept
static NSString *env_path(void) {
    const char *d = getenv("DM_SETTINGS_DIR"); if (!d || !*d) d = getenv("DM_ROOT");
    return d ? [@(d) stringByAppendingPathComponent:@"env.txt"] : nil;
}
static NSMutableArray<NSString *> *env_lines(void) {
    NSString *s = env_path() ? [NSString stringWithContentsOfFile:env_path() encoding:NSUTF8StringEncoding error:nil] : nil;
    NSMutableArray *a = [[s componentsSeparatedByString:@"\n"] mutableCopy] ?: [NSMutableArray array];
    while (a.count && [a.lastObject length] == 0) [a removeLastObject];
    return a;
}
static NSString *env_get(NSString *k, NSString *dflt) {   // the file's value, else the running process's environment, else dflt
    for (NSString *l in env_lines()) if ([l hasPrefix:[k stringByAppendingString:@"="]]) return [l substringFromIndex:k.length + 1];
    const char *e = getenv(k.UTF8String); return e ? @(e) : dflt;
}
static void env_set(NSString *k, NSString *v) {   // v nil removes the key
    if (!env_path()) return;
    NSMutableArray *a = env_lines(); NSString *pre = [k stringByAppendingString:@"="];
    [a filterUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSString *l, NSDictionary *b) { (void)b; return ![l hasPrefix:pre]; }]];
    if (v) [a addObject:[pre stringByAppendingString:v]];
    [[[a componentsJoinedByString:@"\n"] stringByAppendingString:@"\n"] writeToFile:env_path() atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

// ---------- window ----------
static NSString *const k_lang_code[] = {@"en-US", @"en-GB", @"ja", @"fr", @"fr-CA", @"de", @"es", @"es-419", @"it", @"nl", @"ru", @"ko", @"zh-Hans", @"zh-Hant"};
static NSString *const k_lang_name[] = {@"English (US)", @"English (UK)", @"Japanese", @"French", @"French (Canada)", @"German", @"Spanish", @"Spanish (Latin America)",
                                        @"Italian", @"Dutch", @"Russian", @"Korean", @"Chinese (Simplified)", @"Chinese (Traditional)"};
#define NLANG (int)(sizeof k_lang_code / sizeof *k_lang_code)

@interface DmSettings : NSObject <NSWindowDelegate>
@property(strong) NSWindow *win;
@property(strong) NSMutableArray<NSButton *> *bindButtons;   // indexed by action
@property(strong) NSTextField *padLabel, *restartNote;
@property(strong) NSPopUpButton *modePop, *langPop, *padPop;
@property(strong) NSButton *soundBox, *fullBox, *rayBox;
@property(assign) int capturing;   // action waiting for a key, -1 none
@property(strong) id monitor;
@end

static DmSettings *g_set;
int dmset_capturing(void) { return g_set && g_set.capturing >= 0; }

static NSTextField *label(NSString *s, NSRect r) {
    NSTextField *t = [NSTextField labelWithString:s]; t.frame = r; return t;
}

@implementation DmSettings
- (instancetype)init {
    if (!(self = [super init])) return nil;
    _capturing = -1; _bindButtons = [NSMutableArray array];
    for (int i = 0; i < DMSET_N; i++) [_bindButtons addObject:[NSButton new]];
    _win = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 640, 560) styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO];
    _win.title = @"Settings"; _win.releasedWhenClosed = NO; _win.delegate = self;
    NSTabView *tabs = [[NSTabView alloc] initWithFrame:NSMakeRect(12, 12, 616, 536)];
    NSTabViewItem *ctl = [[NSTabViewItem alloc] initWithIdentifier:@"controls"]; ctl.label = @"Controls"; ctl.view = [self controlsView];
    NSTabViewItem *gen = [[NSTabViewItem alloc] initWithIdentifier:@"general"]; gen.label = @"General"; gen.view = [self generalView];
    [tabs addTabViewItem:ctl]; [tabs addTabViewItem:gen];
    [_win.contentView addSubview:tabs];
    [_win center];
    __weak DmSettings *ws = self;
    _monitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown | NSEventMaskFlagsChanged handler:^NSEvent *(NSEvent *e) {
        DmSettings *s = ws; if (!s || s.capturing < 0 || e.window != s.win) return e;
        return [s capture:e] ? nil : e;
    }];
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    [nc addObserver:self selector:@selector(refreshPads) name:GCControllerDidConnectNotification object:nil];
    [nc addObserver:self selector:@selector(refreshPads) name:GCControllerDidDisconnectNotification object:nil];
    [self refresh]; [self refreshPads];
    return self;
}

- (NSView *)joyconBox:(NSString *)title actions:(const int *)acts x:(CGFloat)x {
    NSBox *box = [[NSBox alloc] initWithFrame:NSMakeRect(x, 128, 284, 360)]; box.title = title;
    NSView *v = box.contentView; CGFloat y = 312;
    for (int r = 0; r < NROWS; r++, y -= 26) {
        int a = acts[r];
        if (r == 5) y -= 6;   // stick / buttons
        [v addSubview:label(@(k_act[a].label), NSMakeRect(8, y + 3, 110, 18))];
        NSButton *b = _bindButtons[a];
        b.frame = NSMakeRect(120, y, 148, 24); b.bezelStyle = NSBezelStyleRounded; b.tag = a; b.target = self; b.action = @selector(bindClicked:);
        [v addSubview:b];
    }
    return box;
}

- (NSView *)controlsView {
    NSView *v = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 596, 500)];
    [v addSubview:[self joyconBox:@"Left Joy-Con" actions:k_left x:8]];
    [v addSubview:[self joyconBox:@"Right Joy-Con" actions:k_right x:302]];
    NSTextField *hint = label(@"Click a binding, then press a key. Esc cancels, Delete clears. Changes apply immediately.", NSMakeRect(12, 100, 572, 18));
    hint.textColor = NSColor.secondaryLabelColor; [v addSubview:hint];
    [v addSubview:label(@"Controller buttons:", NSMakeRect(12, 64, 130, 18))];
    _padPop = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(146, 58, 300, 26) pullsDown:NO];
    [_padPop addItemsWithTitles:@[@"By position (Nintendo layout)", @"By label (Xbox / PlayStation)"]];
    _padPop.target = self; _padPop.action = @selector(padChanged:); [v addSubview:_padPop];
    _padLabel = label(@"", NSMakeRect(12, 34, 572, 18)); _padLabel.textColor = NSColor.secondaryLabelColor; [v addSubview:_padLabel];
    NSButton *reset = [NSButton buttonWithTitle:@"Reset to Ryujinx Defaults" target:self action:@selector(resetBindings:)];
    reset.frame = NSMakeRect(384, 0, 204, 28); [v addSubview:reset];
    return v;
}

- (NSView *)generalView {
    NSView *v = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 596, 500)];
    CGFloat y = 440;
    [v addSubview:label(@"Console mode:", NSMakeRect(12, y + 4, 120, 18))];
    _modePop = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(140, y, 280, 26) pullsDown:NO];
    [_modePop addItemsWithTitles:@[@"Docked (higher resolution)", @"Handheld (higher frame rate)"]];
    _modePop.target = self; _modePop.action = @selector(envChanged:); [v addSubview:_modePop];
    y -= 40;
    [v addSubview:label(@"Game language:", NSMakeRect(12, y + 4, 120, 18))];
    _langPop = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(140, y, 280, 26) pullsDown:NO];
    for (int i = 0; i < NLANG; i++) [_langPop addItemWithTitle:k_lang_name[i]];
    _langPop.target = self; _langPop.action = @selector(envChanged:); [v addSubview:_langPop];
    y -= 40;
    _soundBox = [NSButton checkboxWithTitle:@"Sound" target:self action:@selector(envChanged:)]; _soundBox.frame = NSMakeRect(138, y, 280, 22); [v addSubview:_soundBox];
    y -= 30;
    _fullBox = [NSButton checkboxWithTitle:@"Start in full screen" target:self action:@selector(fullChanged:)]; _fullBox.frame = NSMakeRect(138, y, 280, 22); [v addSubview:_fullBox];
    if(DM_GAME_PROGRAM_ID==0x0400380020056000ull) {
        y -= 30;
        _rayBox = [NSButton checkboxWithTitle:@"Ray-traced ambient occlusion (experimental)" target:self action:@selector(envChanged:)];
        _rayBox.frame=NSMakeRect(138,y,420,22);[v addSubview:_rayBox];
    }
    y -= 44;
    _restartNote = label(@"Launch options apply after a restart.", NSMakeRect(12, y, 420, 18));
    _restartNote.textColor = NSColor.secondaryLabelColor; [v addSubview:_restartNote];
    NSButton *restart = [NSButton buttonWithTitle:@"Restart Now" target:self action:@selector(restart:)];
    restart.frame = NSMakeRect(440, y - 6, 140, 28); restart.enabled = [NSBundle.mainBundle.bundlePath hasSuffix:@".app"]; [v addSubview:restart];
    y -= 70;
    NSButton *saves = [NSButton buttonWithTitle:@"Open Save Folder" target:self action:@selector(openSaves:)]; saves.frame = NSMakeRect(8, y, 160, 28); [v addSubview:saves];
    NSButton *log = [NSButton buttonWithTitle:@"Open Log" target:self action:@selector(openLog:)]; log.frame = NSMakeRect(176, y, 120, 28); [v addSubview:log];
    y -= 60;
    NSTextField *keys = label(@"Window shortcuts: ⌘, settings · ⌃⌘F full screen · ⌘Q quit", NSMakeRect(12, y, 572, 18));
    keys.textColor = NSColor.secondaryLabelColor; [v addSubview:keys];
    return v;
}

- (void)refresh {
    for (int i = 0; i < DMSET_N; i++) _bindButtons[i].title = i == _capturing ? @"Press a key…" : key_name(g_dmset_bind[i]);
    [_padPop selectItemAtIndex:g_dmset_pad_by_label ? 1 : 0];
    [_modePop selectItemAtIndex:[env_get(@"DM_OPMODE", DM_GAME_OPMODE ? @"1" : @"0") intValue] == 0 ? 1 : 0];
    NSString *lang = env_get(@"DM_LANG", @"en-US"); NSInteger li = 0;
    for (int i = 0; i < NLANG; i++) if ([k_lang_code[i] caseInsensitiveCompare:lang] == NSOrderedSame) li = i;
    [_langPop selectItemAtIndex:li];
    _soundBox.state = [env_get(@"DM_AUDIO", @"1") intValue] ? NSControlStateValueOn : NSControlStateValueOff;
    _fullBox.state = dmset_fullscreen() ? NSControlStateValueOn : NSControlStateValueOff;
    _rayBox.state = [env_get(@"DM_RAYTRACE", @"off") isEqualToString:@"ao"] ? NSControlStateValueOn : NSControlStateValueOff;
}
- (void)refreshPads {
    NSMutableArray *n = [NSMutableArray array];
    for (GCController *c in GCController.controllers) if (c.extendedGamepad) [n addObject:c.vendorName ?: @"Controller"];
    _padLabel.stringValue = n.count ? [@"Connected: " stringByAppendingString:[n componentsJoinedByString:@", "]] : @"No controller connected (Switch Pro, Joy-Con, Xbox and DualSense controllers work over Bluetooth or USB).";
}

- (void)bindClicked:(NSButton *)b { _capturing = (int)b.tag; [self refresh]; }
- (BOOL)capture:(NSEvent *)e {
    uint16_t c = e.keyCode;
    if (e.type == NSEventTypeFlagsChanged) {   // a modifier key on its own: bind it when it goes down
        NSEventModifierFlags f = e.modifierFlags, m = 0;
        switch (c) { case 56: case 60: m = NSEventModifierFlagShift; break; case 59: case 62: m = NSEventModifierFlagControl; break; case 58: case 61: m = NSEventModifierFlagOption; break; default: return YES; }
        if (!(f & m)) return YES;
    } else if (e.modifierFlags & NSEventModifierFlagCommand) return NO;   // ⌘ shortcuts keep working
    if (c == 53) { _capturing = -1; [self refresh]; return YES; }        // Esc: cancel
    int a = _capturing; _capturing = -1;
    if (c == 51) g_dmset_bind[a] = DMSET_UNBOUND;                          // Delete: clear
    else {
        for (int i = 0; i < DMSET_N; i++) if (i != a && g_dmset_bind[i] == c) g_dmset_bind[i] = DMSET_UNBOUND;   // one action per key
        g_dmset_bind[a] = c;
    }
    save_bindings(); [self refresh];
    return YES;
}
- (void)resetBindings:(id)s { (void)s; for (int i = 0; i < DMSET_N; i++) g_dmset_bind[i] = k_act[i].def; _capturing = -1; save_bindings(); [self refresh]; }
- (void)padChanged:(id)s { (void)s; g_dmset_pad_by_label = (int)_padPop.indexOfSelectedItem; [ud() setInteger:g_dmset_pad_by_label forKey:@"PadByLabel"]; if (g_change_fn) g_change_fn(); }
- (void)fullChanged:(id)s { (void)s; [ud() setBool:_fullBox.state == NSControlStateValueOn forKey:@"StartFullScreen"]; }
- (void)envChanged:(id)s {
    (void)s;
    env_set(@"DM_OPMODE", _modePop.indexOfSelectedItem == 1 ? @"0" : @"1");
    env_set(@"DM_LANG", k_lang_code[_langPop.indexOfSelectedItem]);
    env_set(@"DM_AUDIO", _soundBox.state == NSControlStateValueOn ? @"1" : @"0");
    if(_rayBox)env_set(@"DM_RAYTRACE",_rayBox.state==NSControlStateValueOn?@"ao":@"off");
    _restartNote.stringValue = @"Saved. Restart the game to apply launch options.";
    _restartNote.textColor = NSColor.systemOrangeColor;
}
- (void)restart:(id)s {
    (void)s;
    NSWorkspaceOpenConfiguration *cfg = [NSWorkspaceOpenConfiguration configuration]; cfg.createsNewApplicationInstance = YES;
    [NSWorkspace.sharedWorkspace openApplicationAtURL:NSBundle.mainBundle.bundleURL configuration:cfg completionHandler:^(NSRunningApplication *app, NSError *err) { (void)app; if (!err) exit(0); }];
}
- (void)openSaves:(id)s { (void)s; const char *d = getenv("DM_SAVE"); if (d) [NSWorkspace.sharedWorkspace openURL:[NSURL fileURLWithPath:@(d)]]; }
- (void)openLog:(id)s {
    (void)s; const char *d = getenv("DM_SETTINGS_DIR");
    if (d) [NSWorkspace.sharedWorkspace openURL:[NSURL fileURLWithPath:[@(d) stringByAppendingPathComponent:@"log.txt"]]];
}
- (void)windowWillClose:(NSNotification *)n { (void)n; _capturing = -1; [self refresh]; }
@end

void dmset_show(void) {
    if (!g_set) g_set = [DmSettings new];
    [g_set refresh];
    [g_set.win makeKeyAndOrderFront:nil];
}
