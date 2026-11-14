use std::ops::DerefMut;

use crate::error::NativeError;

fn unsupported<T>() -> Result<T, NativeError> {
    Err(NativeError::CaptureFailed("window capture is not available on this platform".into()))
}

pub fn forget() {}

pub fn nested_display_name() -> Option<String> {
    None
}

pub fn get_window_rect(_class_name: &str) -> Result<(i32, i32, u32, u32), NativeError> {
    Err(NativeError::WindowNotFound)
}

pub fn resize_window(_class_name: &str, _width: u32, _height: u32) -> Result<(), NativeError> {
    Err(NativeError::WindowNotFound)
}

pub fn window_details(_class_name: &str) -> Result<Vec<String>, NativeError> {
    Err(NativeError::WindowNotFound)
}

pub fn is_window_focused(_class_name: &str) -> Result<bool, NativeError> {
    Err(NativeError::WindowNotFound)
}

pub fn grab_frame<B: DerefMut<Target = [u8]>>(
    _window_title: &str,
    _alloc: impl FnMut(usize) -> B,
) -> Result<(B, u32, u32), NativeError> {
    unsupported()
}

pub fn grab_frame_region<B: DerefMut<Target = [u8]>>(
    _window_title: &str,
    _area: (u32, u32, u32, u32),
    _alloc: impl FnMut(usize) -> B,
) -> Result<(B, u32, u32), NativeError> {
    unsupported()
}

pub fn grab_regions<B: DerefMut<Target = [u8]>>(
    _window_title: &str,
    _rects: &[(u32, u32, u32, u32)],
    _alloc: impl FnMut(usize) -> B,
) -> Result<Vec<B>, NativeError> {
    unsupported()
}

pub fn save_png(_bgr: &[u8], _width: u32, _height: u32, _path: &str) -> Result<(), NativeError> {
    unsupported()
}
