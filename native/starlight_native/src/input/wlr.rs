//! Wayland virtual pointer and virtual keyboard input, for compositors that
//! have no RemoteDesktop portal or EIS (Hyprland, Sway, labwc, Wayfire).
//!
//! Absolute pointer coordinates are mapped onto the bounding box of every
//! output's logical rectangle, which is what these compositors expect for
//! `zwlr_virtual_pointer_v1.motion_absolute` without an output argument.

#[cfg(target_os = "linux")]
pub mod linux {
    use std::io::Write;
    use std::os::fd::{AsFd, FromRawFd, OwnedFd};
    use std::sync::{Mutex, OnceLock};
    use std::time::{SystemTime, UNIX_EPOCH};

    use wayland_client::globals::{registry_queue_init, GlobalListContents};
    use wayland_client::protocol::wl_output::WlOutput;
    use wayland_client::protocol::wl_pointer::{Axis, AxisSource, ButtonState};
    use wayland_client::protocol::wl_registry::WlRegistry;
    use wayland_client::protocol::wl_seat::WlSeat;
    use wayland_client::{delegate_noop, Connection, Dispatch, EventQueue, QueueHandle};
    use wayland_protocols::xdg::xdg_output::zv1::client::zxdg_output_manager_v1::ZxdgOutputManagerV1;
    use wayland_protocols::xdg::xdg_output::zv1::client::zxdg_output_v1::{self, ZxdgOutputV1};
    use wayland_protocols_misc::zwp_virtual_keyboard_v1::client::zwp_virtual_keyboard_manager_v1::ZwpVirtualKeyboardManagerV1;
    use wayland_protocols_misc::zwp_virtual_keyboard_v1::client::zwp_virtual_keyboard_v1::ZwpVirtualKeyboardV1;
    use wayland_protocols_wlr::virtual_pointer::v1::client::zwlr_virtual_pointer_manager_v1::ZwlrVirtualPointerManagerV1;
    use wayland_protocols_wlr::virtual_pointer::v1::client::zwlr_virtual_pointer_v1::ZwlrVirtualPointerV1;

    use crate::error::NativeError;

    const BTN_LEFT: u32 = 0x110;
    const BTN_RIGHT: u32 = 0x111;
    const BTN_MIDDLE: u32 = 0x112;
    const WHEEL_CLICK: i32 = 120;
    const PIXELS_PER_CLICK: f64 = 15.0;
    const XKB_KEYMAP_FORMAT_V1: u32 = 1;

    const KEYMAP: &str = "xkb_keymap {
  xkb_keycodes { include \"evdev+aliases(qwerty)\" };
  xkb_types { include \"complete\" };
  xkb_compat { include \"complete\" };
  xkb_symbols { include \"pc+us+inet(evdev)\" };
};
";

    #[derive(Default, Clone, Copy)]
    struct Rect {
        x: i32,
        y: i32,
        w: i32,
        h: i32,
    }

    #[derive(Default)]
    struct State {
        outputs: Vec<Rect>,
    }

    impl State {
        fn bounds(&self) -> Option<Rect> {
            let sized: Vec<&Rect> = self.outputs.iter().filter(|r| r.w > 0 && r.h > 0).collect();
            if sized.is_empty() {
                return None;
            }
            let x0 = sized.iter().map(|r| r.x).min()?;
            let y0 = sized.iter().map(|r| r.y).min()?;
            let x1 = sized.iter().map(|r| r.x + r.w).max()?;
            let y1 = sized.iter().map(|r| r.y + r.h).max()?;
            Some(Rect { x: x0, y: y0, w: x1 - x0, h: y1 - y0 })
        }
    }

    impl Dispatch<WlRegistry, GlobalListContents> for State {
        fn event(
            _: &mut Self,
            _: &WlRegistry,
            _: <WlRegistry as wayland_client::Proxy>::Event,
            _: &GlobalListContents,
            _: &Connection,
            _: &QueueHandle<Self>,
        ) {
        }
    }

    impl Dispatch<ZxdgOutputV1, usize> for State {
        fn event(
            state: &mut Self,
            _: &ZxdgOutputV1,
            event: zxdg_output_v1::Event,
            index: &usize,
            _: &Connection,
            _: &QueueHandle<Self>,
        ) {
            let rect = &mut state.outputs[*index];
            match event {
                zxdg_output_v1::Event::LogicalPosition { x, y } => {
                    rect.x = x;
                    rect.y = y;
                }
                zxdg_output_v1::Event::LogicalSize { width, height } => {
                    rect.w = width;
                    rect.h = height;
                }
                _ => {}
            }
        }
    }

    delegate_noop!(State: ignore WlSeat);
    delegate_noop!(State: ignore WlOutput);
    delegate_noop!(State: ZxdgOutputManagerV1);
    delegate_noop!(State: ZwlrVirtualPointerManagerV1);
    delegate_noop!(State: ZwlrVirtualPointerV1);
    delegate_noop!(State: ZwpVirtualKeyboardManagerV1);
    delegate_noop!(State: ZwpVirtualKeyboardV1);

    struct WlrClient {
        connection: Connection,
        queue: EventQueue<State>,
        state: State,
        pointer: ZwlrVirtualPointerV1,
        keyboard: ZwpVirtualKeyboardV1,
    }

    static CLIENT: OnceLock<Mutex<Option<WlrClient>>> = OnceLock::new();

    fn client() -> &'static Mutex<Option<WlrClient>> {
        CLIENT.get_or_init(|| Mutex::new(None))
    }

    fn connect_failed(what: &str, e: impl std::fmt::Display) -> NativeError {
        NativeError::EisConnectFailed(format!("{what}: {e}"))
    }

    fn now_ms() -> u32 {
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_millis() as u32)
            .unwrap_or(0)
    }

    fn keymap_fd() -> Result<(OwnedFd, u32), NativeError> {
        let raw = unsafe { libc::memfd_create(c"starlight-keymap".as_ptr(), libc::MFD_CLOEXEC) };
        if raw < 0 {
            return Err(NativeError::Io(std::io::Error::last_os_error()));
        }
        let fd = unsafe { OwnedFd::from_raw_fd(raw) };
        let mut file = std::fs::File::from(fd.try_clone()?);
        let mut bytes = KEYMAP.as_bytes().to_vec();
        bytes.push(0);
        file.write_all(&bytes)?;
        Ok((fd, bytes.len() as u32))
    }

    fn connect() -> Result<WlrClient, NativeError> {
        let connection = Connection::connect_to_env().map_err(|e| connect_failed("wayland connect", e))?;
        let (globals, mut queue) =
            registry_queue_init::<State>(&connection).map_err(|e| connect_failed("wayland registry", e))?;
        let qh = queue.handle();
        let mut state = State::default();

        let seat: WlSeat = globals
            .bind(&qh, 1..=1, ())
            .map_err(|e| connect_failed("wl_seat", e))?;
        let pointer_manager: ZwlrVirtualPointerManagerV1 = globals
            .bind(&qh, 1..=2, ())
            .map_err(|e| connect_failed("zwlr_virtual_pointer_manager_v1", e))?;
        let keyboard_manager: ZwpVirtualKeyboardManagerV1 = globals
            .bind(&qh, 1..=1, ())
            .map_err(|e| connect_failed("zwp_virtual_keyboard_manager_v1", e))?;
        let xdg_output_manager: ZxdgOutputManagerV1 = globals
            .bind(&qh, 1..=3, ())
            .map_err(|e| connect_failed("zxdg_output_manager_v1", e))?;

        let output_names: Vec<u32> = globals
            .contents()
            .with_list(|list| list.iter().filter(|g| g.interface == "wl_output").map(|g| g.name).collect());
        let mut _outputs = Vec::new();
        for (index, name) in output_names.into_iter().enumerate() {
            let output: WlOutput = globals.registry().bind(name, 1, &qh, ());
            state.outputs.push(Rect::default());
            _outputs.push(xdg_output_manager.get_xdg_output(&output, &qh, index));
        }

        let pointer = pointer_manager.create_virtual_pointer(Some(&seat), &qh, ());
        let keyboard = keyboard_manager.create_virtual_keyboard(&seat, &qh, ());
        let (fd, size) = keymap_fd()?;
        keyboard.keymap(XKB_KEYMAP_FORMAT_V1, fd.as_fd(), size);

        queue
            .roundtrip(&mut state)
            .map_err(|e| connect_failed("wayland roundtrip", e))?;
        if state.bounds().is_none() {
            return Err(NativeError::EisConnectFailed("compositor reported no output sizes".to_owned()));
        }
        eprintln!("[wlr] virtual pointer and keyboard ready, layout {:?}", state.bounds().map(|b| (b.x, b.y, b.w, b.h)));

        Ok(WlrClient { connection, queue, state, pointer, keyboard })
    }

    pub fn init() -> Result<(), NativeError> {
        *client().lock().unwrap() = Some(connect()?);
        Ok(())
    }

    fn with_client<F>(f: F) -> Result<(), NativeError>
    where
        F: FnOnce(&WlrClient) -> Result<(), NativeError>,
    {
        let mut guard = client().lock().unwrap();
        if guard.is_none() {
            *guard = Some(connect()?);
        }
        let c = guard.as_mut().ok_or(NativeError::NotInitialized)?;

        if let Some(read) = c.connection.prepare_read() {
            let _ = read.read();
        }
        if let Err(e) = c.queue.dispatch_pending(&mut c.state) {
            *guard = None;
            return Err(connect_failed("wayland dispatch", e));
        }

        let result = f(c);
        if let Err(e) = c.connection.flush() {
            *guard = None;
            return Err(connect_failed("wayland flush", e));
        }
        result
    }

    pub fn move_relative(dx: f32, dy: f32) -> Result<(), NativeError> {
        with_client(|c| {
            c.pointer.motion(now_ms(), dx as f64, dy as f64);
            c.pointer.frame();
            Ok(())
        })
    }

    pub fn move_absolute(x: f32, y: f32) -> Result<(), NativeError> {
        with_client(|c| {
            let b = c.state.bounds().ok_or(NativeError::EisNoDevice)?;
            let (lx, ly) = (x as i32 - b.x, y as i32 - b.y);
            if lx < 0 || ly < 0 || lx >= b.w || ly >= b.h {
                return Err(NativeError::EisNoDevice);
            }
            c.pointer.motion_absolute(now_ms(), lx as u32, ly as u32, b.w as u32, b.h as u32);
            c.pointer.frame();
            Ok(())
        })
    }

    pub fn button_event(code: u32, pressed: bool) -> Result<(), NativeError> {
        with_client(|c| {
            let state = if pressed { ButtonState::Pressed } else { ButtonState::Released };
            c.pointer.button(now_ms(), code, state);
            c.pointer.frame();
            Ok(())
        })
    }

    pub fn key_event(keycode: u32, pressed: bool) -> Result<(), NativeError> {
        with_client(|c| {
            c.keyboard.key(now_ms(), keycode, u32::from(pressed));
            Ok(())
        })
    }

    pub fn scroll(dx: i32, dy: i32) -> Result<(), NativeError> {
        with_client(|c| {
            let time = now_ms();
            c.pointer.axis_source(AxisSource::Wheel);
            for (axis, amount) in [(Axis::HorizontalScroll, dx), (Axis::VerticalScroll, dy)] {
                if amount != 0 {
                    let clicks = amount / WHEEL_CLICK;
                    let clicks = if clicks == 0 { amount.signum() } else { clicks };
                    c.pointer.axis_discrete(time, axis, clicks as f64 * PIXELS_PER_CLICK, clicks);
                }
            }
            c.pointer.frame();
            Ok(())
        })
    }

    pub fn release_all(held_keys: &[u32]) -> Result<(), NativeError> {
        with_client(|c| {
            let time = now_ms();
            for button in [BTN_LEFT, BTN_RIGHT, BTN_MIDDLE] {
                c.pointer.button(time, button, ButtonState::Released);
            }
            c.pointer.frame();
            for &key in held_keys {
                c.keyboard.key(time, key, 0);
            }
            Ok(())
        })
    }
}

#[cfg(not(target_os = "linux"))]
pub mod linux {
    use crate::error::NativeError;

    pub fn init() -> Result<(), NativeError> {
        Err(NativeError::NotInitialized)
    }

    pub fn move_absolute(_x: f32, _y: f32) -> Result<(), NativeError> {
        Err(NativeError::NotInitialized)
    }

    pub fn move_relative(_dx: f32, _dy: f32) -> Result<(), NativeError> {
        Err(NativeError::NotInitialized)
    }

    pub fn button_event(_code: u32, _pressed: bool) -> Result<(), NativeError> {
        Err(NativeError::NotInitialized)
    }

    pub fn key_event(_keycode: u32, _pressed: bool) -> Result<(), NativeError> {
        Err(NativeError::NotInitialized)
    }

    pub fn scroll(_dx: i32, _dy: i32) -> Result<(), NativeError> {
        Err(NativeError::NotInitialized)
    }

    pub fn release_all(_held_keys: &[u32]) -> Result<(), NativeError> {
        Err(NativeError::NotInitialized)
    }
}
