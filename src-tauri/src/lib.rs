use std::net::TcpListener;
use std::path::Path;
use std::process::Command;

use tauri::Manager;

const DEV_PORT: u16 = 4000;
const PREFERRED_PORT: u16 = 47621;

fn pick_port() -> u16 {
    TcpListener::bind(("127.0.0.1", PREFERRED_PORT))
        .or_else(|_| TcpListener::bind(("127.0.0.1", 0)))
        .expect("failed to find a free port")
        .local_addr()
        .expect("failed to read local port")
        .port()
}

#[cfg(target_os = "linux")]
fn configure_webkit() {
    if std::env::var_os("WAYLAND_DISPLAY").is_some() {
        let backend = std::env::var("STARLIGHT_GDK_BACKEND").unwrap_or_else(|_| "wayland".into());
        std::env::set_var("GDK_BACKEND", backend);
        std::env::set_var("__NV_DISABLE_EXPLICIT_SYNC", "1");
    } else {
        std::env::set_var("WEBKIT_DISABLE_DMABUF_RENDERER", "1");
    }
}

pub fn run() {
    #[cfg(target_os = "linux")]
    configure_webkit();

    let port = if cfg!(debug_assertions) { DEV_PORT } else { pick_port() };
    let pubsub = elixirkit::PubSub::listen("tcp://127.0.0.1:0").expect("failed to listen");

    tauri::Builder::default()
        .plugin(tauri_plugin_single_instance::init(|app, _args, _cwd| {
            if let Some(window) = app.webview_windows().values().next() {
                let _ = window.unminimize();
                let _ = window.set_focus();
            }
        }))
        .setup(move |app| {
            let app_handle = app.handle().clone();

            pubsub.subscribe("messages", move |msg| {
                if msg == b"ready" {
                    create_window(&app_handle, port);
                } else {
                    println!("[elixir] {}", String::from_utf8_lossy(msg));
                }
            });

            let app_handle = app.handle().clone();

            tauri::async_runtime::spawn_blocking(move || {
                let rel_dir = app_handle.path().resource_dir().unwrap().join("rel");
                let mut command = elixir_command(&rel_dir, port);
                command.env("ELIXIRKIT_PUBSUB", pubsub.url());
                let status = command.status().expect("failed to start Elixir");

                app_handle.exit(status.code().unwrap_or(1));
            });

            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}

fn create_window(app_handle: &tauri::AppHandle, port: u16) {
    if let Some(window) = app_handle.webview_windows().values().next() {
        let _ = window.set_focus();
        return;
    }

    let url = tauri::WebviewUrl::External(format!("http://127.0.0.1:{port}").parse().unwrap());
    tauri::WebviewWindowBuilder::new(app_handle, "main", url)
        .title("Starlight")
        .inner_size(1400.0, 900.0)
        .build()
        .unwrap();
}

fn elixir_command(rel_dir: &Path, port: u16) -> Command {
    if cfg!(debug_assertions) {
        let mut command = elixirkit::mix("phx.server", &[]);
        command.current_dir("..");
        command
    } else {
        let mut command = elixirkit::release(rel_dir, "starlight_bot");
        command.env("PHX_SERVER", "true");
        command.env("PORT", port.to_string());
        if std::env::var_os("APPIMAGE").is_some() {
            command.env_remove("LD_LIBRARY_PATH");
            command.env_remove("LD_PRELOAD");
        }
        command
    }
}
