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
}

#[derive(Debug, Error)]
pub enum NativeError {
    #[error("window not found")]
    WindowNotFound,

    #[cfg(not(target_os = "linux"))]
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

    #[cfg(target_os = "linux")]
    #[error("PNG encode failed: {0}")]
    EncodeFailed(String),

    #[cfg(target_os = "linux")]
    #[error("I/O error: {0}")]
    Io(#[from] std::io::Error),

    #[error("NIF not initialized (call init_input first)")]
    NotInitialized,

    #[error("cursor position query failed: {0}")]
    CursorQueryFailed(String),
}

impl NativeError {
    pub fn to_atom(&self, _env: Env<'_>) -> Atom {
        match self {
            Self::WindowNotFound => window_not_found(),
            #[cfg(not(target_os = "linux"))]
            Self::EisNotAvailable => eis_not_available(),
            #[cfg(target_os = "linux")]
            Self::EisConnectFailed(_) => eis_connect_failed(),
            #[cfg(target_os = "linux")]
            Self::EisHandshakeFailed(_) => eis_handshake_failed(),
            #[cfg(target_os = "linux")]
            Self::EisNoDevice => eis_no_device(),
            Self::CaptureFailed(_) => capture_failed(),
            #[cfg(target_os = "linux")]
            Self::EncodeFailed(_) => encode_failed(),
            #[cfg(target_os = "linux")]
            Self::Io(_) => io_error(),
            Self::NotInitialized => nif_not_initialized(),
            Self::CursorQueryFailed(_) => cursor_query_failed(),
        }
    }
}
