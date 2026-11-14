#[cfg(target_os = "linux")]
pub mod niri;
#[cfg(target_os = "linux")]
pub mod x11;
#[cfg(target_os = "linux")]
pub mod x11_capture;
#[cfg(not(any(target_os = "linux", windows)))]
pub mod unsupported;
#[cfg(windows)]
pub mod windows;

#[cfg(target_os = "linux")]
pub use x11::{forget as forget_window, nested_display_name};
#[cfg(target_os = "linux")]
pub use x11_capture::{get_window_rect, grab_frame, grab_frame_region, grab_regions, is_window_focused, resize_window, save_png, window_details};
#[cfg(not(any(target_os = "linux", windows)))]
pub use unsupported::{forget as forget_window, get_window_rect, grab_frame, grab_frame_region, grab_regions, is_window_focused, nested_display_name, resize_window, save_png, window_details};
#[cfg(windows)]
pub use windows::{forget as forget_window, get_window_rect, grab_frame, grab_frame_region, grab_regions, is_window_focused, resize_window, save_png, system_details, window_details};

#[cfg(not(windows))]
pub fn system_details() -> Result<Vec<String>, crate::error::NativeError> {
    Err(crate::error::NativeError::CaptureFailed("system details are only collected on Windows".into()))
}
