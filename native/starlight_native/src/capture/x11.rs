use std::collections::HashMap;
use std::os::fd::{FromRawFd, IntoRawFd, OwnedFd};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

use xcb::Xid;
use xcb::x::{self, Atom, Drawable, Window};

use crate::error::NativeError;

pub struct Display {
    pub name: String,
    conn: xcb::Connection,
    root: Window,
    client_list: Atom,
    net_wm_name: Atom,
    utf8_string: Atom,
    active_window: Atom,
    shm: Option<Mutex<ShmCapture>>,
}

struct Segment {
    seg: xcb::shm::Seg,
    ptr: *mut u8,
    len: usize,
}

unsafe impl Send for Segment {}

impl Drop for Segment {
    fn drop(&mut self) {
        unsafe { libc::munmap(self.ptr.cast(), self.len) };
    }
}

struct ShmCapture {
    pixmap: x::Pixmap,
    named: bool,
    segment: Option<Segment>,
}

#[derive(Clone)]
pub struct Located {
    pub display: Arc<Display>,
    pub window: Window,
}

static DISPLAYS: OnceLock<Mutex<HashMap<String, Arc<Display>>>> = OnceLock::new();
static LAST: Mutex<Option<(String, Located)>> = Mutex::new(None);
static TARGET: Mutex<Option<String>> = Mutex::new(None);
static UNRESPONSIVE: OnceLock<Mutex<HashMap<String, Instant>>> = OnceLock::new();

const CONNECT_TIMEOUT: Duration = Duration::from_millis(1500);
const UNRESPONSIVE_TTL: Duration = Duration::from_secs(30);

fn xerr(e: impl std::fmt::Display) -> NativeError {
    NativeError::CaptureFailed(e.to_string())
}

pub fn host_display_name() -> Option<String> {
    static HOST: OnceLock<Option<String>> = OnceLock::new();
    HOST.get_or_init(|| std::env::var("DISPLAY").ok().filter(|d| !d.is_empty()))
        .clone()
}

fn display_names() -> Vec<String> {
    let mut numbers: Vec<u32> = std::fs::read_dir("/tmp/.X11-unix")
        .map(|entries| {
            entries
                .filter_map(|e| e.ok()?.file_name().to_str()?.strip_prefix('X')?.parse().ok())
                .collect()
        })
        .unwrap_or_default();
    numbers.sort_unstable();

    let mut names: Vec<String> = host_display_name().into_iter().collect();
    for n in numbers {
        let name = format!(":{n}");
        if !names.contains(&name) {
            names.push(name);
        }
    }
    names
}

fn intern(conn: &xcb::Connection, name: &str) -> Result<Atom, NativeError> {
    let cookie = conn.send_request(&x::InternAtom {
        only_if_exists: false,
        name: name.as_bytes(),
    });
    Ok(conn.wait_for_reply(cookie).map_err(xerr)?.atom())
}

fn shm_supported(conn: &xcb::Connection) -> bool {
    let active: Vec<xcb::Extension> = conn.active_extensions().collect();
    if !active.contains(&xcb::Extension::Shm) || !active.contains(&xcb::Extension::Composite) {
        return false;
    }

    let shm = conn.send_request(&xcb::shm::QueryVersion {});
    let composite = conn.send_request(&xcb::composite::QueryVersion {
        client_major_version: 0,
        client_minor_version: 4,
    });
    let shm_ok = conn
        .wait_for_reply(shm)
        .is_ok_and(|r| (r.major_version(), r.minor_version()) >= (1, 2));
    let composite_ok = conn
        .wait_for_reply(composite)
        .is_ok_and(|r| (r.major_version(), r.minor_version()) >= (0, 2));
    shm_ok && composite_ok
}

fn open_display(name: &str) -> Result<Display, NativeError> {
    let (conn, screen_num) = xcb::Connection::connect_with_extensions(
        Some(name),
        &[],
        &[xcb::Extension::Shm, xcb::Extension::Composite],
    )
    .map_err(xerr)?;
    let root = conn
        .get_setup()
        .roots()
        .nth(screen_num as usize)
        .ok_or_else(|| xerr(format!("{name}: no screen {screen_num}")))?
        .root();

    Ok(Display {
        name: name.to_string(),
        client_list: intern(&conn, "_NET_CLIENT_LIST")?,
        net_wm_name: intern(&conn, "_NET_WM_NAME")?,
        utf8_string: intern(&conn, "UTF8_STRING")?,
        active_window: intern(&conn, "_NET_ACTIVE_WINDOW")?,
        shm: shm_supported(&conn).then(|| {
            Mutex::new(ShmCapture {
                pixmap: conn.generate_id(),
                named: false,
                segment: None,
            })
        }),
        conn,
        root,
    })
}

fn open_display_within(name: &str) -> Option<Display> {
    let unresponsive = UNRESPONSIVE.get_or_init(Default::default);
    let skip = unresponsive
        .lock()
        .ok()?
        .get(name)
        .is_some_and(|at| at.elapsed() < UNRESPONSIVE_TTL);
    if skip {
        return None;
    }

    let (tx, rx) = std::sync::mpsc::channel();
    let owned = name.to_string();
    std::thread::spawn(move || {
        let _ = tx.send(open_display(&owned));
    });

    match rx.recv_timeout(CONNECT_TIMEOUT) {
        Ok(opened) => opened.ok(),
        Err(_) => {
            eprintln!("[starlight_native] X display {name} did not answer, skipping it for a while");
            unresponsive.lock().ok()?.insert(name.to_string(), Instant::now());
            None
        }
    }
}

fn display(name: &str) -> Option<Arc<Display>> {
    let mut cache = DISPLAYS.get_or_init(Default::default).lock().ok()?;

    if let Some(d) = cache.get(name) {
        if d.conn.has_error().is_ok() {
            return Some(d.clone());
        }
        cache.remove(name);
    }

    let d = Arc::new(open_display_within(name)?);
    cache.insert(name.to_string(), d.clone());
    Some(d)
}

fn property(d: &Display, window: Window, property: Atom, r#type: Atom) -> Option<x::GetPropertyReply> {
    let cookie = d.conn.send_request(&x::GetProperty {
        delete: false,
        window,
        property,
        r#type,
        long_offset: 0,
        long_length: 1024,
    });
    d.conn.wait_for_reply(cookie).ok()
}

fn title(d: &Display, window: Window) -> String {
    let net = property(d, window, d.net_wm_name, d.utf8_string)
        .map(|r| String::from_utf8_lossy(r.value::<u8>()).into_owned())
        .unwrap_or_default();
    if !net.is_empty() {
        return net;
    }
    property(d, window, x::ATOM_WM_NAME, x::ATOM_ANY)
        .map(|r| String::from_utf8_lossy(r.value::<u8>()).into_owned())
        .unwrap_or_default()
}

fn class(d: &Display, window: Window) -> String {
    property(d, window, x::ATOM_WM_CLASS, x::ATOM_STRING)
        .map(|r| String::from_utf8_lossy(r.value::<u8>()).replace('\0', " "))
        .unwrap_or_default()
}

fn find_on(d: &Arc<Display>, query_lower: &str) -> Option<Located> {
    let clients = property(d, d.root, d.client_list, x::ATOM_WINDOW)?;
    clients
        .value::<Window>()
        .iter()
        .find(|&&w| {
            title(d, w).to_lowercase().contains(query_lower)
                || class(d, w).to_lowercase().contains(query_lower)
        })
        .map(|&window| Located { display: d.clone(), window })
}

fn alive(located: &Located) -> bool {
    let cookie = located.display.conn.send_request(&x::GetGeometry {
        drawable: Drawable::Window(located.window),
    });
    located.display.conn.wait_for_reply(cookie).is_ok()
}

pub fn locate(query: &str) -> Result<Located, NativeError> {
    let query_lower = query.to_lowercase();
    let mut last = LAST.lock().map_err(xerr)?;

    if let Some((q, located)) = last.as_ref() {
        if *q == query_lower && alive(located) {
            return Ok(located.clone());
        }
    }

    let found = display_names()
        .iter()
        .filter_map(|name| display(name))
        .find_map(|d| find_on(&d, &query_lower));

    *last = found.clone().map(|l| (query_lower, l));
    let located = found.ok_or(NativeError::WindowNotFound)?;
    if let Ok(mut target) = TARGET.lock() {
        *target = Some(located.display.name.clone());
    }
    Ok(located)
}

pub fn forget() {
    if let Ok(mut last) = LAST.lock() {
        *last = None;
    }
    if let Some(displays) = DISPLAYS.get() {
        if let Ok(mut cache) = displays.lock() {
            cache.clear();
        }
    }
}

pub fn located_display_name() -> Option<String> {
    TARGET.lock().ok()?.clone()
}

pub fn nested_display_name() -> Option<String> {
    located_display_name().filter(|name| Some(name) != host_display_name().as_ref())
}

pub fn rect(located: &Located) -> Result<(i32, i32, u32, u32), NativeError> {
    let conn = &located.display.conn;
    let geometry = conn.send_request(&x::GetGeometry {
        drawable: Drawable::Window(located.window),
    });
    let translate = conn.send_request(&x::TranslateCoordinates {
        src_window: located.window,
        dst_window: located.display.root,
        src_x: 0,
        src_y: 0,
    });
    let geometry = conn.wait_for_reply(geometry).map_err(xerr)?;
    let translate = conn.wait_for_reply(translate).map_err(xerr)?;

    Ok((
        translate.dst_x() as i32,
        translate.dst_y() as i32,
        geometry.width() as u32,
        geometry.height() as u32,
    ))
}

pub fn focused(located: &Located) -> Result<bool, NativeError> {
    let d = &located.display;
    let active = property(d, d.root, d.active_window, x::ATOM_WINDOW)
        .ok_or_else(|| xerr("_NET_ACTIVE_WINDOW unreadable"))?;
    Ok(active.value::<u32>().first() == Some(&located.window.resource_id()))
}

fn check_layout(conn: &xcb::Connection, depth: u8) -> Result<(), NativeError> {
    let setup = conn.get_setup();
    let bits_per_pixel = setup
        .pixmap_formats()
        .iter()
        .find(|f| f.depth() == depth)
        .map(|f| f.bits_per_pixel())
        .ok_or_else(|| xerr(format!("no pixmap format for depth {depth}")))?;
    if bits_per_pixel != 32 || setup.image_byte_order() != x::ImageOrder::LsbFirst {
        return Err(xerr(format!(
            "unsupported pixel layout: {bits_per_pixel}bpp {:?}",
            setup.image_byte_order()
        )));
    }
    Ok(())
}

pub fn bgrx_to_bgr_into(src: &[u8], out: &mut [u8]) {
    let pixels = (src.len() / 4).min(out.len() / 3);
    unsafe {
        let s = src.as_ptr() as *const u32;
        let d = out.as_mut_ptr();
        for i in 0..pixels {
            let [b, g, r, _] = s.add(i).read_unaligned().to_le_bytes();
            let o = d.add(i * 3);
            *o = b;
            *o.add(1) = g;
            *o.add(2) = r;
        }
    }
}

pub fn bgrx_to_bgr(src: &[u8]) -> Vec<u8> {
    let mut out = vec![0u8; src.len() / 4 * 3];
    bgrx_to_bgr_into(src, &mut out);
    out
}

fn new_segment(conn: &xcb::Connection, len: usize) -> Result<Segment, NativeError> {
    let raw = unsafe { libc::memfd_create(c"starlight-capture".as_ptr(), libc::MFD_CLOEXEC) };
    if raw < 0 {
        return Err(xerr(std::io::Error::last_os_error()));
    }
    let fd = unsafe { OwnedFd::from_raw_fd(raw) };

    if unsafe { libc::ftruncate(raw, len as libc::off_t) } != 0 {
        return Err(xerr(std::io::Error::last_os_error()));
    }
    let ptr = unsafe {
        libc::mmap(std::ptr::null_mut(), len, libc::PROT_READ, libc::MAP_SHARED, raw, 0)
    };
    if ptr == libc::MAP_FAILED {
        return Err(xerr(std::io::Error::last_os_error()));
    }
    let segment = Segment { seg: conn.generate_id(), ptr: ptr.cast(), len };

    conn.send_and_check_request(&xcb::shm::AttachFd {
        shmseg: segment.seg,
        shm_fd: fd.into_raw_fd(),
        read_only: false,
    })
    .map_err(xerr)?;
    Ok(segment)
}

pub type Area = (u32, u32, u32, u32);

fn area_len(&(_, _, w, h): &Area) -> usize {
    w as usize * h as usize * 4
}

fn shm_capture<'a>(
    conn: &xcb::Connection,
    shm: &'a mut ShmCapture,
    window: Window,
    areas: &[Area],
) -> Result<Vec<&'a [u8]>, NativeError> {
    let total: usize = areas.iter().map(area_len).sum();
    if shm.segment.as_ref().is_none_or(|s| s.len < total) {
        if let Some(old) = shm.segment.take() {
            conn.send_request(&xcb::shm::Detach { shmseg: old.seg });
        }
        shm.segment = Some(new_segment(conn, total)?);
    }
    let (seg, ptr) = match shm.segment.as_ref() {
        Some(s) => (s.seg, s.ptr),
        None => return Err(xerr("shm segment missing")),
    };

    if shm.named {
        conn.send_request(&x::FreePixmap { pixmap: shm.pixmap });
    }
    let name = conn.send_request_checked(&xcb::composite::NameWindowPixmap {
        window,
        pixmap: shm.pixmap,
    });

    let mut offset = 0;
    let images: Vec<_> = areas
        .iter()
        .map(|area @ &(x, y, w, h)| {
            let cookie = conn.send_request(&xcb::shm::GetImage {
                drawable: Drawable::Pixmap(shm.pixmap),
                x: x as i16,
                y: y as i16,
                width: w as u16,
                height: h as u16,
                plane_mask: u32::MAX,
                format: x::ImageFormat::ZPixmap as u8,
                shmseg: seg,
                offset: offset as u32,
            });
            let at = offset;
            offset += area_len(area);
            (cookie, at, area_len(area))
        })
        .collect();

    shm.named = conn.check_request(name).is_ok();

    images
        .into_iter()
        .map(|(cookie, at, len)| {
            let reply = conn.wait_for_reply(cookie).map_err(xerr)?;
            check_layout(conn, reply.depth())?;
            if reply.size() as usize != len {
                return Err(xerr(format!("shm image is {} bytes, expected {len}", reply.size())));
            }
            Ok(unsafe { std::slice::from_raw_parts(ptr.add(at), len) })
        })
        .collect()
}

fn socket_capture(
    conn: &xcb::Connection,
    window: Window,
    areas: &[Area],
) -> Result<Vec<x::GetImageReply>, NativeError> {
    let cookies: Vec<_> = areas
        .iter()
        .map(|&(x, y, w, h)| {
            conn.send_request(&x::GetImage {
                format: x::ImageFormat::ZPixmap,
                drawable: Drawable::Window(window),
                x: x as i16,
                y: y as i16,
                width: w as u16,
                height: h as u16,
                plane_mask: u32::MAX,
            })
        })
        .collect();

    cookies
        .into_iter()
        .map(|cookie| {
            let reply = conn.wait_for_reply(cookie).map_err(xerr)?;
            check_layout(conn, reply.depth())?;
            Ok(reply)
        })
        .collect()
}

fn clamp_area((x, y, w, h): Area, win_w: u32, win_h: u32) -> Result<Area, NativeError> {
    let (x, y) = (x.min(win_w), y.min(win_h));
    let area = (x, y, w.min(win_w - x), h.min(win_h - y));
    if area.2 == 0 || area.3 == 0 {
        return Err(xerr("empty capture region"));
    }
    Ok(area)
}

pub fn with_bgrx_all<T>(
    located: &Located,
    regions: &[Area],
    mut f: impl FnMut(usize, &[u8], u32, u32) -> T,
) -> Result<Vec<T>, NativeError> {
    let (_, _, win_w, win_h) = rect(located)?;
    let areas = regions
        .iter()
        .map(|&r| clamp_area(r, win_w, win_h))
        .collect::<Result<Vec<_>, _>>()?;

    let conn = &located.display.conn;
    if let Some(mut shm) = located.display.shm.as_ref().and_then(|m| m.lock().ok()) {
        if let Ok(images) = shm_capture(conn, &mut shm, located.window, &areas) {
            return Ok(images
                .into_iter()
                .zip(&areas)
                .enumerate()
                .map(|(i, (bgrx, &(_, _, w, h)))| f(i, bgrx, w, h))
                .collect());
        }
    }

    Ok(socket_capture(conn, located.window, &areas)?
        .iter()
        .zip(&areas)
        .enumerate()
        .map(|(i, (reply, &(_, _, w, h)))| f(i, reply.data(), w, h))
        .collect())
}

pub fn with_bgrx<T>(
    located: &Located,
    region: Option<Area>,
    f: impl FnOnce(&[u8], u32, u32) -> T,
) -> Result<T, NativeError> {
    let area = match region {
        Some(area) => area,
        None => {
            let (_, _, win_w, win_h) = rect(located)?;
            (0, 0, win_w, win_h)
        }
    };
    let mut f = Some(f);
    with_bgrx_all(located, &[area], |_, bgrx, w, h| f.take().map(|f| f(bgrx, w, h)))?
        .pop()
        .flatten()
        .ok_or_else(|| xerr("no image captured"))
}

pub fn query_pointer(display_name: &str) -> Result<(i32, i32), NativeError> {
    let d = display(display_name).ok_or_else(|| xerr(format!("{display_name}: cannot connect")))?;
    let cookie = d.conn.send_request(&x::QueryPointer { window: d.root });
    let reply = d.conn.wait_for_reply(cookie).map_err(xerr)?;
    Ok((reply.root_x() as i32, reply.root_y() as i32))
}
