use rustler::{Encoder, Env, LocalPid, OwnedEnv};
use std::sync::mpsc::{channel, Sender};
use std::sync::{Mutex, OnceLock};

rustler::atoms! {
    native_log,
    debug,
    warning,
}

#[derive(Clone, Copy)]
pub enum Level {
    #[cfg(target_os = "linux")]
    Debug,
    Warning,
}

static SINK: Mutex<Option<LocalPid>> = Mutex::new(None);
static QUEUE: OnceLock<Sender<(Level, String)>> = OnceLock::new();

pub fn emit(level: Level, message: String) {
    let has_sink = SINK.lock().map(|sink| sink.is_some()).unwrap_or(false);
    match QUEUE.get() {
        Some(queue) if has_sink => {
            if queue.send((level, message.clone())).is_err() {
                eprintln!("{message}");
            }
        }
        _ => eprintln!("{message}"),
    }
}

pub fn attach(pid: LocalPid) {
    if let Ok(mut sink) = SINK.lock() {
        *sink = Some(pid);
    }
    QUEUE.get_or_init(|| {
        let (tx, rx) = channel::<(Level, String)>();
        std::thread::spawn(move || {
            let mut env = OwnedEnv::new();
            for (level, message) in rx {
                let target = SINK.lock().ok().and_then(|sink| *sink);
                match target {
                    Some(pid) => {
                        let _ = env.send_and_clear(&pid, |env: Env| {
                            let level = match level {
                                #[cfg(target_os = "linux")]
                                Level::Debug => debug(),
                                Level::Warning => warning(),
                            };
                            (native_log(), level, message.as_str()).encode(env)
                        });
                    }
                    None => eprintln!("{message}"),
                }
            }
        });
        tx
    });
}

#[macro_export]
macro_rules! elog {
    ($($arg:tt)*) => {
        $crate::log::emit($crate::log::Level::Debug, format!($($arg)*))
    };
}

#[macro_export]
macro_rules! elog_warn {
    ($($arg:tt)*) => {
        $crate::log::emit($crate::log::Level::Warning, format!($($arg)*))
    };
}
