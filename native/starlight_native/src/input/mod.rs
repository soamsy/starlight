pub mod cursor;
pub mod eis;

pub use eis::linux::{
    init_input, move_absolute, move_relative, button_event, key_event, scroll, release_all,
};

pub fn get_cursor_pos() -> Result<(i32, i32), crate::error::NativeError> {
    match crate::capture::nested_display_name() {
        Some(display) => crate::capture::x11::query_pointer(&display),
        None => cursor::linux::get_cursor_pos(),
    }
}
