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

typedef struct {
    bool bState;
    bool bActive;
} ControllerDigitalActionData_t;

static GamepadState *g_gamepad_state = NULL;

typedef void* (*get_steam_client_t)(void);
typedef void (*addCBResult_t)(void *this, int iCallback, void *pubParam, uint32_t cubParam);
typedef void (*RunCallbacks_t)(void *this, bool b1, bool b2);
typedef void (*RegisterCallback_t)(void *pCallback, int iCallback);
typedef bool (*Init_t)(void);

typedef void (*ActivateActionSet_t)(void *this, uint64_t controllerHandle, uint64_t actionSetHandle);
typedef uint64_t (*GetActionSetHandle_t)(void *this, const char *pszActionSetName);
typedef uint64_t (*GetDigitalActionHandle_t)(void *this, const char *pszActionName);
typedef int (*GetDigitalActionOrigins_t)(void *this, uint64_t controllerHandle, uint64_t actionSetHandle, uint64_t digitalActionHandle, int *originsOut);
typedef ControllerDigitalActionData_t (*GetDigitalActionData_t)(void *this, uint64_t controllerHandle, uint64_t digitalActionHandle);

static get_steam_client_t g_get_steam_client = NULL;
static addCBResult_t g_addCBResult = NULL;
static RunCallbacks_t g_pRunCallbacks = NULL;
static RegisterCallback_t g_orig_RegisterCallback = NULL;
static Init_t g_orig_Init = NULL;

static ActivateActionSet_t g_orig_ActivateActionSet = NULL;
static GetActionSetHandle_t g_orig_GetActionSetHandle = NULL;
static GetDigitalActionHandle_t g_orig_GetDigitalActionHandle = NULL;
static GetDigitalActionOrigins_t g_orig_GetDigitalActionOrigins = NULL;
static GetDigitalActionData_t g_orig_GetDigitalActionData = NULL;

static bool g_was_connected = false;
static int g_initial_sync_frames = 0;
static bool g_device_callbacks_enabled = false;
static char g_app_path[PATH_MAX] = {0};

#define MAX_ACTIVE_LAYERS 16
static uint64_t s_active_layers[MAX_ACTIVE_LAYERS];
static int s_num_active_layers = 0;

static void install_vtable_hooks(void);

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

static bool is_origin_pressed(int origin) {
    if (!g_gamepad_state) return false;
    int b = g_gamepad_state->bCurrent;
    switch (origin) {
        // Button A / Cross / Bottom Face
        case 153: case 72: case 117:
            return (b & (1 << 12)) != 0;
        // Button B / Circle / Right Face
        case 154: case 73: case 118:
            return (b & (1 << 13)) != 0;
        // Button X / Square / Left Face
        case 155: case 74: case 119:
            return (b & (1 << 14)) != 0;
        // Button Y / Triangle / Top Face
        case 156: case 75: case 120:
            return (b & (1 << 15)) != 0;
        // Left Bumper / L1 / L
        case 157: case 76: case 121:
            return (b & (1 << 8)) != 0;
        // Right Bumper / R1 / R
        case 158: case 77: case 122:
            return (b & (1 << 9)) != 0;
        // Start / Options / Plus
        case 159: case 80: case 125:
            return (b & (1 << 4)) != 0;
        // Back / Share / Minus
        case 160: case 81: case 126:
            return (b & (1 << 5)) != 0;
        // Left Trigger / L2 / ZL (Steam origin 161, Goldberg origin 162, PS 78, Switch 123)
        case 161: case 162: case 78: case 123:
            return g_gamepad_state->trigger[0].pressedCurrent != 0;
        // Right Trigger / R2 / ZR (Steam origin 162/163, Goldberg origin 164, PS 79, Switch 124)
        case 163: case 164: case 79: case 124:
            return g_gamepad_state->trigger[1].pressedCurrent != 0;
        // Left Stick Click / L3
        case 166: case 82: case 127:
            return (b & (1 << 6)) != 0;
        // Right Stick Click / R3
        case 172: case 83: case 128:
            return (b & (1 << 7)) != 0;
        // D-Pad Up
        case 177: case 88: case 133:
            return (b & (1 << 0)) != 0;
        // D-Pad Down
        case 178: case 89: case 134:
            return (b & (1 << 1)) != 0;
        // D-Pad Left
        case 179: case 90: case 135:
            return (b & (1 << 2)) != 0;
        // D-Pad Right
        case 180: case 91: case 136:
            return (b & (1 << 3)) != 0;
        default:
            return false;
    }
}

static void my_ActivateActionSetLayer(void *this_iface, uint64_t controllerHandle, uint64_t layerHandle) {
    if (!layerHandle) return;
    for (int i = 0; i < s_num_active_layers; i++) {
        if (s_active_layers[i] == layerHandle) return;
    }
    if (s_num_active_layers < MAX_ACTIVE_LAYERS) {
        s_active_layers[s_num_active_layers++] = layerHandle;
        NSLog(@"[gamepad_bridge] ActivateActionSetLayer: controller=%llu, layer=%llu (active count: %d)",
              controllerHandle, layerHandle, s_num_active_layers);
    }
}

static void my_DeactivateActionSetLayer(void *this_iface, uint64_t controllerHandle, uint64_t layerHandle) {
    for (int i = 0; i < s_num_active_layers; i++) {
        if (s_active_layers[i] == layerHandle) {
            for (int j = i; j < s_num_active_layers - 1; j++) {
                s_active_layers[j] = s_active_layers[j + 1];
            }
            s_num_active_layers--;
            NSLog(@"[gamepad_bridge] DeactivateActionSetLayer: controller=%llu, layer=%llu (remaining: %d)",
                  controllerHandle, layerHandle, s_num_active_layers);
            break;
        }
    }
}

static void my_DeactivateAllActionSetLayers(void *this_iface, uint64_t controllerHandle) {
    s_num_active_layers = 0;
    NSLog(@"[gamepad_bridge] DeactivateAllActionSetLayers: controller=%llu", controllerHandle);
}

static int my_GetActiveActionSetLayers(void *this_iface, uint64_t controllerHandle, uint64_t *handlesOut) {
    if (handlesOut) {
        for (int i = 0; i < s_num_active_layers; i++) {
            handlesOut[i] = s_active_layers[i];
        }
    }
    return s_num_active_layers;
}

static void my_ActivateActionSet(void *this_iface, uint64_t controllerHandle, uint64_t actionSetHandle) {
    s_num_active_layers = 0;
    void *client = g_get_steam_client ? g_get_steam_client() : NULL;
    void *controller = client ? *(void **)((uintptr_t)client + 0x190) : NULL;
    if (g_orig_ActivateActionSet && controller) {
        g_orig_ActivateActionSet(controller, controllerHandle, actionSetHandle);
    }
}

static uint64_t my_GetActionSetHandle(void *this_iface, const char *pszActionSetName) {
    if (!pszActionSetName) return 0;
    void *client = g_get_steam_client ? g_get_steam_client() : NULL;
    void *controller = client ? *(void **)((uintptr_t)client + 0x190) : NULL;
    if (!g_orig_GetActionSetHandle || !controller) return 0;
    
    const char *name = pszActionSetName;
    if (strncmp(name, "/actions/", 9) == 0) {
        name += 9;
    }
    uint64_t h = g_orig_GetActionSetHandle(controller, name);
    if (h == 0 && name != pszActionSetName) {
        h = g_orig_GetActionSetHandle(controller, pszActionSetName);
    }
    return h;
}

static uint64_t my_GetDigitalActionHandle(void *this_iface, const char *pszActionName) {
    if (!pszActionName) return 0;
    void *client = g_get_steam_client ? g_get_steam_client() : NULL;
    void *controller = client ? *(void **)((uintptr_t)client + 0x190) : NULL;
    if (!g_orig_GetDigitalActionHandle || !controller) return 0;
    
    const char *name = pszActionName;
    const char *slash = strrchr(name, '/');
    if (slash) {
        name = slash + 1;
    }
    uint64_t h = g_orig_GetDigitalActionHandle(controller, name);
    if (h == 0 && name != pszActionName) {
        h = g_orig_GetDigitalActionHandle(controller, pszActionName);
    }
    return h;
}

static ControllerDigitalActionData_t my_GetDigitalActionData(void *this_iface, uint64_t controllerHandle, uint64_t digitalActionHandle) {
    my_gamepad_update();
    
    void *client = g_get_steam_client ? g_get_steam_client() : NULL;
    void *controller = client ? *(void **)((uintptr_t)client + 0x190) : NULL;
    
    if (controller && g_orig_GetDigitalActionOrigins && s_num_active_layers > 0) {
        for (int l = s_num_active_layers - 1; l >= 0; l--) {
            uint64_t layer = s_active_layers[l];
            int origins[8] = {0};
            int count = g_orig_GetDigitalActionOrigins(controller, controllerHandle, layer, digitalActionHandle, origins);
            if (count > 0) {
                bool pressed = false;
                for (int i = 0; i < count; i++) {
                    if (is_origin_pressed(origins[i])) {
                        pressed = true;
                        break;
                    }
                }
                ControllerDigitalActionData_t res = { .bState = pressed, .bActive = true };
                return res;
            }
        }
    }
    
    if (g_orig_GetDigitalActionData && controller) {
        return g_orig_GetDigitalActionData(controller, controllerHandle, digitalActionHandle);
    }
    
    ControllerDigitalActionData_t empty = { false, false };
    return empty;
}

static void install_vtable_hooks(void) {
    static bool installed = false;
    if (installed) return;
    
    if (!g_get_steam_client) return;
    void *client = g_get_steam_client();
    if (!client) return;
    void *controller = *(void **)((uintptr_t)client + 0x190);
    if (!controller) return;
    
    uintptr_t page_size = (uintptr_t)getpagesize();
    
    // SteamInput interfaces: 0x48 (SteamInput005), 0x50 (SteamInput006), 0x58 (SteamInput007)
    int iface_offsets[] = { 0x48, 0x50, 0x58 };
    for (int idx = 0; idx < (int)(sizeof(iface_offsets) / sizeof(iface_offsets[0])); idx++) {
        void *pIface = (void *)((uintptr_t)controller + iface_offsets[idx]);
        uintptr_t *vtable = *(uintptr_t **)pIface;
        if (!vtable) continue;
        
        uintptr_t page = ((uintptr_t)vtable) & ~(page_size - 1);
        vm_protect(mach_task_self(), (vm_address_t)page, page_size * 2, FALSE, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
        
        vtable[9]  = (uintptr_t)&my_GetActionSetHandle;
        vtable[10] = (uintptr_t)&my_ActivateActionSet;
        vtable[12] = (uintptr_t)&my_ActivateActionSetLayer;
        vtable[13] = (uintptr_t)&my_DeactivateActionSetLayer;
        vtable[14] = (uintptr_t)&my_DeactivateAllActionSetLayers;
        vtable[15] = (uintptr_t)&my_GetActiveActionSetLayers;
        vtable[16] = (uintptr_t)&my_GetDigitalActionHandle;
        vtable[17] = (uintptr_t)&my_GetDigitalActionData;
        
        vm_protect(mach_task_self(), (vm_address_t)page, page_size * 2, FALSE, VM_PROT_READ | VM_PROT_EXECUTE);
    }
    
    installed = true;
    NSLog(@"[gamepad_bridge] Successfully installed Action Set Layer hooks into ISteamInput vtables!");
}

void my_enable_device_callbacks(void *this) {
    NSLog(@"[gamepad_bridge] SteamInput::EnableDeviceCallbacks() called!");
    g_device_callbacks_enabled = true;
    my_gamepad_update();
    queue_connection_callbacks(true);
}

__attribute__((visibility("default")))
void SteamAPI_RunCallbacks(void) {
    install_vtable_hooks();
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
    install_vtable_hooks();
    my_gamepad_update();
    return res;
}

// Flat C API export overrides for compatibility
__attribute__((visibility("default")))
void SteamAPI_ISteamInput_ActivateActionSetLayer(void *this, uint64_t controllerHandle, uint64_t actionSetLayerHandle) {
    my_ActivateActionSetLayer(this, controllerHandle, actionSetLayerHandle);
}

__attribute__((visibility("default")))
void SteamAPI_ISteamInput_DeactivateActionSetLayer(void *this, uint64_t controllerHandle, uint64_t actionSetLayerHandle) {
    my_DeactivateActionSetLayer(this, controllerHandle, actionSetLayerHandle);
}

__attribute__((visibility("default")))
void SteamAPI_ISteamInput_DeactivateAllActionSetLayers(void *this, uint64_t controllerHandle) {
    my_DeactivateAllActionSetLayers(this, controllerHandle);
}

__attribute__((visibility("default")))
int SteamAPI_ISteamInput_GetActiveActionSetLayers(void *this, uint64_t controllerHandle, uint64_t *handlesOut) {
    return my_GetActiveActionSetLayers(this, controllerHandle, handlesOut);
}

__attribute__((visibility("default")))
ControllerDigitalActionData_t SteamAPI_ISteamInput_GetDigitalActionData(void *this, uint64_t controllerHandle, uint64_t digitalActionHandle) {
    return my_GetDigitalActionData(this, controllerHandle, digitalActionHandle);
}

__attribute__((visibility("default")))
void SteamAPI_ISteamInput_ActivateActionSet(void *this, uint64_t controllerHandle, uint64_t actionSetHandle) {
    my_ActivateActionSet(this, controllerHandle, actionSetHandle);
}

__attribute__((visibility("default")))
uint64_t SteamAPI_ISteamInput_GetActionSetHandle(void *this, const char *pszActionSetName) {
    return my_GetActionSetHandle(this, pszActionSetName);
}

__attribute__((visibility("default")))
uint64_t SteamAPI_ISteamInput_GetDigitalActionHandle(void *this, const char *pszActionName) {
    return my_GetDigitalActionHandle(this, pszActionName);
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
            char check_path[PATH_MAX];
            snprintf(check_path, sizeof(check_path), "%ssteam_settings", g_app_path);
            if (access(check_path, F_OK) != 0) {
                snprintf(check_path, sizeof(check_path), "%s../Resources/steam_settings", g_app_path);
                if (access(check_path, F_OK) == 0) {
                    snprintf(check_path, sizeof(check_path), "%s../Resources/", g_app_path);
                    strlcpy(g_app_path, check_path, sizeof(g_app_path));
                } else {
                    snprintf(check_path, sizeof(check_path), "%s../steam_settings", g_app_path);
                    if (access(check_path, F_OK) == 0) {
                        snprintf(check_path, sizeof(check_path), "%s../", g_app_path);
                        strlcpy(g_app_path, check_path, sizeof(g_app_path));
                    }
                }
            }
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
    
    g_orig_ActivateActionSet = (ActivateActionSet_t)(emu_base + 0x0df8d8);
    g_orig_GetActionSetHandle = (GetActionSetHandle_t)(emu_base + 0x0df720);
    g_orig_GetDigitalActionHandle = (GetDigitalActionHandle_t)(emu_base + 0x0dff3c);
    g_orig_GetDigitalActionOrigins = (GetDigitalActionOrigins_t)(emu_base + 0x0e0d78);
    g_orig_GetDigitalActionData = (GetDigitalActionData_t)(emu_base + 0x0e0110);
    
    install_patch(emu_base + 0x43c90, (void*)&my_gamepad_update);
    install_patch(emu_base + 0x43ce8, (void*)&my_gamepad_is_connected);
    NSLog(@"[gamepad_bridge] arm64 hooks installed successfully");

#elif defined(__x86_64__)
    g_gamepad_state = (GamepadState *)(emu_base + 0x5ef170);
    g_get_steam_client = (get_steam_client_t)(emu_base + 0x286e0);
    g_addCBResult = (addCBResult_t)(emu_base + 0x1f920);
    g_pRunCallbacks = (RunCallbacks_t)(emu_base + 0xe8950);
    
    g_orig_ActivateActionSet = (ActivateActionSet_t)(emu_base + 0x0f43c0);
    g_orig_GetActionSetHandle = (GetActionSetHandle_t)(emu_base + 0x0f41b0);
    g_orig_GetDigitalActionHandle = (GetDigitalActionHandle_t)(emu_base + 0x0f4c50);
    g_orig_GetDigitalActionOrigins = (GetDigitalActionOrigins_t)(emu_base + 0x0f57c0);
    g_orig_GetDigitalActionData = (GetDigitalActionData_t)(emu_base + 0x0f4e80);
    
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
