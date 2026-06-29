//! KWin cursor-position query over D-Bus.
//!
//! Wayland gives compositor clients no way to read the global pointer position
//! directly — that privacy boundary exists in the portal APIs too (RemoteDesktop
//! is input-only, no readback). KWin's scripting engine is a privileged escape
//! hatch: `workspace.cursorPos` is only visible from inside a loaded KWin script,
//! so we generate one, load it via `org.kde.kwin.Scripting`, and have it call
//! back into a D-Bus service we host here. This is the same technique `kdotool`
//! and `wdotool`'s KDE backend use for `getmouselocation`.
//!
//! Only called once per mouse move (to seed trajectory start), not per frame —
//! callers should not poll this in a loop.

#[cfg(target_os = "linux")]
pub mod linux {
    use std::collections::HashMap;
    use std::io::Write;
    use std::sync::atomic::{AtomicI32, Ordering};
    use std::sync::{mpsc, Arc, Mutex, OnceLock};
    use std::time::Duration;

    use zbus::{interface, proxy, Connection};

    use crate::error::NativeError;

    const BRIDGE_PATH: &str = "/com/starlightbot/CursorBridge";
    const BRIDGE_IFACE: &str = "com.starlightbot.CursorBridge";
    const CALLBACK_TIMEOUT: Duration = Duration::from_millis(800);

    type PendingMap = Arc<Mutex<HashMap<i32, mpsc::Sender<Option<(i32, i32)>>>>>;

    struct CursorClient {
        conn: Connection,
        bridge_addr: String,
        pending: PendingMap,
        next_id: AtomicI32,
    }

    unsafe impl Send for CursorClient {}
    unsafe impl Sync for CursorClient {}

    static CLIENT: OnceLock<Mutex<Option<CursorClient>>> = OnceLock::new();

    fn client_cell() -> &'static Mutex<Option<CursorClient>> {
        CLIENT.get_or_init(|| Mutex::new(None))
    }

    struct Bridge {
        pending: PendingMap,
    }

    #[interface(name = "com.starlightbot.CursorBridge")]
    impl Bridge {
        async fn report_pointer(&self, req_id: i32, ok: bool, x: i32, y: i32) {
            if let Some(tx) = self.pending.lock().unwrap().remove(&req_id) {
                let _ = tx.send(if ok { Some((x, y)) } else { None });
            }
        }
    }

    #[proxy(
        interface = "org.kde.kwin.Scripting",
        default_service = "org.kde.KWin",
        default_path = "/Scripting"
    )]
    trait KwinScripting {
        #[zbus(name = "loadScript")]
        fn load_script(&self, file_path: &str, plugin_name: &str) -> zbus::Result<i32>;
        #[zbus(name = "unloadScript")]
        fn unload_script(&self, plugin_name: &str) -> zbus::Result<bool>;
    }

    #[proxy(interface = "org.kde.kwin.Script", default_service = "org.kde.KWin")]
    trait KwinScript {
        #[zbus(name = "run")]
        fn run(&self) -> zbus::Result<()>;
    }

    fn dbus_err(e: zbus::Error) -> NativeError {
        NativeError::CursorQueryFailed(e.to_string())
    }

    fn ensure_connected() -> Result<(), NativeError> {
        let mut guard = client_cell().lock().unwrap();
        if guard.is_some() {
            return Ok(());
        }

        let pending: PendingMap = Arc::new(Mutex::new(HashMap::new()));
        let pending_for_bridge = pending.clone();

        let conn = futures_lite::future::block_on(async {
            let conn = Connection::session().await.map_err(dbus_err)?;
            conn.object_server()
                .at(
                    BRIDGE_PATH,
                    Bridge {
                        pending: pending_for_bridge,
                    },
                )
                .await
                .map_err(dbus_err)?;
            Ok::<Connection, NativeError>(conn)
        })?;

        let bridge_addr = conn
            .unique_name()
            .ok_or_else(|| {
                NativeError::CursorQueryFailed("session bus assigned no unique name".into())
            })?
            .to_string();

        *guard = Some(CursorClient {
            conn,
            bridge_addr,
            pending,
            next_id: AtomicI32::new(1),
        });
        Ok(())
    }

    fn pointer_position_script(req_id: i32, bridge_addr: &str) -> String {
        format!(
            r#"(function() {{
  var p = workspace.cursorPos;
  var ok = (p && typeof p.x === "number" && typeof p.y === "number");
  callDBus(
    "{addr}", "{path}", "{iface}", "ReportPointer",
    {id}, ok, ok ? (p.x | 0) : 0, ok ? (p.y | 0) : 0
  );
}})();
"#,
            addr = bridge_addr,
            path = BRIDGE_PATH,
            iface = BRIDGE_IFACE,
            id = req_id,
        )
    }

    async fn run_kwin_script(
        conn: &Connection,
        path: &str,
        plugin_name: &str,
    ) -> Result<(), NativeError> {
        let scripting = KwinScriptingProxy::new(conn).await.map_err(dbus_err)?;
        let script_id = scripting
            .load_script(path, plugin_name)
            .await
            .map_err(dbus_err)?;
        if script_id < 0 {
            return Err(NativeError::CursorQueryFailed(format!(
                "loadScript returned {script_id}"
            )));
        }

        let script_proxy = KwinScriptProxy::builder(conn)
            .path(format!("/Scripting/Script{script_id}"))
            .map_err(dbus_err)?
            .build()
            .await
            .map_err(dbus_err)?;
        script_proxy.run().await.map_err(dbus_err)
    }

    async fn unload_kwin_script(conn: &Connection, plugin_name: &str) {
        if let Ok(scripting) = KwinScriptingProxy::new(conn).await {
            let _ = scripting.unload_script(plugin_name).await;
        }
    }

    pub fn get_cursor_pos() -> Result<(i32, i32), NativeError> {
        ensure_connected()?;

        let guard = client_cell().lock().unwrap();
        let client = guard.as_ref().ok_or(NativeError::NotInitialized)?;

        let req_id = client.next_id.fetch_add(1, Ordering::Relaxed);
        let (tx, rx) = mpsc::channel();
        client.pending.lock().unwrap().insert(req_id, tx);

        let plugin_name = format!("starlight-cursor-{}-{}", std::process::id(), req_id);
        let script = pointer_position_script(req_id, &client.bridge_addr);

        let mut tmp = tempfile::Builder::new()
            .prefix("starlight-cursor-")
            .suffix(".js")
            .tempfile()
            .map_err(NativeError::Io)?;
        tmp.write_all(script.as_bytes()).map_err(NativeError::Io)?;
        tmp.flush().map_err(NativeError::Io)?;
        let path = tmp.into_temp_path();
        let path_str = path.to_str().ok_or_else(|| {
            NativeError::CursorQueryFailed("temp script path is not valid UTF-8".into())
        })?;

        let run_result =
            futures_lite::future::block_on(run_kwin_script(&client.conn, path_str, &plugin_name));

        let recv_result = if run_result.is_ok() {
            rx.recv_timeout(CALLBACK_TIMEOUT)
        } else {
            Err(mpsc::RecvTimeoutError::Disconnected)
        };

        client.pending.lock().unwrap().remove(&req_id);
        futures_lite::future::block_on(unload_kwin_script(&client.conn, &plugin_name));
        drop(path); // removes the temp file

        run_result?;

        match recv_result {
            Ok(Some((x, y))) => Ok((x, y)),
            Ok(None) => Err(NativeError::CursorQueryFailed(
                "workspace.cursorPos unavailable in this session".into(),
            )),
            Err(_) => Err(NativeError::CursorQueryFailed(
                "timed out waiting for KWin cursor callback".into(),
            )),
        }
    }
}

#[cfg(not(target_os = "linux"))]
pub mod linux {
    use crate::error::NativeError;

    pub fn get_cursor_pos() -> Result<(i32, i32), NativeError> {
        Err(NativeError::CursorQueryFailed(
            "cursor query not available on this platform".into(),
        ))
    }
}
