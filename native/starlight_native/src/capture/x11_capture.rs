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
    crop: Option<scale::CropBox>,
    (to_w, to_h): (u32, u32),
    alloc: &mut impl FnMut(usize) -> B,
) -> Result<B, NativeError> {
    let mut out = alloc(to_w as usize * to_h as usize * 3);
    scale::resize_bgr_into(bgr, w, h, crop, &mut out, to_w, to_h)?;
    Ok(out)
}

struct RegionPlan {
    area: x11::Area,
    crop: Option<scale::CropBox>,
}

fn padded_span(f0: f64, f1: f64, ratio: f64, limit: u32) -> (u32, u32) {
    let pad = (scale::LANCZOS3_SUPPORT * ratio.max(1.0)).ceil() + 1.0;
    ((f0 - pad).floor().max(0.0) as u32, ((f1 + pad).ceil() as u32).min(limit))
}

fn plan_region((x, y, w, h): x11::Area, src_w: u32, src_h: u32) -> RegionPlan {
    if src_w == scale::NORM_W && src_h == scale::NORM_H {
        return RegionPlan { area: (x, y, w, h), crop: None };
    }
    let sx = src_w as f64 / scale::NORM_W as f64;
    let sy = src_h as f64 / scale::NORM_H as f64;
    let (fx0, fx1) = (x as f64 * sx, (x + w) as f64 * sx);
    let (fy0, fy1) = (y as f64 * sy, (y + h) as f64 * sy);
    let (ax0, ax1) = padded_span(fx0, fx1, sx, src_w);
    let (ay0, ay1) = padded_span(fy0, fy1, sy, src_h);
    RegionPlan {
        area: (ax0, ay0, ax1 - ax0, ay1 - ay0),
        crop: Some((fx0 - ax0 as f64, fy0 - ay0 as f64, fx1 - fx0, fy1 - fy0)),
    }
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
        Captured::Scaled(bgr, w, h) => resize_into(&bgr, (w, h), None, (scale::NORM_W, scale::NORM_H), &mut alloc)?,
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
    (rx, ry, rw, rh): x11::Area,
    alloc: impl FnMut(usize) -> B,
) -> Result<(B, u32, u32), NativeError> {
    grab_regions(window_title, &[(rx, ry, rw, rh)], alloc)?
        .pop()
        .map(|out| (out, rw, rh))
        .ok_or_else(|| NativeError::CaptureFailed("no image captured".to_string()))
}

pub fn grab_regions<B: DerefMut<Target = [u8]>>(
    window_title: &str,
    rects: &[x11::Area],
    mut alloc: impl FnMut(usize) -> B,
) -> Result<Vec<B>, NativeError> {
    let located = x11::locate(window_title)?;
    let (_, _, src_w, src_h) = x11::rect(&located)?;
    let plans: Vec<RegionPlan> = rects.iter().map(|&r| plan_region(r, src_w, src_h)).collect();
    let areas: Vec<x11::Area> = plans.iter().map(|p| p.area).collect();

    let captured = x11::with_bgrx_all(&located, &areas, |i, bgrx, w, h| match plans[i].crop {
        None => Captured::Native(convert_into(bgrx, &mut alloc)),
        Some(_) => Captured::Scaled(x11::bgrx_to_bgr(bgrx), w, h),
    })?;

    captured
        .into_iter()
        .zip(plans.iter().zip(rects))
        .map(|(c, (plan, &(_, _, rw, rh)))| match c {
            Captured::Native(out) => Ok(out),
            Captured::Scaled(bgr, w, h) => resize_into(&bgr, (w, h), plan.crop, (rw, rh), &mut alloc),
        })
        .collect()
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
