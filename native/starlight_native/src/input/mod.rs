pub mod cursor;
pub mod eis;
pub mod wlr;

use std::sync::atomic::{AtomicBool, Ordering};

use crate::error::NativeError;

static WLR_ACTIVE: AtomicBool = AtomicBool::new(false);

fn use_wlr() -> bool {
    WLR_ACTIVE.load(Ordering::Relaxed) && crate::capture::nested_display_name().is_none()
}

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

pub fn backend() -> &'static str {
    if use_wlr() { "wayland virtual pointer and keyboard" } else { "libei" }
}

pub fn move_absolute(x: f32, y: f32) -> Result<(), NativeError> {
    if use_wlr() { wlr::linux::move_absolute(x, y) } else { eis::linux::move_absolute(x, y) }
}

pub fn move_relative(dx: f32, dy: f32) -> Result<(), NativeError> {
    if use_wlr() { wlr::linux::move_relative(dx, dy) } else { eis::linux::move_relative(dx, dy) }
}

pub fn button_event(code: u32, pressed: bool) -> Result<(), NativeError> {
    if use_wlr() { wlr::linux::button_event(code, pressed) } else { eis::linux::button_event(code, pressed) }
}

pub fn key_event(keycode: u32, pressed: bool) -> Result<(), NativeError> {
    if use_wlr() { wlr::linux::key_event(keycode, pressed) } else { eis::linux::key_event(keycode, pressed) }
}

pub fn scroll(dx: i32, dy: i32) -> Result<(), NativeError> {
    if use_wlr() { wlr::linux::scroll(dx, dy) } else { eis::linux::scroll(dx, dy) }
}

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

#[cfg(not(target_os = "linux"))]
pub fn get_cursor_pos() -> Result<(i32, i32), NativeError> {
    cursor::linux::get_cursor_pos()
}
