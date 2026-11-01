#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <windowsx.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define CLASS_NAME "starlight-winprobe"
#define MAX_MOVE_EVENTS 150000
#define FLUSH_TIMER 1
#define DONE_TIMER 2
#define DEFAULT_DURATION_S 60

typedef struct {
    int deviceType;
    int originId;
} MessageSource;

typedef BOOL(WINAPI *GetCurrentInputMessageSourceFn)(MessageSource *);
typedef LONG(WINAPI *RtlGetVersionFn)(OSVERSIONINFOW *);
typedef const char *(CDECL *WineGetVersionFn)(void);
typedef void(CDECL *WineGetHostVersionFn)(const char **, const char **);

static HANDLE out_file = INVALID_HANDLE_VALUE;
static CRITICAL_SECTION lock;
static LARGE_INTEGER qpf, qpc0;
static char pending[1 << 18];
static size_t pending_len;
static long move_events, dropped_moves;
static HWND main_window;
static volatile LONG stop_polling;
static GetCurrentInputMessageSourceFn get_message_source;

static long long now_us(void) {
    LARGE_INTEGER n;
    QueryPerformanceCounter(&n);
    return (n.QuadPart - qpc0.QuadPart) * 1000000LL / qpf.QuadPart;
}

static void flush_locked(void) {
    if (pending_len && out_file != INVALID_HANDLE_VALUE) {
        DWORD written;
        WriteFile(out_file, pending, (DWORD)pending_len, &written, NULL);
    }
    pending_len = 0;
}

static void emit_line(int is_move, const char *kind, const char *fmt, va_list ap) {
    char line[768];
    int n = snprintf(line, sizeof line, "%s t=%lld ", kind, now_us());
    if (n < 0 || n >= (int)sizeof line) return;
    int m = vsnprintf(line + n, sizeof line - n - 1, fmt, ap);
    if (m < 0) return;
    n += m;
    if (n > (int)sizeof line - 2) n = (int)sizeof line - 2;
    line[n++] = '\n';

    EnterCriticalSection(&lock);
    if (is_move && ++move_events > MAX_MOVE_EVENTS) {
        dropped_moves++;
    } else {
        if (pending_len + n > sizeof pending) flush_locked();
        memcpy(pending + pending_len, line, n);
        pending_len += n;
    }
    LeaveCriticalSection(&lock);
}

static void emit(const char *kind, const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    emit_line(0, kind, fmt, ap);
    va_end(ap);
}

static void emit_move(const char *kind, const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    emit_line(1, kind, fmt, ap);
    va_end(ap);
}

static void flush(void) {
    EnterCriticalSection(&lock);
    flush_locked();
    LeaveCriticalSection(&lock);
}

static const char *msg_name(UINT msg) {
    switch (msg) {
    case WM_MOUSEMOVE: return "MOVE";
    case WM_LBUTTONDOWN: return "LDOWN";
    case WM_LBUTTONUP: return "LUP";
    case WM_RBUTTONDOWN: return "RDOWN";
    case WM_RBUTTONUP: return "RUP";
    case WM_MBUTTONDOWN: return "MDOWN";
    case WM_MBUTTONUP: return "MUP";
    case WM_MOUSEWHEEL: return "WHEEL";
    case WM_MOUSEHWHEEL: return "HWHEEL";
    case WM_KEYDOWN: return "KEYDOWN";
    case WM_KEYUP: return "KEYUP";
    case WM_SYSKEYDOWN: return "SYSKEYDOWN";
    case WM_SYSKEYUP: return "SYSKEYUP";
    case WM_CHAR: return "CHAR";
    default: return NULL;
    }
}

static void message_source(int *device, int *origin) {
    MessageSource s;
    *device = -1;
    *origin = -1;
    if (get_message_source && get_message_source(&s)) {
        *device = s.deviceType;
        *origin = s.originId;
    }
}

static LRESULT CALLBACK ll_mouse(int code, WPARAM wp, LPARAM lp) {
    if (code == HC_ACTION) {
        const MSLLHOOKSTRUCT *m = (const MSLLHOOKSTRUCT *)lp;
        const char *name = msg_name((UINT)wp);
        char other[16];
        if (!name) {
            snprintf(other, sizeof other, "OTHER_%x", (unsigned)wp);
            name = other;
        }
        (wp == WM_MOUSEMOVE ? emit_move : emit)("llm", "msg=%s x=%ld y=%ld data=%lu flags=%lu time=%lu tick=%lu extra=%llx",
            name, m->pt.x, m->pt.y, m->mouseData, m->flags, m->time, GetTickCount(), (unsigned long long)m->dwExtraInfo);
    }
    return CallNextHookEx(NULL, code, wp, lp);
}

static LRESULT CALLBACK ll_keyboard(int code, WPARAM wp, LPARAM lp) {
    if (code == HC_ACTION) {
        const KBDLLHOOKSTRUCT *k = (const KBDLLHOOKSTRUCT *)lp;
        const char *name = msg_name((UINT)wp);
        char other[16];
        if (!name) {
            snprintf(other, sizeof other, "OTHER_%x", (unsigned)wp);
            name = other;
        }
        emit("llk", "msg=%s vk=%lu scan=%lu flags=%lu time=%lu tick=%lu extra=%llx",
            name, k->vkCode, k->scanCode, k->flags, k->time, GetTickCount(), (unsigned long long)k->dwExtraInfo);
        if (k->vkCode == VK_ESCAPE && wp == WM_KEYDOWN && main_window) PostMessageA(main_window, WM_CLOSE, 0, 0);
    }
    return CallNextHookEx(NULL, code, wp, lp);
}

static void handle_raw_input(WPARAM wp, LPARAM lp) {
    static BYTE raw[1024] __attribute__((aligned(8)));
    UINT size = sizeof raw;
    UINT got = GetRawInputData((HRAWINPUT)lp, RID_INPUT, raw, &size, sizeof(RAWINPUTHEADER));
    if (got == (UINT)-1 || got == 0) {
        emit("rawerr", "size=%u error=%lu", size, GetLastError());
        return;
    }
    const RAWINPUT *r = (const RAWINPUT *)raw;
    int sink = (int)GET_RAWINPUT_CODE_WPARAM(wp);
    unsigned long long dev = (unsigned long long)(uintptr_t)r->header.hDevice;
    if (r->header.dwType == RIM_TYPEMOUSE) {
        const RAWMOUSE *m = &r->data.mouse;
        emit_move("rawm", "dev=%llx sink=%d flags=%u bflags=%u bdata=%d rawbtn=%lu dx=%ld dy=%ld extra=%lx",
            dev, sink, m->usFlags, m->usButtonFlags, (short)m->usButtonData, m->ulRawButtons, m->lLastX, m->lLastY, m->ulExtraInformation);
    } else if (r->header.dwType == RIM_TYPEKEYBOARD) {
        const RAWKEYBOARD *k = &r->data.keyboard;
        emit("rawk", "dev=%llx sink=%d make=%u flags=%u vk=%u msg=%u extra=%lx",
            dev, sink, k->MakeCode, k->Flags, k->VKey, k->Message, k->ExtraInformation);
    } else {
        emit("rawh", "dev=%llx sink=%d size=%lu", dev, sink, r->header.dwSize);
    }
}

static void handle_window_message(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    const char *name = msg_name(msg);
    if (!name) return;
    int device, origin;
    message_source(&device, &origin);
    (msg == WM_MOUSEMOVE ? emit_move : emit)("wm",
        "msg=%s wp=%llx x=%d y=%d extra=%llx mtime=%ld tick=%lu dev=%d origin=%d fg=%d focus=%d cap=%d",
        name, (unsigned long long)wp, GET_X_LPARAM(lp), GET_Y_LPARAM(lp), (unsigned long long)GetMessageExtraInfo(),
        GetMessageTime(), GetTickCount(), device, origin,
        GetForegroundWindow() == hwnd, GetFocus() == hwnd, GetCapture() == hwnd);
}

static LRESULT CALLBACK wnd_proc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    switch (msg) {
    case WM_INPUT:
        handle_raw_input(wp, lp);
        return DefWindowProcA(hwnd, msg, wp, lp);
    case WM_INPUT_DEVICE_CHANGE:
        emit("rawchg", "event=%s dev=%llx", wp == GIDC_ARRIVAL ? "arrival" : "removal", (unsigned long long)lp);
        return 0;
    case WM_ACTIVATE:
        emit("focus", "event=activate state=%u", LOWORD(wp));
        return 0;
    case WM_SETFOCUS:
        emit("focus", "event=setfocus state=1");
        return 0;
    case WM_KILLFOCUS:
        emit("focus", "event=killfocus state=0");
        return 0;
    case WM_TIMER:
        if (wp == FLUSH_TIMER) flush();
        if (wp == DONE_TIMER) DestroyWindow(hwnd);
        return 0;
    case WM_DESTROY:
        PostQuitMessage(0);
        return 0;
    default:
        handle_window_message(hwnd, msg, wp, lp);
        return DefWindowProcA(hwnd, msg, wp, lp);
    }
}

static DWORD WINAPI poll_thread(LPVOID unused) {
    static const int keys[] = {VK_LBUTTON, VK_RBUTTON, VK_MBUTTON, VK_ESCAPE, 'A', VK_SPACE, VK_RETURN};
    enum { COUNT = sizeof keys / sizeof keys[0] };
    int was_down[COUNT] = {0};
    POINT last = {-99999, -99999};
    (void)unused;

    while (!InterlockedCompareExchange(&stop_polling, 0, 0)) {
        POINT p;
        if (GetCursorPos(&p) && (p.x != last.x || p.y != last.y)) {
            last = p;
            emit_move("pcur", "x=%ld y=%ld", p.x, p.y);
        }
        for (int i = 0; i < COUNT; i++) {
            SHORT s = GetAsyncKeyState(keys[i]);
            int down = (s & 0x8000) != 0;
            int pressed = s & 1;
            if (down != was_down[i] || pressed) emit("pkey", "vk=%d down=%d pressed=%d", keys[i], down, pressed);
            was_down[i] = down;
        }
        Sleep(1);
    }
    return 0;
}

static void emit_environment(void) {
    HMODULE ntdll = GetModuleHandleA("ntdll.dll");
    OSVERSIONINFOW os = {sizeof os};
    RtlGetVersionFn rtl_get_version = ntdll ? (RtlGetVersionFn)(void *)GetProcAddress(ntdll, "RtlGetVersion") : NULL;
    WineGetVersionFn wine_version = ntdll ? (WineGetVersionFn)(void *)GetProcAddress(ntdll, "wine_get_version") : NULL;
    WineGetHostVersionFn wine_host = ntdll ? (WineGetHostVersionFn)(void *)GetProcAddress(ntdll, "wine_get_host_version") : NULL;
    const char *sysname = "none", *release = "none";

    if (rtl_get_version) rtl_get_version(&os);
    if (wine_host) wine_host(&sysname, &release);
    emit("ver", "os=%lu.%lu.%lu wine=%s host=%s host_release=%s message_source_api=%d",
        os.dwMajorVersion, os.dwMinorVersion, os.dwBuildNumber, wine_version ? wine_version() : "none", sysname, release,
        get_message_source != NULL);

    int mouse_params[3] = {0}, mouse_speed = 0;
    SystemParametersInfoA(SPI_GETMOUSE, 0, mouse_params, 0);
    SystemParametersInfoA(SPI_GETMOUSESPEED, 0, &mouse_speed, 0);
    emit("sys",
        "mouse_present=%d mouse_buttons=%d wheel=%d hwheel=%d swap=%d remote=%d digitizer=%d max_touches=%d screen=%dx%d "
        "kbd_type=%d kbd_subtype=%d kbd_fkeys=%d layout=%llx accel_thresholds=%d,%d accel=%d speed=%d",
        GetSystemMetrics(SM_MOUSEPRESENT), GetSystemMetrics(SM_CMOUSEBUTTONS), GetSystemMetrics(SM_MOUSEWHEELPRESENT),
        GetSystemMetrics(91), GetSystemMetrics(SM_SWAPBUTTON), GetSystemMetrics(0x1000), GetSystemMetrics(94),
        GetSystemMetrics(95), GetSystemMetrics(SM_CXSCREEN), GetSystemMetrics(SM_CYSCREEN), GetKeyboardType(0),
        GetKeyboardType(1), GetKeyboardType(2), (unsigned long long)(uintptr_t)GetKeyboardLayout(0), mouse_params[0],
        mouse_params[1], mouse_params[2], mouse_speed);

    static const char *names[] = {"SteamAppId", "SteamGameId", "STEAM_COMPAT_DATA_PATH", "WINEPREFIX", "WINEDLLOVERRIDES",
        "PROTON_VERSION", "XDG_SESSION_TYPE", "WAYLAND_DISPLAY", "DISPLAY", "SDL_VIDEODRIVER", "PROTON_ENABLE_WAYLAND"};
    for (size_t i = 0; i < sizeof names / sizeof names[0]; i++) {
        char value[512];
        DWORD n = GetEnvironmentVariableA(names[i], value, sizeof value);
        if (n > 0 && n < sizeof value) emit("env", "name=%s val=%s", names[i], value);
    }

    UINT count = 0;
    if (GetRawInputDeviceList(NULL, &count, sizeof(RAWINPUTDEVICELIST)) == 0 && count > 0) {
        RAWINPUTDEVICELIST *list = malloc(count * sizeof *list);
        if (list && GetRawInputDeviceList(list, &count, sizeof *list) != (UINT)-1) {
            for (UINT i = 0; i < count; i++) {
                char name[512] = "";
                UINT name_size = sizeof name;
                RID_DEVICE_INFO info = {sizeof info};
                UINT info_size = sizeof info;
                GetRawInputDeviceInfoA(list[i].hDevice, RIDI_DEVICENAME, name, &name_size);
                GetRawInputDeviceInfoA(list[i].hDevice, RIDI_DEVICEINFO, &info, &info_size);
                unsigned long long handle = (unsigned long long)(uintptr_t)list[i].hDevice;
                if (list[i].dwType == RIM_TYPEMOUSE)
                    emit("rawdev", "type=mouse dev=%llx id=%lu buttons=%lu sample_rate=%lu hwheel=%d val=%s", handle,
                        info.mouse.dwId, info.mouse.dwNumberOfButtons, info.mouse.dwSampleRate, info.mouse.fHasHorizontalWheel, name);
                else if (list[i].dwType == RIM_TYPEKEYBOARD)
                    emit("rawdev", "type=keyboard dev=%llx kbd_type=%lu subtype=%lu mode=%lu fkeys=%lu indicators=%lu keys=%lu val=%s",
                        handle, info.keyboard.dwType, info.keyboard.dwSubType, info.keyboard.dwKeyboardMode,
                        info.keyboard.dwNumberOfFunctionKeys, info.keyboard.dwNumberOfIndicators, info.keyboard.dwNumberOfKeysTotal, name);
                else
                    emit("rawdev", "type=hid dev=%llx vid=%lx pid=%lx usage_page=%u usage=%u val=%s", handle,
                        info.hid.dwVendorId, info.hid.dwProductId, info.hid.usUsagePage, info.hid.usUsage, name);
            }
        }
        free(list);
    }
    emit("rawdevs", "count=%u", count);
}

static void emit_window_state(HWND hwnd) {
    RECT window, client;
    POINT origin = {0, 0}, cursor = {0, 0};
    RECT clip = {0, 0, 0, 0};
    LASTINPUTINFO last = {sizeof last};

    GetWindowRect(hwnd, &window);
    GetClientRect(hwnd, &client);
    ClientToScreen(hwnd, &origin);
    GetCursorPos(&cursor);
    GetClipCursor(&clip);
    emit("win", "window=%ld,%ld,%ldx%ld client=%ldx%ld client_origin=%ld,%ld fg=%d focus=%d",
        window.left, window.top, window.right - window.left, window.bottom - window.top, client.right, client.bottom,
        origin.x, origin.y, GetForegroundWindow() == hwnd, GetFocus() == hwnd);
    emit("cursor0", "x=%ld y=%ld clip=%ld,%ld,%ld,%ld", cursor.x, cursor.y, clip.left, clip.top, clip.right, clip.bottom);
    if (GetLastInputInfo(&last)) emit("lastinput", "input_tick=%lu now_tick=%lu", last.dwTime, GetTickCount());
}

static void unix_to_windows_path(const char *in, char *out, size_t size) {
    size_t n = 0;
    if (in[0] == '/' && size > 3) {
        out[n++] = 'Z';
        out[n++] = ':';
    }
    for (; *in && n + 1 < size; in++) out[n++] = *in == '/' ? '\\' : *in;
    out[n] = 0;
}

int WINAPI WinMain(HINSTANCE inst, HINSTANCE prev, LPSTR cmdline, int show) {
    const char *out_path = NULL;
    int duration = DEFAULT_DURATION_S;
    (void)prev;
    (void)cmdline;
    (void)show;

    for (int i = 1; i < __argc; i++) {
        if (strncmp(__argv[i], "--out=", 6) == 0) out_path = __argv[i] + 6;
        else if (strncmp(__argv[i], "--duration=", 11) == 0) duration = atoi(__argv[i] + 11);
    }
    if (!out_path || duration <= 0) return 2;

    InitializeCriticalSection(&lock);
    QueryPerformanceFrequency(&qpf);
    QueryPerformanceCounter(&qpc0);

    char path[1024];
    unix_to_windows_path(out_path, path, sizeof path);
    out_file = CreateFileA(path, GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (out_file == INVALID_HANDLE_VALUE) return 3;

    HMODULE user32 = GetModuleHandleA("user32.dll");
    get_message_source = user32 ? (GetCurrentInputMessageSourceFn)(void *)GetProcAddress(user32, "GetCurrentInputMessageSource") : NULL;
    emit("start", "pid=%lu duration=%d", GetCurrentProcessId(), duration);
    emit_environment();

    WNDCLASSA wc = {0};
    wc.lpfnWndProc = wnd_proc;
    wc.hInstance = inst;
    wc.lpszClassName = CLASS_NAME;
    wc.hCursor = LoadCursorA(NULL, IDC_ARROW);
    wc.hbrBackground = (HBRUSH)GetStockObject(DKGRAY_BRUSH);
    if (!RegisterClassA(&wc)) return 4;

    main_window = CreateWindowExA(0, CLASS_NAME, CLASS_NAME, WS_OVERLAPPEDWINDOW | WS_VISIBLE, 100, 100, 800, 450, NULL, NULL, inst, NULL);
    if (!main_window) return 5;
    SetForegroundWindow(main_window);
    SetFocus(main_window);

    RAWINPUTDEVICE devices[2] = {
        {0x01, 0x02, RIDEV_INPUTSINK | RIDEV_DEVNOTIFY, main_window},
        {0x01, 0x06, RIDEV_INPUTSINK | RIDEV_DEVNOTIFY, main_window},
    };
    BOOL registered = RegisterRawInputDevices(devices, 2, sizeof(RAWINPUTDEVICE));
    emit("rawreg", "ok=%d error=%lu", registered, registered ? 0 : GetLastError());

    HHOOK mouse_hook = SetWindowsHookExA(WH_MOUSE_LL, ll_mouse, inst, 0);
    HHOOK keyboard_hook = SetWindowsHookExA(WH_KEYBOARD_LL, ll_keyboard, inst, 0);
    emit("hooks", "mouse=%d keyboard=%d", mouse_hook != NULL, keyboard_hook != NULL);

    SetTimer(main_window, FLUSH_TIMER, 100, NULL);
    SetTimer(main_window, DONE_TIMER, (UINT)duration * 1000, NULL);
    HANDLE poller = CreateThread(NULL, 0, poll_thread, NULL, 0, NULL);

    emit_window_state(main_window);
    emit("ready", "pid=%lu", GetCurrentProcessId());
    flush();

    MSG msg;
    while (GetMessageA(&msg, NULL, 0, 0) > 0) {
        TranslateMessage(&msg);
        DispatchMessageA(&msg);
    }

    InterlockedExchange(&stop_polling, 1);
    if (poller) {
        WaitForSingleObject(poller, 1000);
        CloseHandle(poller);
    }
    if (mouse_hook) UnhookWindowsHookEx(mouse_hook);
    if (keyboard_hook) UnhookWindowsHookEx(keyboard_hook);

    LASTINPUTINFO last = {sizeof last};
    if (GetLastInputInfo(&last)) emit("lastinput", "input_tick=%lu now_tick=%lu", last.dwTime, GetTickCount());
    emit("done", "dropped_moves=%ld", dropped_moves);
    flush();
    CloseHandle(out_file);
    return 0;
}
