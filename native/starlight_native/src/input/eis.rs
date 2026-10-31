//! libei EIS client for Wayland input injection.
//!
//! Connection path, chosen by where `capture::x11::locate` last found the game:
//!   - Nested display (not the host `$DISPLAY`): the nested KWin's
//!     `org.kde.KWin.EIS.RemoteDesktop.connectToEIS` over the bus at
//!     `$XDG_RUNTIME_DIR/starlight-nested/bus`. The bus connection is held for
//!     the client's lifetime, since KWin drops the EIS context when it closes.
//!   - Host display, tried in order:
//!       1. LIBEI_SOCKET env var → reis EI handshake directly
//!       2. XDG Remote Desktop portal via ashpd:
//!          CreateSession → SelectDevices → Start → ConnectToEIS
//!
//! `with_client` reconnects when the game's display changes.

#[cfg(target_os = "linux")]
pub mod linux {
    use std::os::unix::net::UnixStream;
    use std::sync::{Mutex, OnceLock};
    use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

    use reis::ei::{self, button::ButtonState, keyboard::KeyState};
    use reis::enumflags2::BitFlags;
    use reis::event::{Connection, DeviceCapability, DeviceResumed, EiEvent, EiEventConverter};
    use reis::{PendingRequestResult, handshake};

    use ashpd::desktop::remote_desktop::{
        ConnectToEISOptions, DeviceType, RemoteDesktop, SelectDevicesOptions,
    };
    use ashpd::desktop::{CreateSessionOptions, PersistMode, Session};

    use crate::error::NativeError;

    pub const BTN_LEFT: u32 = 0x110;
    pub const BTN_RIGHT: u32 = 0x111;
    pub const BTN_MIDDLE: u32 = 0x112;

    pub struct EisClient {
        connection: Connection,
        /// Cloned context for draining incoming events (pings etc.) without blocking.
        context: ei::Context,
        proto_device: ei::Device,
        pointer: ei::Pointer,
        button: ei::Button,
        keyboard: Option<ei::Keyboard>,
        /// Keyboard's own device (may differ from proto_device — KWin can
        /// announce it as a separate EIS device that arrives after the
        /// pointer device). frame() must be called on this one for key
        /// events to actually commit, not on the pointer's device.
        proto_device_kb: Option<ei::Device>,
        scroll: Option<ei::Scroll>,
        absolute: Option<AbsoluteHandles>,
        serial: u32,
        serial_kb: u32,
        converter: EiEventConverter,
        dead: bool,
        /// Keeps the portal session alive; closes when EisClient is dropped.
        _session: Option<Session<RemoteDesktop>>,
        _kwin_bus: Option<zbus::Connection>,
        display: Option<String>,
    }

    // SAFETY: EisClient is only accessed through the Mutex.
    unsafe impl Send for EisClient {}
    unsafe impl Sync for EisClient {}

    static EIS: OnceLock<Mutex<Option<EisClient>>> = OnceLock::new();
    static TOKEN_PATH: Mutex<Option<std::path::PathBuf>> = Mutex::new(None);

    fn read_restore_token() -> Option<String> {
        let path = TOKEN_PATH.lock().unwrap().clone()?;
        let token = std::fs::read_to_string(path).ok()?;
        let token = token.trim();
        (!token.is_empty()).then(|| token.to_owned())
    }

    fn write_restore_token(token: &str) {
        use std::os::unix::fs::PermissionsExt;
        let Some(path) = TOKEN_PATH.lock().unwrap().clone() else {
            return;
        };
        if let Some(dir) = path.parent() {
            let _ = std::fs::create_dir_all(dir);
        }
        match std::fs::write(&path, token)
            .and_then(|_| std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)))
        {
            Ok(()) => eprintln!("[eis] saved portal restore token to {}", path.display()),
            Err(e) => eprintln!("[eis] could not save portal restore token: {e}"),
        }
    }

    fn eis() -> &'static Mutex<Option<EisClient>> {
        EIS.get_or_init(|| Mutex::new(None))
    }

    fn now_us() -> u64 {
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_micros() as u64
    }

    type PointerHandles = (ei::Pointer, ei::Button, Option<ei::Scroll>, ei::Device, u32);
    type KeyboardHandles = (ei::Keyboard, ei::Device, u32);
    type AbsoluteHandles = (ei::PointerAbsolute, ei::Device, u32, Vec<(f32, f32, f32, f32)>);

    fn acquire_absolute(resumed: &DeviceResumed, connection: &Connection) -> Option<AbsoluteHandles> {
        let absolute = resumed.device.interface::<ei::PointerAbsolute>()?;
        let device = resumed.device.device();
        device.start_emulating(resumed.serial, 1);
        let _ = connection.flush();
        let regions = resumed
            .device
            .regions()
            .iter()
            .map(|r| (r.x as f32, r.y as f32, r.width as f32, r.height as f32))
            .collect();
        Some((absolute, device.clone(), resumed.serial, regions))
    }

    fn acquire(
        resumed: &DeviceResumed,
        connection: &Connection,
    ) -> (Option<PointerHandles>, Option<KeyboardHandles>) {
        let device = resumed.device.device();
        let pointer = match (
            resumed.device.interface::<ei::Pointer>(),
            resumed.device.interface::<ei::Button>(),
        ) {
            (Some(pointer), Some(button)) => Some((
                pointer,
                button,
                resumed.device.interface::<ei::Scroll>(),
                device.clone(),
                resumed.serial,
            )),
            _ => None,
        };
        let keyboard = resumed
            .device
            .interface::<ei::Keyboard>()
            .map(|kb| (kb, device.clone(), resumed.serial));
        if pointer.is_some() || keyboard.is_some() {
            device.start_emulating(resumed.serial, 1);
            let _ = connection.flush();
        }
        (pointer, keyboard)
    }

    impl EisClient {
        fn refresh_devices(&mut self) {
            if let Err(e) = self.context.read() {
                if e.kind() == std::io::ErrorKind::UnexpectedEof {
                    self.dead = true;
                }
            }
            while let Some(result) = self.context.pending_event() {
                if let PendingRequestResult::Request(request) = result {
                    let _ = self.converter.handle_event(request);
                }
            }
            while let Some(ev) = self.converter.next_event() {
                match ev {
                    EiEvent::DeviceRemoved(r) => {
                        eprintln!("[eis] DeviceRemoved: name={:?}, reconnecting", r.device.name());
                        self.dead = true;
                    }
                    EiEvent::DeviceResumed(r) => {
                        eprintln!(
                            "[eis] DeviceResumed: name={:?} serial={}",
                            r.device.name(),
                            r.serial
                        );
                        let (pointer, keyboard) = acquire(&r, &self.connection);
                        if let Some(absolute) = acquire_absolute(&r, &self.connection) {
                            self.absolute = Some(absolute);
                        }
                        if let Some((pointer, button, scroll, device, serial)) = pointer {
                            self.pointer = pointer;
                            self.button = button;
                            self.scroll = scroll;
                            self.proto_device = device;
                            self.serial = serial;
                        }
                        if let Some((kb, device, serial)) = keyboard {
                            self.keyboard = Some(kb);
                            self.proto_device_kb = Some(device);
                            self.serial_kb = serial;
                        }
                    }
                    EiEvent::Disconnected(d) => {
                        eprintln!("[eis] Disconnected: reason={:?}", d.reason);
                        self.dead = true;
                    }
                    other => {
                        eprintln!("[eis] unhandled event: {other:?}");
                    }
                }
            }
            let _ = self.connection.flush();
        }
    }

    async fn connect_via_portal() -> Result<(ei::Context, Session<RemoteDesktop>), NativeError> {
        let proxy = RemoteDesktop::new()
            .await
            .map_err(|e| NativeError::EisConnectFailed(format!("portal proxy: {e}")))?;

        let session = proxy
            .create_session(CreateSessionOptions::default())
            .await
            .map_err(|e| NativeError::EisConnectFailed(format!("CreateSession: {e}")))?;

        let saved_token = read_restore_token();
        eprintln!(
            "[eis] portal restore token: {}",
            if saved_token.is_some() { "found" } else { "none" }
        );

        proxy
            .select_devices(
                &session,
                SelectDevicesOptions::default()
                    .set_devices(DeviceType::Keyboard | DeviceType::Pointer)
                    .set_persist_mode(PersistMode::ExplicitlyRevoked)
                    .set_restore_token(saved_token.as_deref()),
            )
            .await
            .map_err(|e| NativeError::EisConnectFailed(format!("SelectDevices: {e}")))?;

        eprintln!("[eis] portal Start — approve the permission dialog if one appears");
        let selected = proxy
            .start(&session, None, Default::default())
            .await
            .map_err(|e| NativeError::EisConnectFailed(format!("Start: {e}")))?
            .response()
            .map_err(|e| NativeError::EisConnectFailed(format!("Start denied: {e}")))?;
        eprintln!("[eis] Start approved");

        if let Some(token) = selected.restore_token() {
            if saved_token.as_deref() != Some(token) {
                write_restore_token(token);
            }
        }

        eprintln!("[eis] calling ConnectToEIS");
        let fd = proxy
            .connect_to_eis(&session, ConnectToEISOptions::default())
            .await
            .map_err(|e| NativeError::EisConnectFailed(format!("ConnectToEIS: {e}")))?;
        eprintln!("[eis] ConnectToEIS returned fd");

        let socket = UnixStream::from(fd);
        let ctx = ei::Context::new(socket)
            .map_err(|e| NativeError::EisConnectFailed(format!("EIS context: {e}")))?;

        Ok((ctx, session))
    }

    fn nested_bus_address() -> Result<String, NativeError> {
        let runtime = std::env::var("XDG_RUNTIME_DIR")
            .map_err(|_| NativeError::EisConnectFailed("XDG_RUNTIME_DIR not set".to_string()))?;
        Ok(format!("unix:path={runtime}/starlight-nested/bus"))
    }

    async fn connect_via_kwin_dbus(address: &str) -> Result<(ei::Context, zbus::Connection), NativeError> {
        const KEYBOARD_AND_POINTER: i32 = 1 | 2;

        let bus = zbus::connection::Builder::address(address)
            .map_err(|e| NativeError::EisConnectFailed(format!("bus address {address}: {e}")))?
            .build()
            .await
            .map_err(|e| NativeError::EisConnectFailed(format!("bus {address}: {e}")))?;

        let reply = bus
            .call_method(
                Some("org.kde.KWin"),
                "/org/kde/KWin/EIS/RemoteDesktop",
                Some("org.kde.KWin.EIS.RemoteDesktop"),
                "connectToEIS",
                &KEYBOARD_AND_POINTER,
            )
            .await
            .map_err(|e| NativeError::EisConnectFailed(format!("KWin connectToEIS: {e}")))?;

        let (fd, _cookie): (zbus::zvariant::OwnedFd, i32) = reply
            .body()
            .deserialize()
            .map_err(|e| NativeError::EisConnectFailed(format!("KWin connectToEIS reply: {e}")))?;
        eprintln!("[eis] KWin connectToEIS returned fd");

        let socket = UnixStream::from(std::os::fd::OwnedFd::from(fd));
        let ctx = ei::Context::new(socket)
            .map_err(|e| NativeError::EisConnectFailed(format!("EIS context: {e}")))?;

        Ok((ctx, bus))
    }

    pub fn init_input(window_title: &str, token_path: &str) -> Result<(), NativeError> {
        *TOKEN_PATH.lock().unwrap() = Some(std::path::PathBuf::from(token_path));
        let _ = crate::capture::x11::locate(window_title);
        let client = connect(crate::capture::nested_display_name())?;
        *eis().lock().unwrap() = Some(client);
        Ok(())
    }

    fn connect(mut display: Option<String>) -> Result<EisClient, NativeError> {
        let (ctx, mut session, mut kwin_bus) = match &display {
            Some(name) => {
                eprintln!("[eis] game is on nested display {name}, connecting to its KWin");
                let address = nested_bus_address()?;
                let (ctx, bus) = futures_lite::future::block_on(connect_via_kwin_dbus(&address))?;
                (ctx, None, Some(bus))
            }
            None => match reis::ei::Context::connect_to_env() {
                Ok(Some(ctx)) => (ctx, None, None),
                Ok(None) => {
                    let (ctx, s) = futures_lite::future::block_on(connect_via_portal())?;
                    (ctx, Some(s), None)
                }
                Err(e) => return Err(NativeError::EisConnectFailed(e.to_string())),
            },
        };

        let ctx_clone = ctx.clone();

        eprintln!("[eis] starting EIS handshake");
        let resp =
            handshake::ei_handshake_blocking(&ctx, "starlight", ei::handshake::ContextType::Sender)
                .map_err(|e| NativeError::EisHandshakeFailed(e.to_string()))?;
        eprintln!("[eis] handshake complete, polling for seat/device events");

        let mut converter = EiEventConverter::new(&ctx, resp);
        let connection = converter.connection().clone();
        let _ = connection.flush();

        let deadline = Instant::now() + Duration::from_secs(15);

        // KWin announces device capabilities as separate EIS devices that can
        // arrive at different times, not all at once. We used to break out of
        // discovery the instant we saw Pointer+Button, which meant a keyboard
        // device announced even slightly later (a very common ordering) was
        // never seen — key_event silently had no device to send to. Now we
        // hold off breaking for a short grace period after the pointer is
        // ready, to give a straggling keyboard device a chance to arrive.
        const KEYBOARD_GRACE: Duration = Duration::from_millis(750);

        let mut found_keyboard: Option<KeyboardHandles> = None;
        let mut found_pointer: Option<PointerHandles> = None;
        let mut found_absolute: Option<AbsoluteHandles> = None;
        let mut pointer_ready_at: Option<Instant> = None;

        let client: EisClient = 'outer: loop {
            if Instant::now() > deadline {
                return Err(NativeError::EisConnectFailed(
                    "timed out waiting for EIS seat/device events (15 s)".to_owned(),
                ));
            }

            // Non-blocking read: pull whatever the compositor has written.
            match ctx.read() {
                Ok(_) => {}
                Err(e) if e.kind() == std::io::ErrorKind::UnexpectedEof => {
                    return Err(NativeError::EisConnectFailed(
                        "EIS socket closed during setup".to_owned(),
                    ));
                }
                Err(_) => {}
            }

            // Parse raw bytes into high-level converter (handles pings automatically).
            while let Some(result) = ctx.pending_event() {
                let request = match result {
                    PendingRequestResult::Request(r) => r,
                    _ => continue,
                };
                let _ = converter.handle_event(request);
            }
            let _ = connection.flush();

            // Dispatch high-level events.
            while let Some(ev) = converter.next_event() {
                eprintln!("[eis] event: {:?}", ev);
                match ev {
                    EiEvent::SeatAdded(seat_added) => {
                        eprintln!("[eis] SeatAdded: {:?}", seat_added.seat.name());
                        seat_added
                            .seat
                            .bind_capabilities(BitFlags::<DeviceCapability>::all());
                        let _ = connection.flush();
                    }
                    EiEvent::DeviceAdded(ref r) => {
                        eprintln!(
                            "[eis] DeviceAdded: name={:?} type={:?}",
                            r.device.name(),
                            r.device.device_type()
                        );
                    }
                    EiEvent::DeviceResumed(r) => {
                        eprintln!("[eis] DeviceResumed serial={}", r.serial);
                        eprintln!(
                            "[eis] device offers: pointer={} button={} keyboard={} scroll={}",
                            r.device.interface::<ei::Pointer>().is_some(),
                            r.device.interface::<ei::Button>().is_some(),
                            r.device.interface::<ei::Keyboard>().is_some(),
                            r.device.interface::<ei::Scroll>().is_some(),
                        );
                        let (pointer, keyboard) = acquire(&r, &connection);
                        if let Some(absolute) = acquire_absolute(&r, &connection) {
                            found_absolute = Some(absolute);
                        }
                        if found_keyboard.is_none() && keyboard.is_some() {
                            eprintln!("[eis] keyboard device acquired (serial={})", r.serial);
                            found_keyboard = keyboard;
                        }
                        if found_pointer.is_none() && pointer.is_some() {
                            found_pointer = pointer;
                            pointer_ready_at = Some(Instant::now());
                        }
                    }
                    EiEvent::Disconnected(ref d) => {
                        eprintln!("[eis] Disconnected: reason={:?}", d.reason);
                        return Err(NativeError::EisConnectFailed(format!(
                            "disconnected during EIS setup: reason={:?}",
                            d.reason
                        )));
                    }
                    _ => {}
                }
            }

            // Finalize once the pointer is ready and either a keyboard device
            // has shown up or we've given it a fair chance to.
            if let Some(ready_at) = pointer_ready_at {
                if found_keyboard.is_some() || ready_at.elapsed() > KEYBOARD_GRACE {
                    let (pointer, button, scroll, proto_device, serial) = found_pointer.take().unwrap();

                    let (keyboard, proto_device_kb, serial_kb) = match found_keyboard.take() {
                        Some((kb, kd, s)) => (Some(kb), Some(kd), s),
                        None => (None, None, 0),
                    };

                    eprintln!("[eis] keyboard: {}", keyboard.is_some());
                    eprintln!("[eis] scroll: {}", scroll.is_some());

                    break 'outer EisClient {
                        connection: connection.clone(),
                        context: ctx_clone,
                        proto_device,
                        pointer,
                        button,
                        keyboard,
                        proto_device_kb,
                        scroll,
                        absolute: found_absolute.take(),
                        serial,
                        serial_kb,
                        converter,
                        dead: false,
                        _session: session.take(),
                        _kwin_bus: kwin_bus.take(),
                        display: display.take(),
                    };
                }
            }

            std::thread::sleep(Duration::from_millis(10));
        };

        Ok(client)
    }

    fn with_client<F, T>(f: F) -> Result<T, NativeError>
    where
        F: FnOnce(&EisClient) -> Result<T, NativeError>,
    {
        let mut guard = eis().lock().unwrap();
        let nested = crate::capture::nested_display_name();
        let stale = match guard.as_mut() {
            Some(c) => {
                c.refresh_devices();
                c.dead || c.display != nested
            }
            None => nested.is_some(),
        };
        if stale {
            eprintln!("[eis] connection lost or game display is now {nested:?}, reconnecting");
            *guard = None;
            *guard = Some(connect(nested)?);
        }
        let client = guard.as_mut().ok_or(NativeError::NotInitialized)?;
        let result = f(client);
        if matches!(result, Err(NativeError::EisConnectFailed(_))) {
            client.dead = true;
        }
        result
    }

    pub fn move_relative(dx: f32, dy: f32) -> Result<(), NativeError> {
        with_client(|c| {
            c.pointer.motion_relative(dx, dy);
            c.proto_device.frame(c.serial, now_us());
            c.connection
                .flush()
                .map_err(|e| NativeError::EisConnectFailed(e.to_string()))
        })
    }

    pub fn move_absolute(x: f32, y: f32) -> Result<(), NativeError> {
        with_client(|c| {
            let (absolute, device, serial, regions) = c.absolute.as_ref().ok_or(NativeError::EisNoDevice)?;
            let inside = regions
                .iter()
                .any(|&(rx, ry, rw, rh)| x >= rx && y >= ry && x < rx + rw && y < ry + rh);
            if !inside {
                return Err(NativeError::EisNoDevice);
            }
            absolute.motion_absolute(x, y);
            device.frame(*serial, now_us());
            c.connection
                .flush()
                .map_err(|e| NativeError::EisConnectFailed(e.to_string()))
        })
    }

    pub fn button_event(code: u32, pressed: bool) -> Result<(), NativeError> {
        with_client(|c| {
            let state = if pressed {
                ButtonState::Press
            } else {
                ButtonState::Released
            };
            c.button.button(code, state);
            c.proto_device.frame(c.serial, now_us());
            c.connection
                .flush()
                .map_err(|e| NativeError::EisConnectFailed(e.to_string()))
        })
    }

    pub fn key_event(keycode: u32, pressed: bool) -> Result<(), NativeError> {
        with_client(|c| {
            let kb = c.keyboard.as_ref().ok_or(NativeError::EisNoDevice)?;
            // Keyboard may be its own EIS device, separate from the pointer's —
            // frame() must go to whichever device the key request was sent on,
            // or the compositor never commits it.
            let kb_device = c.proto_device_kb.as_ref().ok_or(NativeError::EisNoDevice)?;
            let state = if pressed {
                KeyState::Press
            } else {
                KeyState::Released
            };
            kb.key(keycode, state);
            kb_device.frame(c.serial_kb, now_us());
            c.connection
                .flush()
                .map_err(|e| NativeError::EisConnectFailed(e.to_string()))
        })
    }

    /// Discrete (wheel-click) scroll. dx/dy are in units of 120 per the EIS
    /// protocol's ei_scroll.scroll_discrete convention (one wheel click = 120).
    /// Positive dy scrolls down, positive dx scrolls right.
    pub fn scroll(dx: i32, dy: i32) -> Result<(), NativeError> {
        with_client(|c| {
            let sc = c.scroll.as_ref().ok_or(NativeError::EisNoDevice)?;
            sc.scroll_discrete(dx, dy);
            c.proto_device.frame(c.serial, now_us());
            c.connection
                .flush()
                .map_err(|e| NativeError::EisConnectFailed(e.to_string()))
        })
    }

    pub fn release_all(held_keys: &[u32]) -> Result<(), NativeError> {
        with_client(|c| {
            for btn in [BTN_LEFT, BTN_RIGHT, BTN_MIDDLE] {
                c.button.button(btn, ButtonState::Released);
            }
            c.proto_device.frame(c.serial, now_us());

            if let (Some(kb), Some(kb_device)) = (&c.keyboard, &c.proto_device_kb) {
                for &key in held_keys {
                    kb.key(key, KeyState::Released);
                }
                kb_device.frame(c.serial_kb, now_us());
            }

            c.connection
                .flush()
                .map_err(|e| NativeError::EisConnectFailed(e.to_string()))
        })
    }
}

#[cfg(not(target_os = "linux"))]
pub mod linux {
    use crate::error::NativeError;

    pub fn init_input(_window_title: &str, _token_path: &str) -> Result<(), NativeError> {
        Err(NativeError::EisNotAvailable)
    }
    pub fn move_absolute(_x: f32, _y: f32) -> Result<(), NativeError> {
        Err(NativeError::EisNotAvailable)
    }

    pub fn move_relative(_dx: f32, _dy: f32) -> Result<(), NativeError> {
        Err(NativeError::EisNotAvailable)
    }
    pub fn button_event(_code: u32, _pressed: bool) -> Result<(), NativeError> {
        Err(NativeError::EisNotAvailable)
    }
    pub fn key_event(_keycode: u32, _pressed: bool) -> Result<(), NativeError> {
        Err(NativeError::EisNotAvailable)
    }
    pub fn scroll(_dx: i32, _dy: i32) -> Result<(), NativeError> {
        Err(NativeError::EisNotAvailable)
    }
    pub fn release_all(_held_keys: &[u32]) -> Result<(), NativeError> {
        Err(NativeError::EisNotAvailable)
    }
}
