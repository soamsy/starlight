#[cfg(target_os = "linux")]
pub mod niri;
#[cfg(target_os = "linux")]
pub mod x11;
#[cfg(target_os = "linux")]
pub mod x11_capture;
#[cfg(not(target_os = "linux"))]
pub mod unsupported;

#[cfg(target_os = "linux")]
pub use x11::{forget as forget_window, nested_display_name};
#[cfg(target_os = "linux")]
pub use x11_capture::{get_window_rect, grab_frame, grab_frame_region, grab_regions, is_window_focused, resize_window, save_png, window_details};
#[cfg(not(target_os = "linux"))]
pub use unsupported::{forget as forget_window, get_window_rect, grab_frame, grab_frame_region, grab_regions, is_window_focused, nested_display_name, resize_window, save_png, window_details};
