#import <Foundation/Foundation.h>
#import <GameController/GameController.h>
#import <mach/mach.h>
#import <mach-o/dyld.h>
#import <dlfcn.h>
#import <math.h>
#import <libkern/OSCacheControl.h>

#define PI_1_4  0.78539816339744f
#define PI_1_2  1.57079632679489f
#define PI_3_4  2.35619449019234f

#define GAMEPAD_DEADZONE_LEFT_STICK   7849.0f
#define GAMEPAD_DEADZONE_RIGHT_STICK  8689.0f
#define GAMEPAD_DEADZONE_TRIGGER      30.0f

enum GAMEPAD_STICKDIR {
    STICKDIR_CENTER = 0,
    STICKDIR_UP     = 1,
    STICKDIR_DOWN   = 2,
    STICKDIR_LEFT   = 3,
    STICKDIR_RIGHT  = 4
};

typedef struct {
    int x, y;
    float nx, ny;
    float length;
    float angle;
    int dirLast, dirCurrent;
} GamepadAxis;

typedef struct {
    int value;
    float length;
    int pressedLast, pressedCurrent;
} GamepadTrigInfo;

typedef struct {
    GamepadAxis stick[2];
    GamepadTrigInfo trigger[2];
    int bLast, bCurrent, flags;
} GamepadState;

static GamepadState *g_gamepad_state = NULL;

typedef void* (*get_steam_client_t)(void);
typedef void (*addCBResult_t)(void *this, int iCallback, void *pubParam, uint32_t cubParam);
typedef void (*RunCallbacks_t)(void *this, bool b1, bool b2);
typedef void (*RegisterCallback_t)(void *pCallback, int iCallback);
typedef bool (*Init_t)(void);

static get_steam_client_t g_get_steam_client = NULL;
static addCBResult_t g_addCBResult = NULL;
static RunCallbacks_t g_pRunCallbacks = NULL;
static RegisterCallback_t g_orig_RegisterCallback = NULL;
static Init_t g_orig_Init = NULL;

static bool g_was_connected = false;
static int g_initial_sync_frames = 0;
static bool g_device_callbacks_enabled = false;
static char g_app_path[PATH_MAX] = {0};

static void update_stick(GamepadAxis *axis, float deadzone) {
    axis->length = sqrtf((float)(axis->x * axis->x) + (float)(axis->y * axis->y));

    if (axis->length > deadzone) {
        if (axis->length > 32767.0f) {
            axis->length = 32767.0f;
        }
        axis->nx = axis->x / axis->length;
        axis->ny = axis->y / axis->length;
        axis->length -= deadzone;
        axis->length /= (32767.0f - deadzone);
        axis->angle = atan2f((float)axis->y, (float)axis->x);
    } else {
        axis->x = axis->y = 0;
        axis->nx = axis->ny = 0.0f;
        axis->length = axis->angle = 0.0f;
    }

    axis->dirLast = axis->dirCurrent;
    axis->dirCurrent = STICKDIR_CENTER;

    if (axis->length != 0.0f) {
        if (axis->angle >= PI_1_4 && axis->angle < PI_3_4) {
            axis->dirCurrent = STICKDIR_UP;
        } else if (axis->angle >= -PI_3_4 && axis->angle < -PI_1_4) {
            axis->dirCurrent = STICKDIR_DOWN;
        } else if (axis->angle >= PI_3_4 || axis->angle < -PI_3_4) {
            axis->dirCurrent = STICKDIR_LEFT;
        } else {
            axis->dirCurrent = STICKDIR_RIGHT;
        }
    }
}

static void update_trigger(GamepadTrigInfo *trig) {
    trig->pressedLast = trig->pressedCurrent;

    if (trig->value > (int)GAMEPAD_DEADZONE_TRIGGER) {
        trig->length = ((trig->value - GAMEPAD_DEADZONE_TRIGGER) / (255.0f - GAMEPAD_DEADZONE_TRIGGER));
        trig->pressedCurrent = 1;
    } else {
        trig->value = 0;
        trig->length = 0.0f;
        trig->pressedCurrent = 0;
    }
}

void my_gamepad_update(void) {
    if (!g_gamepad_state) return;
    
    g_gamepad_state->bLast = g_gamepad_state->bCurrent;
    
    GCController *controller = nil;
    if ([GCController current] && [GCController current].extendedGamepad) {
        controller = [GCController current];
    } else {
        for (GCController *c in [GCController controllers]) {
            if (c.extendedGamepad) {
                controller = c;
                NSString *name = c.vendorName ?: @"";
                if ([name containsString:@"Xbox"] || [name containsString:@"Direwolf"] || [name containsString:@"Controller"]) {
                    break;
                }
            }
        }
    }
    
    if (!controller || !controller.extendedGamepad) {
        if (getenv("SIMULATE_GAMEPAD")) {
            g_gamepad_state->flags |= 1;
            g_gamepad_state->bCurrent = (1 << 12); // Button A (SELECT)
            g_gamepad_state->stick[0].x = 15000;
            g_gamepad_state->stick[0].y = 15000;
            update_stick(&g_gamepad_state->stick[0], GAMEPAD_DEADZONE_LEFT_STICK);
            return;
        }
        g_gamepad_state->flags &= ~1;
        return;
    }
    
    GCExtendedGamepad *pad = controller.extendedGamepad;
    
    int b = 0;
    if (pad.dpad.up.isPressed) b |= (1 << 0);
    if (pad.dpad.down.isPressed) b |= (1 << 1);
    if (pad.dpad.left.isPressed) b |= (1 << 2);
    if (pad.dpad.right.isPressed) b |= (1 << 3);
    
    if (pad.buttonMenu.isPressed) b |= (1 << 4);
    if (pad.buttonOptions && pad.buttonOptions.isPressed) b |= (1 << 5);
    
    if (pad.leftThumbstickButton && pad.leftThumbstickButton.isPressed) b |= (1 << 6);
    if (pad.rightThumbstickButton && pad.rightThumbstickButton.isPressed) b |= (1 << 7);
    
    if (pad.leftShoulder.isPressed) b |= (1 << 8);
    if (pad.rightShoulder.isPressed) b |= (1 << 9);
    
    if (pad.buttonA.isPressed) b |= (1 << 12);
    if (pad.buttonB.isPressed) b |= (1 << 13);
    if (pad.buttonX.isPressed) b |= (1 << 14);
    if (pad.buttonY.isPressed) b |= (1 << 15);
    
    g_gamepad_state->bCurrent = b;
    
    g_gamepad_state->trigger[0].value = (int)(pad.leftTrigger.value * 255.0f);
    g_gamepad_state->trigger[1].value = (int)(pad.rightTrigger.value * 255.0f);
    
    g_gamepad_state->stick[0].x = (int)(pad.leftThumbstick.xAxis.value * 32767.0f);
    g_gamepad_state->stick[0].y = (int)(pad.leftThumbstick.yAxis.value * 32767.0f);
    
    g_gamepad_state->stick[1].x = (int)(pad.rightThumbstick.xAxis.value * 32767.0f);
    g_gamepad_state->stick[1].y = (int)(pad.rightThumbstick.yAxis.value * 32767.0f);
    
    g_gamepad_state->flags |= 1;
    
    update_stick(&g_gamepad_state->stick[0], GAMEPAD_DEADZONE_LEFT_STICK);
    update_stick(&g_gamepad_state->stick[1], GAMEPAD_DEADZONE_RIGHT_STICK);
    update_trigger(&g_gamepad_state->trigger[0]);
    update_trigger(&g_gamepad_state->trigger[1]);
}

int my_gamepad_is_connected(int index) {
    my_gamepad_update();
    if (index == 0 && g_gamepad_state) {
        return (g_gamepad_state->flags & 1) ? 1 : 0;
    }
    return 0;
}

static void queue_connection_callbacks(bool force) {
    if (!g_get_steam_client || !g_addCBResult) return;
    
    void *client = g_get_steam_client();
    if (!client) return;
    void *callbacks = *(void**)((uintptr_t)client + 0x108);
    if (!callbacks) return;
    
    bool is_connected = (g_gamepad_state && (g_gamepad_state->flags & 1));
    
    if (is_connected) {
        if (force || !g_was_connected || (g_initial_sync_frames < 30)) {
            NSLog(@"[gamepad_bridge] Queuing SteamInputDeviceConnected_t (2801) and ConfigurationLoaded (2803) (sync frame %d)...", g_initial_sync_frames);
            uint64_t handle = 1;
            g_addCBResult(callbacks, 2801, &handle, sizeof(handle));
            
            struct {
                uint32_t app;
                uint64_t handle;
                uint64_t creator;
                uint32_t maj, min;
                bool blocks;
            } cfg = { 275850, 1, 0, 1, 0, false };
            g_addCBResult(callbacks, 2803, &cfg, sizeof(cfg));
            
            g_was_connected = true;
            g_initial_sync_frames++;
        }
    } else {
        if (g_was_connected) {
            NSLog(@"[gamepad_bridge] Queuing SteamInputDeviceDisconnected_t (2802)...");
            uint64_t handle = 1;
            g_addCBResult(callbacks, 2802, &handle, sizeof(handle));
            g_was_connected = false;
            g_initial_sync_frames = 0;
        }
    }
}

void my_enable_device_callbacks(void *this) {
    NSLog(@"[gamepad_bridge] SteamInput::EnableDeviceCallbacks() called!");
    g_device_callbacks_enabled = true;
    my_gamepad_update();
    queue_connection_callbacks(true);
}

__attribute__((visibility("default")))
void SteamAPI_RunCallbacks(void) {
    my_gamepad_update();
    queue_connection_callbacks(false);
    
    if (g_pRunCallbacks && g_get_steam_client) {
        void *client = g_get_steam_client();
        if (client) {
            g_pRunCallbacks(client, true, false);
        }
    }
}

__attribute__((visibility("default")))
void SteamAPI_RegisterCallback(void *pCallback, int iCallback) {
    if (g_orig_RegisterCallback) {
        g_orig_RegisterCallback(pCallback, iCallback);
    }
    if (iCallback == 2801 || iCallback == 2803) {
        NSLog(@"[gamepad_bridge] SteamAPI_RegisterCallback registered callback %d", iCallback);
        g_initial_sync_frames = 0;
    }
}

__attribute__((visibility("default")))
bool SteamAPI_Init(void) {
    if (g_app_path[0]) {
        setenv("GseAppPath", g_app_path, 1);
    }
    bool res = g_orig_Init ? g_orig_Init() : false;
    my_gamepad_update();
    return res;
}

static void install_patch(uintptr_t target_addr, void *replacement) {
    uintptr_t page_size = (uintptr_t)getpagesize();
    uintptr_t page = target_addr & ~(page_size - 1);
    
    vm_protect(mach_task_self(), (vm_address_t)page, page_size * 2, FALSE, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    
#if defined(__arm64__)
    uint32_t hook[4];
    hook[0] = 0x58000050; // ldr x16, [pc, #8]
    hook[1] = 0xd61f0200; // br x16
    *(uint64_t*)&hook[2] = (uint64_t)replacement;
    memcpy((void*)target_addr, hook, sizeof(hook));
    sys_icache_invalidate((void*)target_addr, sizeof(hook));
#elif defined(__x86_64__)
    uint8_t hook[12];
    hook[0] = 0x48; hook[1] = 0xb8;
    *(uint64_t*)&hook[2] = (uint64_t)replacement;
    hook[10] = 0xff; hook[11] = 0xe0;
    memcpy((void*)target_addr, hook, sizeof(hook));
#endif

    vm_protect(mach_task_self(), (vm_address_t)page, page_size * 2, FALSE, VM_PROT_READ | VM_PROT_EXECUTE);
}

__attribute__((constructor))
static void bridge_init(void) {
    uint32_t count = _dyld_image_count();
    uintptr_t emu_base = 0;
    const char *emu_path = NULL;
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (strstr(name, "libsteam_emu.dylib") || strstr(name, "test_steam.dylib")) {
            emu_base = (uintptr_t)_dyld_get_image_header(i);
            emu_path = name;
            break;
        }
    }
    if (!emu_base) {
        NSLog(@"[gamepad_bridge] Could not find emu dylib base");
        return;
    }
    
    NSLog(@"[gamepad_bridge] Found emu base at 0x%lx from %s", (unsigned long)emu_base, emu_path ?: "unknown");
    
    if (emu_path) {
        strlcpy(g_app_path, emu_path, sizeof(g_app_path));
        char *last_slash = strrchr(g_app_path, '/');
        if (last_slash) {
            *(last_slash + 1) = '\0';
            setenv("GseAppPath", g_app_path, 1);
            NSLog(@"[gamepad_bridge] Dynamically set GseAppPath to: %s", g_app_path);
        }
    }
    
    void *emu_handle = dlopen("libsteam_emu.dylib", RTLD_NOLOAD | RTLD_LAZY);
    if (!emu_handle && emu_path) {
        emu_handle = dlopen(emu_path, RTLD_NOLOAD | RTLD_LAZY);
    }
    if (emu_handle) {
        g_orig_RegisterCallback = (RegisterCallback_t)dlsym(emu_handle, "SteamAPI_RegisterCallback");
        g_orig_Init = (Init_t)dlsym(emu_handle, "SteamAPI_Init");
    }

#if defined(__arm64__)
    g_gamepad_state = (GamepadState *)(emu_base + 0x5b711c);
    g_get_steam_client = (get_steam_client_t)(emu_base + 0x26ca8);
    g_addCBResult = (addCBResult_t)(emu_base + 0x1e800);
    g_pRunCallbacks = (RunCallbacks_t)(emu_base + 0xd59e0);
    
    install_patch(emu_base + 0x43c90, (void*)&my_gamepad_update);
    install_patch(emu_base + 0x43ce8, (void*)&my_gamepad_is_connected);
    NSLog(@"[gamepad_bridge] arm64 hooks installed successfully");

#elif defined(__x86_64__)
    g_gamepad_state = (GamepadState *)(emu_base + 0x5ef170);
    g_get_steam_client = (get_steam_client_t)(emu_base + 0x286e0);
    g_addCBResult = (addCBResult_t)(emu_base + 0x1f920);
    g_pRunCallbacks = (RunCallbacks_t)(emu_base + 0xe8950);
    
    install_patch(emu_base + 0x44f30, (void*)&my_gamepad_update);
    install_patch(emu_base + 0x44fb0, (void*)&my_gamepad_is_connected);
    NSLog(@"[gamepad_bridge] x86_64 hooks installed successfully");
#endif

    [[NSNotificationCenter defaultCenter] addObserverForName:GCControllerDidConnectNotification
                                                      object:nil
                                                       queue:nil
                                                  usingBlock:^(NSNotification *note) {
        GCController *c = (GCController *)note.object;
        NSLog(@"[gamepad_bridge] Gamepad connected: %@", c.vendorName ?: @"Unknown Controller");
        my_gamepad_update();
        g_initial_sync_frames = 0;
        queue_connection_callbacks(true);
    }];
    [[NSNotificationCenter defaultCenter] addObserverForName:GCControllerDidDisconnectNotification
                                                      object:nil
                                                       queue:nil
                                                  usingBlock:^(NSNotification *note) {
        GCController *c = (GCController *)note.object;
        NSLog(@"[gamepad_bridge] Gamepad disconnected: %@", c.vendorName ?: @"Unknown Controller");
        my_gamepad_update();
        queue_connection_callbacks(true);
    }];
    [GCController startWirelessControllerDiscoveryWithCompletionHandler:nil];

    my_gamepad_update();
}
