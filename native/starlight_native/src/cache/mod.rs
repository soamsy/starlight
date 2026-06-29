pub mod xcap_poll;

use std::sync::{Arc, Mutex, OnceLock, RwLock};
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread::JoinHandle;
use std::time::Instant;

use crate::error::NativeError;

pub struct CachedFrame {
    pub bgr: Vec<u8>,
    pub width: u32,
    pub height: u32,
    pub captured_at: Instant,
}

static FRAME: OnceLock<Arc<RwLock<Option<CachedFrame>>>> = OnceLock::new();
static STOP: OnceLock<Arc<AtomicBool>> = OnceLock::new();
static THREAD: Mutex<Option<JoinHandle<()>>> = Mutex::new(None);

pub fn frame_arc() -> Arc<RwLock<Option<CachedFrame>>> {
    FRAME.get_or_init(|| Arc::new(RwLock::new(None))).clone()
}

pub fn stop_arc() -> Arc<AtomicBool> {
    STOP.get_or_init(|| Arc::new(AtomicBool::new(false))).clone()
}

pub fn start(window_title: String) -> Result<(), NativeError> {
    // Signal any running thread to stop, then join it before resetting the flag.
    // This prevents two threads running concurrently when start() is called twice.
    stop_arc().store(true, Ordering::Relaxed);
    if let Ok(mut guard) = THREAD.lock() {
        if let Some(handle) = guard.take() {
            let _ = handle.join();
        }
    }

    stop_arc().store(false, Ordering::Relaxed);
    if let Ok(mut guard) = frame_arc().write() {
        *guard = None;
    }

    let handle = xcap_poll::start(window_title, frame_arc(), stop_arc());
    if let Ok(mut guard) = THREAD.lock() {
        *guard = Some(handle);
    }

    Ok(())
}

pub fn stop() {
    stop_arc().store(true, Ordering::Relaxed);
    if let Ok(mut guard) = frame_arc().write() {
        *guard = None;
    }
}

pub fn grab_frame() -> Option<(Vec<u8>, u32, u32)> {
    let arc = frame_arc();
    let guard = arc.read().ok()?;
    guard.as_ref().map(|f| (f.bgr.clone(), f.width, f.height))
}

pub fn grab_region(rx: u32, ry: u32, rw: u32, rh: u32) -> Option<(Vec<u8>, u32, u32)> {
    let arc = frame_arc();
    let guard = arc.read().ok()?;
    guard.as_ref().map(|f| {
        let stride = (f.width * 3) as usize;
        let mut out = Vec::with_capacity((rw * rh * 3) as usize);
        for row in 0..rh {
            let y = ry + row;
            if y >= f.height {
                break;
            }
            let start = y as usize * stride + rx as usize * 3;
            let end = (start + rw as usize * 3).min(f.bgr.len());
            if start >= f.bgr.len() {
                break;
            }
            out.extend_from_slice(&f.bgr[start..end]);
        }
        (out, rw, rh)
    })
}

pub fn age_ms() -> Option<u64> {
    let arc = frame_arc();
    let guard = arc.read().ok()?;
    guard.as_ref().map(|f| f.captured_at.elapsed().as_millis() as u64)
}
