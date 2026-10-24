use fast_image_resize::images::{Image, ImageRef};
use fast_image_resize::{PixelType, ResizeOptions, Resizer};

use crate::error::NativeError;

pub const NORM_W: u32 = 1920;
pub const NORM_H: u32 = 1080;

pub const LANCZOS3_SUPPORT: f64 = 3.0;

pub type CropBox = (f64, f64, f64, f64);

fn resize_err(e: impl std::fmt::Display) -> NativeError {
    NativeError::CaptureFailed(format!("resize: {e}"))
}

pub fn resize_bgr_into(
    bgr: &[u8],
    w: u32,
    h: u32,
    crop: Option<CropBox>,
    out: &mut [u8],
    to_w: u32,
    to_h: u32,
) -> Result<(), NativeError> {
    let src = ImageRef::new(w, h, bgr, PixelType::U8x3).map_err(resize_err)?;
    let mut dst = Image::from_slice_u8(to_w, to_h, out, PixelType::U8x3).map_err(resize_err)?;
    let options = match crop {
        Some((left, top, width, height)) => ResizeOptions::new().crop(left, top, width, height),
        None => ResizeOptions::new(),
    };
    Resizer::new().resize(&src, &mut dst, &options).map_err(resize_err)
}
