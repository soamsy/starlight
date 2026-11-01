pub mod niri;
pub mod x11;
pub mod x11_capture;

pub use x11::{forget as forget_window, nested_display_name};
pub use x11_capture::{get_window_rect, grab_frame, grab_frame_region, grab_regions, is_window_focused, resize_window, save_png, window_details};
