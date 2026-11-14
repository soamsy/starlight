use std::ops::DerefMut;
use std::sync::Once;

use image::{ImageBuffer, Rgb};
use windows_sys::Win32::Foundation::{CloseHandle, HWND, LPARAM, POINT, RECT};
use windows_sys::Win32::Graphics::Gdi::{
    BitBlt, ClientToScreen, CreateCompatibleBitmap, CreateCompatibleDC, DeleteDC, DeleteObject, EnumDisplayMonitors,
    GetDC, GetDIBits, GetMonitorInfoW, MonitorFromWindow, ReleaseDC, SelectObject, BITMAPINFO, BITMAPINFOHEADER, BI_RGB,
    DIB_RGB_COLORS, HDC, HGDIOBJ, HMONITOR, MONITORINFOEXW, MONITOR_DEFAULTTONEAREST, SRCCOPY,
};
use windows_sys::Win32::Storage::Xps::{PrintWindow, PW_CLIENTONLY};
use windows_sys::Win32::System::Threading::{OpenProcess, QueryFullProcessImageNameW, PROCESS_NAME_WIN32, PROCESS_QUERY_LIMITED_INFORMATION};
use windows_sys::Win32::UI::HiDpi::{
    AdjustWindowRectExForDpi, GetDpiForMonitor, GetDpiForWindow, GetThreadDpiAwarenessContext, GetAwarenessFromDpiAwarenessContext,
    SetProcessDpiAwarenessContext, DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2, MDT_EFFECTIVE_DPI,
};
use windows_sys::Win32::UI::WindowsAndMessaging::{
    FindWindowW, GetClassNameW, GetClientRect, GetCursorPos, GetForegroundWindow, GetSystemMetrics, GetWindowLongW,
    GetWindowRect, GetWindowTextW, GetWindowThreadProcessId, IsIconic, IsZoomed, SetWindowPos, ShowWindow, SystemParametersInfoW,
    GWL_EXSTYLE, GWL_STYLE, SM_CXVIRTUALSCREEN, SM_CYVIRTUALSCREEN, SM_XVIRTUALSCREEN, SM_YVIRTUALSCREEN, SPI_GETMOUSE,
    SPI_GETMOUSESPEED, SWP_NOACTIVATE, SWP_NOMOVE, SWP_NOZORDER, SW_RESTORE,
};

use crate::error::NativeError;

const PW_RENDERFULLCONTENT: u32 = 2;

static DPI_AWARE: Once = Once::new();

pub fn ensure_dpi_aware() {
    DPI_AWARE.call_once(|| unsafe {
        SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    });
}

pub fn wide(text: &str) -> Vec<u16> {
    text.encode_utf16().chain(std::iter::once(0)).collect()
}

pub fn find_window(title: &str) -> Option<HWND> {
    ensure_dpi_aware();
    let name = wide(title);
    let by_title = unsafe { FindWindowW(std::ptr::null(), name.as_ptr()) };
    if !by_title.is_null() {
        return Some(by_title);
    }
    let by_class = unsafe { FindWindowW(name.as_ptr(), std::ptr::null()) };
    (!by_class.is_null()).then_some(by_class)
}

pub fn find_exact(class: &str, title: &str) -> Option<HWND> {
    ensure_dpi_aware();
    let class = wide(class);
    let title = wide(title);
    let hwnd = unsafe { FindWindowW(class.as_ptr(), title.as_ptr()) };
    (!hwnd.is_null()).then_some(hwnd)
}

fn locate(title: &str) -> Result<HWND, NativeError> {
    find_window(title).ok_or(NativeError::WindowNotFound)
}

pub fn client_rect(hwnd: HWND) -> Result<(i32, i32, u32, u32), NativeError> {
    let mut rect = RECT { left: 0, top: 0, right: 0, bottom: 0 };
    let mut origin = POINT { x: 0, y: 0 };
    let ok = unsafe { GetClientRect(hwnd, &mut rect) != 0 && ClientToScreen(hwnd, &mut origin) != 0 };
    if !ok {
        return Err(NativeError::WindowNotFound);
    }
    Ok((origin.x, origin.y, (rect.right - rect.left).max(0) as u32, (rect.bottom - rect.top).max(0) as u32))
}

pub fn window_pid(hwnd: HWND) -> u32 {
    let mut pid = 0u32;
    unsafe { GetWindowThreadProcessId(hwnd, &mut pid) };
    pid
}

pub fn process_image(pid: u32) -> Option<String> {
    unsafe {
        let process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid);
        if process.is_null() {
            return None;
        }
        let mut buf = [0u16; 1024];
        let mut len = buf.len() as u32;
        let ok = QueryFullProcessImageNameW(process, PROCESS_NAME_WIN32, buf.as_mut_ptr(), &mut len) != 0;
        CloseHandle(process);
        ok.then(|| String::from_utf16_lossy(&buf[..len as usize]))
    }
}

pub fn exe_file_name(hwnd: HWND) -> Option<String> {
    let image = process_image(window_pid(hwnd))?;
    image.rsplit(['\\', '/']).next().map(|name| name.to_ascii_lowercase())
}

fn window_text(hwnd: HWND) -> String {
    let mut buf = [0u16; 512];
    let len = unsafe { GetWindowTextW(hwnd, buf.as_mut_ptr(), buf.len() as i32) };
    String::from_utf16_lossy(&buf[..len.max(0) as usize])
}

fn class_name(hwnd: HWND) -> String {
    let mut buf = [0u16; 256];
    let len = unsafe { GetClassNameW(hwnd, buf.as_mut_ptr(), buf.len() as i32) };
    String::from_utf16_lossy(&buf[..len.max(0) as usize])
}

pub fn forget() {}

pub fn get_window_rect(title: &str) -> Result<(i32, i32, u32, u32), NativeError> {
    client_rect(locate(title)?)
}

pub fn is_window_focused(title: &str) -> Result<bool, NativeError> {
    let hwnd = locate(title)?;
    Ok(unsafe { GetForegroundWindow() } == hwnd)
}

pub fn window_details(title: &str) -> Result<Vec<String>, NativeError> {
    let hwnd = locate(title)?;
    let mut outer = RECT { left: 0, top: 0, right: 0, bottom: 0 };
    unsafe { GetWindowRect(hwnd, &mut outer) };
    let (cx, cy, cw, ch) = client_rect(hwnd)?;
    let pid = window_pid(hwnd);

    Ok(vec![
        format!("title {:?}, class {:?}", window_text(hwnd), class_name(hwnd)),
        format!("process {} ({})", pid, process_image(pid).unwrap_or_else(|| "image unreadable".into())),
        format!(
            "window geometry {}x{} at {:+}{:+}",
            outer.right - outer.left,
            outer.bottom - outer.top,
            outer.left,
            outer.top
        ),
        format!("client area {cw}x{ch} at {cx:+}{cy:+}"),
        format!(
            "foreground {}, minimized {}, maximized {}",
            unsafe { GetForegroundWindow() } == hwnd,
            unsafe { IsIconic(hwnd) } != 0,
            unsafe { IsZoomed(hwnd) } != 0
        ),
        format!("window dpi {}", unsafe { GetDpiForWindow(hwnd) }),
        format!("monitor {}", monitor_name(unsafe { MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST) })),
    ])
}

pub fn resize_window(title: &str, width: u32, height: u32) -> Result<(), NativeError> {
    let hwnd = locate(title)?;
    unsafe {
        if IsZoomed(hwnd) != 0 {
            ShowWindow(hwnd, SW_RESTORE);
        }
        let style = GetWindowLongW(hwnd, GWL_STYLE) as u32;
        let ex_style = GetWindowLongW(hwnd, GWL_EXSTYLE) as u32;
        let mut rect = RECT { left: 0, top: 0, right: width as i32, bottom: height as i32 };
        if AdjustWindowRectExForDpi(&mut rect, style, 0, ex_style, GetDpiForWindow(hwnd)) == 0 {
            return Err(NativeError::CaptureFailed("AdjustWindowRectExForDpi failed".into()));
        }
        let flags = SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE;
        if SetWindowPos(hwnd, std::ptr::null_mut(), 0, 0, rect.right - rect.left, rect.bottom - rect.top, flags) == 0 {
            return Err(NativeError::CaptureFailed("SetWindowPos failed".into()));
        }
    }
    Ok(())
}

fn capture_bgra(hwnd: HWND) -> Result<(Vec<u8>, u32, u32), NativeError> {
    let (x, y, w, h) = client_rect(hwnd)?;
    if w == 0 || h == 0 {
        return Err(NativeError::CaptureFailed("the window has an empty client area".into()));
    }

    unsafe {
        let screen: HDC = GetDC(std::ptr::null_mut());
        let memory = CreateCompatibleDC(screen);
        let bitmap = CreateCompatibleBitmap(screen, w as i32, h as i32);
        let previous = SelectObject(memory, bitmap as HGDIOBJ);

        if PrintWindow(hwnd, memory, PW_CLIENTONLY | PW_RENDERFULLCONTENT) == 0 {
            BitBlt(memory, 0, 0, w as i32, h as i32, screen, x, y, SRCCOPY);
        }

        let mut info: BITMAPINFO = std::mem::zeroed();
        info.bmiHeader = BITMAPINFOHEADER {
            biSize: std::mem::size_of::<BITMAPINFOHEADER>() as u32,
            biWidth: w as i32,
            biHeight: -(h as i32),
            biPlanes: 1,
            biBitCount: 32,
            biCompression: BI_RGB,
            ..std::mem::zeroed()
        };
        let mut pixels = vec![0u8; (w * h * 4) as usize];
        let lines = GetDIBits(memory, bitmap, 0, h, pixels.as_mut_ptr().cast(), &mut info, DIB_RGB_COLORS);

        SelectObject(memory, previous);
        DeleteObject(bitmap as HGDIOBJ);
        DeleteDC(memory);
        ReleaseDC(std::ptr::null_mut(), screen);

        if lines != h as i32 {
            return Err(NativeError::CaptureFailed(format!("GetDIBits copied {lines} of {h} lines")));
        }
        Ok((pixels, w, h))
    }
}

fn bgra_to_bgr<B: DerefMut<Target = [u8]>>(
    bgra: &[u8],
    src_w: u32,
    (rx, ry, rw, rh): (u32, u32, u32, u32),
    alloc: &mut impl FnMut(usize) -> B,
) -> B {
    let mut out = alloc((rw * rh * 3) as usize);
    for row in 0..rh {
        for col in 0..rw {
            let src = (((ry + row) * src_w + rx + col) * 4) as usize;
            let dst = ((row * rw + col) * 3) as usize;
            out[dst..dst + 3].copy_from_slice(&bgra[src..src + 3]);
        }
    }
    out
}

pub fn grab_frame<B: DerefMut<Target = [u8]>>(
    window_title: &str,
    mut alloc: impl FnMut(usize) -> B,
) -> Result<(B, u32, u32), NativeError> {
    let (bgra, w, h) = capture_bgra(locate(window_title)?)?;
    Ok((bgra_to_bgr(&bgra, w, (0, 0, w, h), &mut alloc), w, h))
}

pub fn grab_frame_region<B: DerefMut<Target = [u8]>>(
    window_title: &str,
    area: (u32, u32, u32, u32),
    alloc: impl FnMut(usize) -> B,
) -> Result<(B, u32, u32), NativeError> {
    let (_, _, w, h) = area;
    let frame = grab_regions(window_title, &[area], alloc)?.pop().ok_or_else(|| NativeError::CaptureFailed("no region".into()))?;
    Ok((frame, w, h))
}

pub fn grab_regions<B: DerefMut<Target = [u8]>>(
    window_title: &str,
    rects: &[(u32, u32, u32, u32)],
    mut alloc: impl FnMut(usize) -> B,
) -> Result<Vec<B>, NativeError> {
    let (bgra, w, h) = capture_bgra(locate(window_title)?)?;
    rects
        .iter()
        .map(|&(rx, ry, rw, rh)| {
            if rx + rw > w || ry + rh > h {
                return Err(NativeError::CaptureFailed(format!("region {rx},{ry} {rw}x{rh} is outside the {w}x{h} window")));
            }
            Ok(bgra_to_bgr(&bgra, w, (rx, ry, rw, rh), &mut alloc))
        })
        .collect()
}

pub fn save_png(bgr: &[u8], width: u32, height: u32, path: &str) -> Result<(), NativeError> {
    let rgb: Vec<u8> = bgr.as_chunks::<3>().0.iter().flat_map(|&[b, g, r]| [r, g, b]).collect();
    let img: ImageBuffer<Rgb<u8>, _> =
        ImageBuffer::from_raw(width, height, rgb).ok_or_else(|| NativeError::EncodeFailed("buffer size mismatch".to_string()))?;
    img.save(path).map_err(|e| NativeError::EncodeFailed(e.to_string()))
}

fn monitor_name(monitor: HMONITOR) -> String {
    unsafe {
        let mut info: MONITORINFOEXW = std::mem::zeroed();
        info.monitorInfo.cbSize = std::mem::size_of::<MONITORINFOEXW>() as u32;
        if GetMonitorInfoW(monitor, &mut info as *mut MONITORINFOEXW as *mut _) == 0 {
            return "unknown".into();
        }
        let end = info.szDevice.iter().position(|&c| c == 0).unwrap_or(info.szDevice.len());
        let name = String::from_utf16_lossy(&info.szDevice[..end]);
        let r = info.monitorInfo.rcMonitor;
        let (mut dpi_x, mut dpi_y) = (0u32, 0u32);
        GetDpiForMonitor(monitor, MDT_EFFECTIVE_DPI, &mut dpi_x, &mut dpi_y);
        format!(
            "{name} {}x{} at {:+}{:+}, dpi {dpi_x} (scale {}%), primary {}",
            r.right - r.left,
            r.bottom - r.top,
            r.left,
            r.top,
            dpi_x * 100 / 96,
            info.monitorInfo.dwFlags & 1 != 0
        )
    }
}

unsafe extern "system" fn collect_monitor(monitor: HMONITOR, _dc: HDC, _rect: *mut RECT, data: LPARAM) -> i32 {
    let lines = &mut *(data as *mut Vec<String>);
    lines.push(format!("monitor {}", monitor_name(monitor)));
    1
}

pub fn system_details() -> Result<Vec<String>, NativeError> {
    ensure_dpi_aware();
    let mut lines = Vec::new();

    unsafe {
        let awareness = GetAwarenessFromDpiAwarenessContext(GetThreadDpiAwarenessContext());
        lines.push(format!("dpi awareness of this process: {awareness} (2 is per-monitor aware)"));
        lines.push(format!(
            "virtual screen {}x{} at {:+}{:+}",
            GetSystemMetrics(SM_CXVIRTUALSCREEN),
            GetSystemMetrics(SM_CYVIRTUALSCREEN),
            GetSystemMetrics(SM_XVIRTUALSCREEN),
            GetSystemMetrics(SM_YVIRTUALSCREEN)
        ));
        EnumDisplayMonitors(std::ptr::null_mut(), std::ptr::null(), Some(collect_monitor), &mut lines as *mut Vec<String> as LPARAM);

        let mut mouse = [0i32; 3];
        let mut speed = 0i32;
        SystemParametersInfoW(SPI_GETMOUSE, 0, mouse.as_mut_ptr().cast(), 0);
        SystemParametersInfoW(SPI_GETMOUSESPEED, 0, (&mut speed as *mut i32).cast(), 0);
        lines.push(format!(
            "pointer speed {speed} of 20, enhance pointer precision {} (thresholds {},{})",
            if mouse[2] != 0 { "on" } else { "off" },
            mouse[0],
            mouse[1]
        ));

        let mut cursor = POINT { x: 0, y: 0 };
        GetCursorPos(&mut cursor);
        lines.push(format!("cursor at {},{}", cursor.x, cursor.y));

        let foreground = GetForegroundWindow();
        if !foreground.is_null() {
            lines.push(format!(
                "foreground window {:?} ({})",
                window_text(foreground),
                exe_file_name(foreground).unwrap_or_else(|| "unknown process".into())
            ));
        }
    }

    Ok(lines)
}
