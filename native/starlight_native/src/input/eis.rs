//! libei EIS client for Wayland input injection.
//!
//! Connection path (tried in order):
//!   1. LIBEI_SOCKET env var → reis EI handshake directly
//!   2. XDG Remote Desktop portal via ashpd:
//!      CreateSession → SelectDevices → Start → ConnectToEIS

#[cfg(target_os = "linux")]
pub mod linux {
    use std::os::unix::net::UnixStream;
    use std::sync::{Mutex, OnceLock};
    use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

    use reis::ei::{self, button::ButtonState, keyboard::KeyState};
    use reis::enumflags2::BitFlags;
    use reis::event::{Connection, DeviceCapability, EiEvent, EiEventConverter};
    use reis::{PendingRequestResult, handshake};

    use ashpd::desktop::remote_desktop::{
        ConnectToEISOptions, DeviceType, RemoteDesktop, SelectDevicesOptions,
    };
    use ashpd::desktop::{CreateSessionOptions, Session};

    use crate::error::NativeError;

    pub const BTN_LEFT: u32 = 0x110;
    pub const BTN_RIGHT: u32 = 0x111;
    pub const BTN_MIDDLE: u32 = 0x112;

    pub struct EisClient {
        connection: Connection,
        /// Cloned context for draining incoming events (pings etc.) without blocking.
        context: ei::Context,
        proto_device: ei::Device,
        /// Separate device for absolute pointer (may be a different EIS device).
        proto_device_abs: Option<ei::Device>,
        pointer: ei::Pointer,
        pointer_abs: Option<ei::PointerAbsolute>,
        button: ei::Button,
        keyboard: Option<ei::Keyboard>,
        /// Keyboard's own device (may differ from proto_device — KWin can
        /// announce it as a separate EIS device that arrives after the
        /// pointer device). frame() must be called on this one for key
        /// events to actually commit, not on the pointer's device.
        proto_device_kb: Option<ei::Device>,
        scroll: Option<ei::Scroll>,
        /// Scroll's own device — same reasoning as proto_device_kb.
        proto_device_scroll: Option<ei::Device>,
        serial: u32,
        serial_abs: u32,
        serial_kb: u32,
        serial_scroll: u32,
        /// Keeps the portal session alive; closes when EisClient is dropped.
        _session: Option<Session<RemoteDesktop>>,
    }

    // SAFETY: EisClient is only accessed through the Mutex.
    unsafe impl Send for EisClient {}
    unsafe impl Sync for EisClient {}

    static EIS: OnceLock<Mutex<Option<EisClient>>> = OnceLock::new();

    fn eis() -> &'static Mutex<Option<EisClient>> {
        EIS.get_or_init(|| Mutex::new(None))
    }

    fn now_us() -> u64 {
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_micros() as u64
    }

    async fn connect_via_portal() -> Result<(ei::Context, Session<RemoteDesktop>), NativeError> {
        let proxy = RemoteDesktop::new()
            .await
            .map_err(|e| NativeError::EisConnectFailed(format!("portal proxy: {e}")))?;

        let session = proxy
            .create_session(CreateSessionOptions::default())
            .await
            .map_err(|e| NativeError::EisConnectFailed(format!("CreateSession: {e}")))?;

        proxy
            .select_devices(
                &session,
                SelectDevicesOptions::default()
                    .set_devices(DeviceType::Keyboard | DeviceType::Pointer),
            )
            .await
            .map_err(|e| NativeError::EisConnectFailed(format!("SelectDevices: {e}")))?;

        eprintln!("[eis] portal Start — approve the permission dialog if one appears");
        proxy
            .start(&session, None, Default::default())
            .await
            .map_err(|e| NativeError::EisConnectFailed(format!("Start: {e}")))?
            .response()
            .map_err(|e| NativeError::EisConnectFailed(format!("Start denied: {e}")))?;
        eprintln!("[eis] Start approved");

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

    pub fn init_input() -> Result<(), NativeError> {
        let (ctx, mut session) = match reis::ei::Context::connect_to_env() {
            Ok(Some(ctx)) => (ctx, None),
            Ok(None) => {
                let (ctx, s) = futures_lite::future::block_on(connect_via_portal())?;
                (ctx, Some(s))
            }
            Err(e) => return Err(NativeError::EisConnectFailed(e.to_string())),
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

        let mut found_abs: Option<(ei::PointerAbsolute, ei::Device, u32)> = None;
        let mut found_keyboard: Option<(ei::Keyboard, ei::Device, u32)> = None;
        let mut found_scroll: Option<(ei::Scroll, ei::Device, u32)> = None;
        let mut found_pointer: Option<(ei::Pointer, ei::Button, ei::Device, u32)> = None;
        let mut pointer_ready_at: Option<Instant> = None;

        // Multiple interfaces (e.g. scroll and pointer+button, or keyboard and
        // pointer+button) can land on the *same* EIS device/serial. It's a
        // protocol violation to call start_emulating twice on one device
        // without an intermediate stop_emulating — KWin disconnects the
        // client's other requests after that (this bit us for scroll, which
        // shares a device with the relative pointer). Track which serials
        // we've already started to guard every capture block below.
        let mut emulating_serials: std::collections::HashSet<u32> = std::collections::HashSet::new();

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
                            "[eis] device offers: pointer={} button={} pointer_abs={} keyboard={} scroll={}",
                            r.device.interface::<ei::Pointer>().is_some(),
                            r.device.interface::<ei::Button>().is_some(),
                            r.device.interface::<ei::PointerAbsolute>().is_some(),
                            r.device.interface::<ei::Keyboard>().is_some(),
                            r.device.interface::<ei::Scroll>().is_some(),
                        );
                        let serial = r.serial;

                        // Capture absolute pointer from whichever device offers it.
                        if found_abs.is_none() {
                            if let Some(pa) = r.device.interface::<ei::PointerAbsolute>() {
                                let pd = r.device.device().clone();
                                if emulating_serials.insert(serial) {
                                    pd.start_emulating(serial, 1);
                                    let _ = connection.flush();
                                }
                                eprintln!("[eis] absolute pointer device acquired (serial={})", serial);
                                found_abs = Some((pa, pd, serial));
                            }
                        }

                        // Capture keyboard from whichever device offers it — may be
                        // the same device as pointer+button, or its own device.
                        if found_keyboard.is_none() {
                            if let Some(kb) = r.device.interface::<ei::Keyboard>() {
                                let kd = r.device.device().clone();
                                if emulating_serials.insert(serial) {
                                    kd.start_emulating(serial, 1);
                                    let _ = connection.flush();
                                }
                                eprintln!("[eis] keyboard device acquired (serial={})", serial);
                                found_keyboard = Some((kb, kd, serial));
                            }
                        }

                        // Capture scroll from whichever device offers it — in
                        // practice it's shown up bundled with the relative
                        // pointer device, but treat it as independently
                        // opportunistic like keyboard in case that's not always so.
                        if found_scroll.is_none() {
                            if let Some(sc) = r.device.interface::<ei::Scroll>() {
                                let sd = r.device.device().clone();
                                if emulating_serials.insert(serial) {
                                    sd.start_emulating(serial, 1);
                                    let _ = connection.flush();
                                }
                                eprintln!("[eis] scroll device acquired (serial={})", serial);
                                found_scroll = Some((sc, sd, serial));
                            }
                        }

                        // Record the relative pointer device (needs Pointer + Button)
                        // but don't break yet — give a straggling keyboard device
                        // the grace period below to still show up.
                        if found_pointer.is_none() {
                            if let (Some(pointer), Some(button)) = (
                                r.device.interface::<ei::Pointer>(),
                                r.device.interface::<ei::Button>(),
                            ) {
                                let proto_device = r.device.device().clone();
                                if emulating_serials.insert(serial) {
                                    proto_device.start_emulating(serial, 1);
                                    let _ = connection.flush();
                                }
                                found_pointer = Some((pointer, button, proto_device, serial));
                                pointer_ready_at = Some(Instant::now());
                            }
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
                    let (pointer, button, proto_device, serial) = found_pointer.take().unwrap();

                    let (pointer_abs, proto_device_abs, serial_abs) = match found_abs.take() {
                        Some((pa, pd, s)) => (Some(pa), Some(pd), s),
                        None => (None, None, 0),
                    };

                    let (keyboard, proto_device_kb, serial_kb) = match found_keyboard.take() {
                        Some((kb, kd, s)) => (Some(kb), Some(kd), s),
                        None => (None, None, 0),
                    };

                    let (scroll, proto_device_scroll, serial_scroll) = match found_scroll.take() {
                        Some((sc, sd, s)) => (Some(sc), Some(sd), s),
                        None => (None, None, 0),
                    };

                    eprintln!("[eis] absolute pointer: {}", pointer_abs.is_some());
                    eprintln!("[eis] keyboard: {}", keyboard.is_some());
                    eprintln!("[eis] scroll: {}", scroll.is_some());

                    break 'outer EisClient {
                        connection: connection.clone(),
                        context: ctx_clone,
                        proto_device,
                        proto_device_abs,
                        pointer,
                        pointer_abs,
                        button,
                        keyboard,
                        proto_device_kb,
                        scroll,
                        proto_device_scroll,
                        serial,
                        serial_abs,
                        serial_kb,
                        serial_scroll,
                        _session: session.take(),
                    };
                }
            }

            std::thread::sleep(Duration::from_millis(10));
        };

        *eis().lock().unwrap() = Some(client);
        Ok(())
    }

    fn with_client<F, T>(f: F) -> Result<T, NativeError>
    where
        F: FnOnce(&EisClient) -> Result<T, NativeError>,
    {
        let guard = eis().lock().unwrap();
        let client = guard.as_ref().ok_or(NativeError::NotInitialized)?;
        // Drain any incoming events (compositor pings etc.) without blocking.
        let _ = client.context.read();
        while client.context.pending_event().is_some() {}
        f(client)
    }

    pub fn move_absolute(x: f32, y: f32) -> Result<(), NativeError> {
        with_client(|c| {
            let pa = c.pointer_abs.as_ref().ok_or(NativeError::EisNoDevice)?;
            let pd = c.proto_device_abs.as_ref().ok_or(NativeError::EisNoDevice)?;
            pa.motion_absolute(x, y);
            pd.frame(c.serial_abs, now_us());
            c.connection
                .flush()
                .map_err(|e| NativeError::EisConnectFailed(e.to_string()))
        })
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
            let sc_device = c.proto_device_scroll.as_ref().ok_or(NativeError::EisNoDevice)?;
            sc.scroll_discrete(dx, dy);
            sc_device.frame(c.serial_scroll, now_us());
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

    pub fn init_input() -> Result<(), NativeError> {
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
