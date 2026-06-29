use image::{ImageBuffer, Rgba, imageops};

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

pub fn resize_rgba(
    img: &ImageBuffer<Rgba<u8>, Vec<u8>>,
    w: u32, h: u32,
) -> ImageBuffer<Rgba<u8>, Vec<u8>> {
    imageops::resize(img, w, h, imageops::FilterType::Lanczos3)
}

pub fn rgba_to_bgr(img: &ImageBuffer<Rgba<u8>, Vec<u8>>) -> Vec<u8> {
    img.pixels().flat_map(|px| [px[2], px[1], px[0]]).collect()
}

