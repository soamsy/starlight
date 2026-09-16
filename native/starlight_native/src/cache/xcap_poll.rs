//! xcap-based polling capture thread.
//!
//! Polls the game window at ~30fps via xcap's X11 window capture, the same
//! path used by single-shot hook matching. Caches the window handle across
//! frames so `Window::all()` is only called when the handle goes stale.

use std::sync::Arc;
use std::sync::RwLock;
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread::JoinHandle;

use image::RgbaImage;
use xcap::Window;

use crate::cache::CachedFrame;
use crate::scale;

pub fn start(
    window_title: String,
    frame_store: Arc<RwLock<Option<CachedFrame>>>,
    stop: Arc<AtomicBool>,
) -> JoinHandle<()> {
    std::thread::spawn(move || {
        run_loop(&window_title.to_lowercase(), &frame_store, &stop);
    })
}

const BASE_INTERVAL_MS: u64 = 33;
const MAX_BACKOFF_MS: u64 = 2_000;

fn run_loop(title_lower: &str, frame_store: &Arc<RwLock<Option<CachedFrame>>>, stop: &AtomicBool) {
    let mut cached: Option<Window> = None;
    let mut backoff_ms = BASE_INTERVAL_MS;

    loop {
        if stop.load(Ordering::Relaxed) {
            break;
        }

        if cached.is_none() {
            cached = find_window(title_lower);
        }

        let sleep_ms = if let Some(window) = cached.take() {
            backoff_ms = BASE_INTERVAL_MS;
            if let Ok(image) = window.capture_image() {
                if let Ok(mut guard) = frame_store.write() {
                    *guard = Some(to_cached_frame(image));
                }
                cached = Some(window);
            }
            BASE_INTERVAL_MS
        } else {
            backoff_ms = (backoff_ms * 2).min(MAX_BACKOFF_MS);
            backoff_ms
        };

        std::thread::sleep(std::time::Duration::from_millis(sleep_ms));
    }
}

fn find_window(title_lower: &str) -> Option<Window> {
    Window::all().ok()?.into_iter().find(|w| {
        w.title()
            .ok()
            .is_some_and(|t| t.to_lowercase().contains(title_lower))
            || w.app_name()
                .ok()
                .is_some_and(|a| a.to_lowercase().contains(title_lower))
    })
}

fn to_cached_frame(image: RgbaImage) -> CachedFrame {
    let (w, h) = (image.width(), image.height());
    let bgr = if w == scale::NORM_W && h == scale::NORM_H {
        scale::rgba_to_bgr(&image)
    } else {
        scale::rgba_to_bgr(&scale::resize_rgba(&image, scale::NORM_W, scale::NORM_H))
    };
    CachedFrame {
        bgr,
        width: scale::NORM_W,
        height: scale::NORM_H,
        captured_at: std::time::Instant::now(),
    }
}
