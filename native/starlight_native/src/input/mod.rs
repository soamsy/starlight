pub mod cursor;
pub mod eis;

pub use cursor::linux::get_cursor_pos;
pub use eis::linux::{
    init_input, move_absolute, move_relative, button_event, key_event, scroll, release_all,
};
