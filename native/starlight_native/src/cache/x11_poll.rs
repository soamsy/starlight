//! X11 polling capture thread.
//!
//! Polls the game window at ~30fps via `capture::x11::capture_bgr` (MIT-SHM
//! `GetImage` of the composite window pixmap, socket `GetImage` fallback), the
//! same path used by single-shot hook matching. `x11::locate` keeps the window
//! cached and validates it with one `GetGeometry` per frame, so the full scan
//! across every X display only runs when the window goes away.

use std::sync::Arc;
use std::sync::RwLock;
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread::JoinHandle;

use rustler::ResourceArc;

use crate::cache::{CachedFrame, FrameData};
use crate::capture::x11;
use crate::scale;

pub fn start(
    window_title: String,
    frame_store: Arc<RwLock<Option<CachedFrame>>>,
    stop: Arc<AtomicBool>,
) -> JoinHandle<()> {
    std::thread::spawn(move || {
        run_loop(&window_title, &frame_store, &stop);
    })
}

const BASE_INTERVAL_MS: u64 = 33;
const MAX_BACKOFF_MS: u64 = 2_000;

fn run_loop(title: &str, frame_store: &Arc<RwLock<Option<CachedFrame>>>, stop: &AtomicBool) {
    let mut backoff_ms = BASE_INTERVAL_MS;

    loop {
        if stop.load(Ordering::Relaxed) {
            break;
        }

        let sleep_ms = if let Ok(located) = x11::locate(title) {
            backoff_ms = BASE_INTERVAL_MS;
            if let Ok((bgr, w, h)) = x11::capture_bgr(&located, None) {
                if let Ok(mut guard) = frame_store.write() {
                    *guard = Some(CachedFrame {
                        data: ResourceArc::new(FrameData { bgr: scale::normalize_bgr(bgr, w, h) }),
                        width: scale::NORM_W,
                        height: scale::NORM_H,
                        captured_at: std::time::Instant::now(),
                    });
                }
            }
            BASE_INTERVAL_MS
        } else {
            backoff_ms = (backoff_ms * 2).min(MAX_BACKOFF_MS);
            backoff_ms
        };

        std::thread::sleep(std::time::Duration::from_millis(sleep_ms));
    }
}
