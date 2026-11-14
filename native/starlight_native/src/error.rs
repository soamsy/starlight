use rustler::{Atom, Env};
use thiserror::Error;

rustler::atoms! {
    ok,
    error,
    window_not_found,
    eis_not_available,
    eis_connect_failed,
    eis_handshake_failed,
    eis_no_device,
    capture_failed,
    encode_failed,
    io_error,
    nif_not_initialized,
    cursor_query_failed,
    input_refused,
    input_failed,
}

#[derive(Debug, Error)]
pub enum NativeError {
    #[error("window not found")]
    WindowNotFound,

    #[cfg(not(any(target_os = "linux", windows)))]
    #[error("EIS not available (KWin Plasma 6.0+ required)")]
    EisNotAvailable,

    #[cfg(target_os = "linux")]
    #[error("EIS connection failed: {0}")]
    EisConnectFailed(String),

    #[cfg(target_os = "linux")]
    #[error("EIS handshake failed: {0}")]
    EisHandshakeFailed(String),

    #[cfg(target_os = "linux")]
    #[error("EIS device not ready")]
    EisNoDevice,

    #[error("capture failed: {0}")]
    CaptureFailed(String),

    #[cfg(any(target_os = "linux", windows))]
    #[error("PNG encode failed: {0}")]
    EncodeFailed(String),

    #[cfg(target_os = "linux")]
    #[error("I/O error: {0}")]
    Io(#[from] std::io::Error),

    #[error("NIF not initialized (call init_input first)")]
    NotInitialized,

    #[error("cursor position query failed: {0}")]
    CursorQueryFailed(String),

    #[cfg(windows)]
    #[error("input refused: {0}")]
    InputRefused(String),

    #[cfg(windows)]
    #[error("SendInput failed: {0}")]
    InputFailed(String),
}

impl NativeError {
    pub fn to_atom(&self, _env: Env<'_>) -> Atom {
        match self {
            Self::WindowNotFound => window_not_found(),
            #[cfg(not(any(target_os = "linux", windows)))]
            Self::EisNotAvailable => eis_not_available(),
            #[cfg(target_os = "linux")]
            Self::EisConnectFailed(_) => eis_connect_failed(),
            #[cfg(target_os = "linux")]
            Self::EisHandshakeFailed(_) => eis_handshake_failed(),
            #[cfg(target_os = "linux")]
            Self::EisNoDevice => eis_no_device(),
            Self::CaptureFailed(_) => capture_failed(),
            #[cfg(any(target_os = "linux", windows))]
            Self::EncodeFailed(_) => encode_failed(),
            #[cfg(target_os = "linux")]
            Self::Io(_) => io_error(),
            Self::NotInitialized => nif_not_initialized(),
            Self::CursorQueryFailed(_) => cursor_query_failed(),
            #[cfg(windows)]
            Self::InputRefused(_) => input_refused(),
            #[cfg(windows)]
            Self::InputFailed(_) => input_failed(),
        }
    }
}
