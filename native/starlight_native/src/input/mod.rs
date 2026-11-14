#[cfg(not(windows))]
pub mod cursor;
#[cfg(not(windows))]
pub mod eis;
#[cfg(windows)]
mod send_input;
#[cfg(not(windows))]
pub mod wlr;

#[cfg(windows)]
pub use send_input::{backend, button_event, get_cursor_pos, init_input, key_event, move_absolute, move_relative, release_all, scroll};

#[cfg(not(windows))]
use std::sync::atomic::{AtomicBool, Ordering};

#[cfg(not(windows))]
use crate::error::NativeError;

#[cfg(not(windows))]
static WLR_ACTIVE: AtomicBool = AtomicBool::new(false);

#[cfg(not(windows))]
fn use_wlr() -> bool {
    WLR_ACTIVE.load(Ordering::Relaxed) && crate::capture::nested_display_name().is_none()
}

#[cfg(not(windows))]
pub fn init_input(window_title: &str, token_path: &str) -> Result<(), NativeError> {
    match eis::linux::init_input(window_title, token_path) {
        Ok(()) => {
            WLR_ACTIVE.store(false, Ordering::Relaxed);
            Ok(())
        }
        Err(eis_error) if crate::capture::nested_display_name().is_none() => {
            crate::elog_warn!("[input] libei unavailable ({eis_error}), trying the Wayland virtual pointer and keyboard");
            match wlr::linux::init() {
                Ok(()) => {
                    WLR_ACTIVE.store(true, Ordering::Relaxed);
                    Ok(())
                }
                Err(wlr_error) => {
                    crate::elog_warn!("[input] virtual pointer and keyboard unavailable too: {wlr_error}");
                    Err(eis_error)
                }
            }
        }
        Err(eis_error) => Err(eis_error),
    }
}

#[cfg(not(windows))]
pub fn backend() -> &'static str {
    if use_wlr() { "wayland virtual pointer and keyboard" } else { "libei" }
}

#[cfg(not(windows))]
pub fn move_absolute(x: f32, y: f32) -> Result<(), NativeError> {
    if use_wlr() { wlr::linux::move_absolute(x, y) } else { eis::linux::move_absolute(x, y) }
}

#[cfg(not(windows))]
pub fn move_relative(dx: f32, dy: f32) -> Result<(), NativeError> {
    if use_wlr() { wlr::linux::move_relative(dx, dy) } else { eis::linux::move_relative(dx, dy) }
}

#[cfg(not(windows))]
pub fn button_event(code: u32, pressed: bool) -> Result<(), NativeError> {
    if use_wlr() { wlr::linux::button_event(code, pressed) } else { eis::linux::button_event(code, pressed) }
}

#[cfg(not(windows))]
pub fn key_event(keycode: u32, pressed: bool) -> Result<(), NativeError> {
    if use_wlr() { wlr::linux::key_event(keycode, pressed) } else { eis::linux::key_event(keycode, pressed) }
}

#[cfg(not(windows))]
pub fn scroll(dx: i32, dy: i32) -> Result<(), NativeError> {
    if use_wlr() { wlr::linux::scroll(dx, dy) } else { eis::linux::scroll(dx, dy) }
}

#[cfg(not(windows))]
pub fn release_all(held_keys: &[u32]) -> Result<(), NativeError> {
    if use_wlr() { wlr::linux::release_all(held_keys) } else { eis::linux::release_all(held_keys) }
}

#[cfg(target_os = "linux")]
pub fn get_cursor_pos() -> Result<(i32, i32), NativeError> {
    match crate::capture::nested_display_name() {
        Some(display) => crate::capture::x11::query_pointer(&display),
        None => cursor::linux::get_cursor_pos(),
    }
}

#[cfg(not(any(target_os = "linux", windows)))]
pub fn get_cursor_pos() -> Result<(i32, i32), NativeError> {
    cursor::linux::get_cursor_pos()
}
