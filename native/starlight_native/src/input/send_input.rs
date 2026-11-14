use std::sync::atomic::{AtomicBool, Ordering};

use windows_sys::Win32::Foundation::{GetLastError, HWND, POINT};
use windows_sys::Win32::UI::Input::KeyboardAndMouse::{
    SendInput, INPUT, INPUT_0, INPUT_KEYBOARD, INPUT_MOUSE, KEYBDINPUT, KEYEVENTF_KEYUP, KEYEVENTF_SCANCODE, MOUSEEVENTF_ABSOLUTE,
    MOUSEEVENTF_HWHEEL, MOUSEEVENTF_LEFTDOWN, MOUSEEVENTF_LEFTUP, MOUSEEVENTF_MIDDLEDOWN, MOUSEEVENTF_MIDDLEUP, MOUSEEVENTF_MOVE,
    MOUSEEVENTF_RIGHTDOWN, MOUSEEVENTF_RIGHTUP, MOUSEEVENTF_VIRTUALDESK, MOUSEEVENTF_WHEEL, MOUSEINPUT,
};
use windows_sys::Win32::UI::WindowsAndMessaging::{
    GetAncestor, GetCursorPos, GetForegroundWindow, GetSystemMetrics, WindowFromPoint, GA_ROOT, SM_CXVIRTUALSCREEN,
    SM_CYVIRTUALSCREEN, SM_XVIRTUALSCREEN, SM_YVIRTUALSCREEN,
};

use crate::capture::windows as win;
use crate::error::NativeError;

const PROBE_TITLE: &str = "starlight-winprobe";
const PROBE_CLASS: &str = "starlight-winprobe";
const PROBE_EXE: &str = "winprobe.exe";
const GAME_EXE: &str = "limbuscompany.exe";
const BTN_LEFT: u32 = 0x110;
const BTN_RIGHT: u32 = 0x111;
const BTN_MIDDLE: u32 = 0x112;
const MAX_SCANCODE: u32 = 88;
const MAX_POINTER_GAIN: i32 = 4;

static READY: AtomicBool = AtomicBool::new(false);

fn refuse(reason: impl Into<String>) -> NativeError {
    NativeError::InputRefused(reason.into())
}

pub fn backend() -> &'static str {
    "SendInput, restricted to the starlight-winprobe test window"
}

pub fn init_input(window_title: &str, _token_path: &str) -> Result<(), NativeError> {
    READY.store(false, Ordering::SeqCst);
    if window_title != PROBE_TITLE {
        return Err(refuse(format!("SendInput only drives the {PROBE_TITLE} test window, never {window_title:?}")));
    }
    probe_window()?;
    READY.store(true, Ordering::SeqCst);
    Ok(())
}

fn probe_window() -> Result<HWND, NativeError> {
    let hwnd = win::find_exact(PROBE_CLASS, PROBE_TITLE).ok_or_else(|| refuse("the starlight-winprobe test window is not open"))?;
    match win::exe_file_name(hwnd) {
        Some(name) if name == PROBE_EXE => Ok(hwnd),
        Some(name) => Err(refuse(format!("the starlight-winprobe window belongs to {name}, not {PROBE_EXE}"))),
        None => Err(refuse("could not read which program owns the starlight-winprobe window")),
    }
}

fn is_game(hwnd: HWND) -> bool {
    !hwnd.is_null() && win::exe_file_name(hwnd).is_none_or(|name| name == GAME_EXE)
}

fn guard_common() -> Result<HWND, NativeError> {
    if !READY.load(Ordering::SeqCst) {
        return Err(NativeError::NotInitialized);
    }
    let foreground = unsafe { GetForegroundWindow() };
    if is_game(foreground) {
        return Err(refuse("the foreground window is Limbus Company or cannot be identified"));
    }
    probe_window()
}

fn guard_pointer(point: POINT) -> Result<(), NativeError> {
    let probe = guard_common()?;
    let (x, y, w, h) = win::client_rect(probe)?;
    let inside = point.x >= x && point.y >= y && point.x < x + w as i32 && point.y < y + h as i32;
    if !inside {
        return Err(refuse(format!("{},{} is outside the test window's client area", point.x, point.y)));
    }
    let under = unsafe { GetAncestor(WindowFromPoint(point), GA_ROOT) };
    if under != probe {
        let owner = win::exe_file_name(under).unwrap_or_else(|| "an unknown program".into());
        return Err(refuse(format!("{},{} is covered by a window of {owner}", point.x, point.y)));
    }
    Ok(())
}

fn guard_keyboard() -> Result<(), NativeError> {
    let probe = guard_common()?;
    if unsafe { GetForegroundWindow() } != probe {
        return Err(refuse("keys go to the foreground window, and that is not the test window"));
    }
    Ok(())
}

fn cursor() -> Result<POINT, NativeError> {
    win::ensure_dpi_aware();
    let mut point = POINT { x: 0, y: 0 };
    if unsafe { GetCursorPos(&mut point) } == 0 {
        return Err(NativeError::CursorQueryFailed(format!("GetCursorPos error {}", unsafe { GetLastError() })));
    }
    Ok(point)
}

fn send(input: INPUT) -> Result<(), NativeError> {
    let sent = unsafe { SendInput(1, &input, std::mem::size_of::<INPUT>() as i32) };
    if sent == 1 {
        Ok(())
    } else {
        Err(NativeError::InputFailed(format!("error {}", unsafe { GetLastError() })))
    }
}

fn mouse(dx: i32, dy: i32, data: i32, flags: u32) -> INPUT {
    INPUT {
        r#type: INPUT_MOUSE,
        Anonymous: INPUT_0 { mi: MOUSEINPUT { dx, dy, mouseData: data as _, dwFlags: flags, time: 0, dwExtraInfo: 0 } },
    }
}

fn key(scan: u16, flags: u32) -> INPUT {
    INPUT {
        r#type: INPUT_KEYBOARD,
        Anonymous: INPUT_0 { ki: KEYBDINPUT { wVk: 0, wScan: scan, dwFlags: flags, time: 0, dwExtraInfo: 0 } },
    }
}

pub fn move_absolute(x: f32, y: f32) -> Result<(), NativeError> {
    win::ensure_dpi_aware();
    let target = POINT { x: x.round() as i32, y: y.round() as i32 };
    guard_pointer(target)?;
    let (vx, vy, vw, vh) = unsafe {
        (
            GetSystemMetrics(SM_XVIRTUALSCREEN),
            GetSystemMetrics(SM_YVIRTUALSCREEN),
            GetSystemMetrics(SM_CXVIRTUALSCREEN).max(2),
            GetSystemMetrics(SM_CYVIRTUALSCREEN).max(2),
        )
    };
    let nx = ((target.x - vx) as i64 * 65535 / (vw - 1) as i64) as i32;
    let ny = ((target.y - vy) as i64 * 65535 / (vh - 1) as i64) as i32;
    send(mouse(nx, ny, 0, MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK))
}

pub fn move_relative(dx: f32, dy: f32) -> Result<(), NativeError> {
    let (dx, dy) = (dx.round() as i32, dy.round() as i32);
    let from = cursor()?;
    guard_pointer(POINT { x: from.x + dx, y: from.y + dy })?;
    guard_pointer(POINT { x: from.x + dx * MAX_POINTER_GAIN, y: from.y + dy * MAX_POINTER_GAIN })?;
    send(mouse(dx, dy, 0, MOUSEEVENTF_MOVE))
}

pub fn button_event(code: u32, pressed: bool) -> Result<(), NativeError> {
    let flags = match (code, pressed) {
        (BTN_LEFT, true) => MOUSEEVENTF_LEFTDOWN,
        (BTN_LEFT, false) => MOUSEEVENTF_LEFTUP,
        (BTN_RIGHT, true) => MOUSEEVENTF_RIGHTDOWN,
        (BTN_RIGHT, false) => MOUSEEVENTF_RIGHTUP,
        (BTN_MIDDLE, true) => MOUSEEVENTF_MIDDLEDOWN,
        (BTN_MIDDLE, false) => MOUSEEVENTF_MIDDLEUP,
        _ => return Err(NativeError::InputFailed(format!("button code {code:#x} has no SendInput mapping"))),
    };
    guard_pointer(cursor()?)?;
    send(mouse(0, 0, 0, flags))
}

pub fn key_event(keycode: u32, pressed: bool) -> Result<(), NativeError> {
    if keycode == 0 || keycode > MAX_SCANCODE {
        return Err(NativeError::InputFailed(format!("key code {keycode} has no scancode mapping")));
    }
    guard_keyboard()?;
    let flags = KEYEVENTF_SCANCODE | if pressed { 0 } else { KEYEVENTF_KEYUP };
    send(key(keycode as u16, flags))
}

pub fn scroll(dx: i32, dy: i32) -> Result<(), NativeError> {
    guard_pointer(cursor()?)?;
    if dy != 0 {
        send(mouse(0, 0, -dy, MOUSEEVENTF_WHEEL))?;
    }
    if dx != 0 {
        send(mouse(0, 0, dx, MOUSEEVENTF_HWHEEL))?;
    }
    Ok(())
}

pub fn release_all(held_keys: &[u32]) -> Result<(), NativeError> {
    for &code in held_keys {
        key_event(code, false)?;
    }
    for code in [BTN_LEFT, BTN_RIGHT, BTN_MIDDLE] {
        button_event(code, false)?;
    }
    Ok(())
}

pub fn get_cursor_pos() -> Result<(i32, i32), NativeError> {
    let point = cursor()?;
    Ok((point.x, point.y))
}
