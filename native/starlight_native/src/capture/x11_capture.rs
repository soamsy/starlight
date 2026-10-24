use std::ops::DerefMut;

use image::{ImageBuffer, Rgb};
use crate::capture::x11;
use crate::error::NativeError;
use crate::scale;

pub fn get_window_rect(class_name: &str) -> Result<(i32, i32, u32, u32), NativeError> {
    x11::rect(&x11::locate(class_name)?)
}

/// Whether the window has OS input focus right now — reads `_NET_ACTIVE_WINDOW`
/// off the root window of whichever X display the game is on and compares ids,
/// two XCB round trips (window validation + property), same cost class as
/// `get_window_rect`. Not cached: callers
/// gating input injection need this fresh at the moment of the check, not
/// whatever it was as of some earlier poll.
pub fn is_window_focused(class_name: &str) -> Result<bool, NativeError> {
    x11::focused(&x11::locate(class_name)?)
}

enum Captured<B> {
    Native(B),
    Scaled(Vec<u8>, u32, u32),
}

fn resize_into<B: DerefMut<Target = [u8]>>(
    bgr: &[u8],
    (w, h): (u32, u32),
    (to_w, to_h): (u32, u32),
    alloc: &mut impl FnMut(usize) -> B,
) -> Result<B, NativeError> {
    let mut out = alloc(to_w as usize * to_h as usize * 3);
    scale::resize_bgr_into(bgr, w, h, &mut out, to_w, to_h)?;
    Ok(out)
}

fn convert_into<B: DerefMut<Target = [u8]>>(bgrx: &[u8], alloc: &mut impl FnMut(usize) -> B) -> B {
    let mut out = alloc(bgrx.len() / 4 * 3);
    x11::bgrx_to_bgr_into(bgrx, &mut out);
    out
}

pub fn grab_frame<B: DerefMut<Target = [u8]>>(
    window_title: &str,
    mut alloc: impl FnMut(usize) -> B,
) -> Result<(B, u32, u32), NativeError> {
    let captured = x11::with_bgrx(&x11::locate(window_title)?, None, |bgrx, w, h| {
        if w == scale::NORM_W && h == scale::NORM_H {
            Captured::Native(convert_into(bgrx, &mut alloc))
        } else {
            Captured::Scaled(x11::bgrx_to_bgr(bgrx), w, h)
        }
    })?;

    let out = match captured {
        Captured::Native(out) => out,
        Captured::Scaled(bgr, w, h) => resize_into(&bgr, (w, h), (scale::NORM_W, scale::NORM_H), &mut alloc)?,
    };
    Ok((out, scale::NORM_W, scale::NORM_H))
}

pub fn grab_frame_raw<B: DerefMut<Target = [u8]>>(
    window_title: &str,
    mut alloc: impl FnMut(usize) -> B,
) -> Result<(B, u32, u32), NativeError> {
    x11::with_bgrx(&x11::locate(window_title)?, None, |bgrx, w, h| {
        (convert_into(bgrx, &mut alloc), w, h)
    })
}

pub fn grab_frame_region<B: DerefMut<Target = [u8]>>(
    window_title: &str,
    (rx, ry, rw, rh): (u32, u32, u32, u32),
    mut alloc: impl FnMut(usize) -> B,
) -> Result<(B, u32, u32), NativeError> {
    let located = x11::locate(window_title)?;
    let (_, _, src_w, src_h) = x11::rect(&located)?;
    let area = scale::scale_rect(rx, ry, rw, rh, src_w, src_h);

    if src_w == scale::NORM_W && src_h == scale::NORM_H {
        x11::with_bgrx(&located, Some(area), |bgrx, w, h| (convert_into(bgrx, &mut alloc), w, h))
    } else {
        let (bgr, w, h) = x11::capture_bgr(&located, Some(area))?;
        Ok((resize_into(&bgr, (w, h), (rw, rh), &mut alloc)?, rw, rh))
    }
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
