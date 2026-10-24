use fast_image_resize::images::{Image, ImageRef};
use fast_image_resize::{PixelType, Resizer};

use crate::error::NativeError;

pub const NORM_W: u32 = 1920;
pub const NORM_H: u32 = 1080;

pub fn scale_rect(
    rx: u32, ry: u32, rw: u32, rh: u32,
    target_w: u32, target_h: u32,
) -> (u32, u32, u32, u32) {
    if target_w == NORM_W && target_h == NORM_H {
        return (rx, ry, rw, rh);
    }
    let sx = target_w as f64 / NORM_W as f64;
    let sy = target_h as f64 / NORM_H as f64;
    let x = (rx as f64 * sx) as u32;
    let y = (ry as f64 * sy) as u32;
    let w = ((rw as f64 * sx).ceil() as u32).min(target_w.saturating_sub(x));
    let h = ((rh as f64 * sy).ceil() as u32).min(target_h.saturating_sub(y));
    (x, y, w, h)
}

fn resize_err(e: impl std::fmt::Display) -> NativeError {
    NativeError::CaptureFailed(format!("resize: {e}"))
}

pub fn resize_bgr_into(bgr: &[u8], w: u32, h: u32, out: &mut [u8], to_w: u32, to_h: u32) -> Result<(), NativeError> {
    let src = ImageRef::new(w, h, bgr, PixelType::U8x3).map_err(resize_err)?;
    let mut dst = Image::from_slice_u8(to_w, to_h, out, PixelType::U8x3).map_err(resize_err)?;
    Resizer::new().resize(&src, &mut dst, None).map_err(resize_err)
}
