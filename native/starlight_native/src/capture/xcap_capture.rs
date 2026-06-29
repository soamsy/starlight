use image::{ImageBuffer, Rgb, Rgba};
use xcap::Window;
use crate::error::NativeError;
use crate::scale;

fn find_window_by_class(class_name: &str) -> Result<Window, NativeError> {
    let name_lower = class_name.to_lowercase();
    let windows = Window::all().map_err(|e| NativeError::CaptureFailed(e.to_string()))?;

    windows
        .into_iter()
        .find(|w| {
            w.app_name()
                .ok()
                .is_some_and(|a| a.to_lowercase() == name_lower)
                || w.title()
                    .ok()
                    .is_some_and(|t| t.to_lowercase().contains(&name_lower))
        })
        .ok_or(NativeError::WindowNotFound)
}

pub fn get_window_rect(class_name: &str) -> Result<(i32, i32, u32, u32), NativeError> {
    let window = find_window_by_class(class_name)?;

    let x = window.x().map_err(|e| NativeError::CaptureFailed(e.to_string()))?;
    let y = window.y().map_err(|e| NativeError::CaptureFailed(e.to_string()))?;
    let w = window.width().map_err(|e| NativeError::CaptureFailed(e.to_string()))?;
    let h = window.height().map_err(|e| NativeError::CaptureFailed(e.to_string()))?;

    Ok((x, y, w, h))
}

/// Whether the window has OS input focus right now — reads `_NET_ACTIVE_WINDOW`
/// off the X11 root window and compares ids (xcap 0.9.6's `Window::is_focused`),
/// one XCB round trip, same cost class as `get_window_rect`. Not cached: callers
/// gating input injection need this fresh at the moment of the check, not
/// whatever it was as of some earlier poll.
pub fn is_window_focused(class_name: &str) -> Result<bool, NativeError> {
    let window = find_window_by_class(class_name)?;
    window.is_focused().map_err(|e| NativeError::CaptureFailed(e.to_string()))
}

pub fn grab_frame(window_title: &str) -> Result<(Vec<u8>, u32, u32), NativeError> {
    let image = capture_window(window_title)?;
    let (w, h) = (image.width(), image.height());

    let bgr = if w == scale::NORM_W && h == scale::NORM_H {
        scale::rgba_to_bgr(&image)
    } else {
        scale::rgba_to_bgr(&scale::resize_rgba(&image, scale::NORM_W, scale::NORM_H))
    };

    Ok((bgr, scale::NORM_W, scale::NORM_H))
}

pub fn grab_frame_raw(window_title: &str) -> Result<(Vec<u8>, u32, u32), NativeError> {
    let image = capture_window(window_title)?;
    let (w, h) = (image.width(), image.height());
    Ok((scale::rgba_to_bgr(&image), w, h))
}

pub fn grab_frame_region(window_title: &str, rx: u32, ry: u32, rw: u32, rh: u32)
    -> Result<(Vec<u8>, u32, u32), NativeError>
{
    let image = capture_window(window_title)?;
    let (src_w, src_h) = (image.width(), image.height());

    let (cx, cy, cw, ch) = scale::scale_rect(rx, ry, rw, rh, src_w, src_h);
    let cropped = image::imageops::crop_imm(&image, cx, cy, cw, ch).to_image();

    let final_img = if src_w == scale::NORM_W && src_h == scale::NORM_H {
        cropped
    } else {
        scale::resize_rgba(&cropped, rw, rh)
    };

    Ok((scale::rgba_to_bgr(&final_img), rw, rh))
}

pub fn save_png(bgr: &[u8], width: u32, height: u32, path: &str) -> Result<(), NativeError> {
    let rgb: Vec<u8> = bgr
        .chunks_exact(3)
        .flat_map(|chunk| [chunk[2], chunk[1], chunk[0]])
        .collect();

    let img: ImageBuffer<Rgb<u8>, _> =
        ImageBuffer::from_raw(width, height, rgb)
            .ok_or_else(|| NativeError::EncodeFailed("buffer size mismatch".to_string()))?;

    img.save(path)
        .map_err(|e| NativeError::EncodeFailed(e.to_string()))
}

fn capture_window(title: &str) -> Result<ImageBuffer<Rgba<u8>, Vec<u8>>, NativeError> {
    let title_lower = title.to_lowercase();
    let windows = Window::all().map_err(|e| NativeError::CaptureFailed(e.to_string()))?;

    let window = windows
        .into_iter()
        .find(|w| {
            w.title()
                .ok()
                .is_some_and(|t| t.to_lowercase().contains(&title_lower))
                || w.app_name()
                    .ok()
                    .is_some_and(|a| a.to_lowercase().contains(&title_lower))
        })
        .ok_or(NativeError::WindowNotFound)?;

    window
        .capture_image()
        .map_err(|e| NativeError::CaptureFailed(e.to_string()))
}
