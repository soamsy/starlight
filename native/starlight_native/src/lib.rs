mod capture;
mod error;
mod input;
mod scale;

use rustler::{Binary, Encoder, Env, OwnedBinary, Term};
use crate::error::{ok, error};

fn new_binary(len: usize) -> OwnedBinary {
    OwnedBinary::new(len).unwrap()
}

#[rustler::nif(schedule = "DirtyCpu")]
fn grab_frame<'a>(env: Env<'a>, window_title: String) -> Term<'a> {
    match capture::grab_frame(&window_title, new_binary) {
        Ok((owned, w, h)) => (ok(), owned.release(env), w, h).encode(env),
        Err(e) => {
            eprintln!("[starlight_native] grab_frame error: {e}");
            (error(), e.to_atom(env)).encode(env)
        }
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
fn grab_frame_region<'a>(env: Env<'a>, window_title: String, rx: u32, ry: u32, rw: u32, rh: u32) -> Term<'a> {
    match capture::grab_frame_region(&window_title, (rx, ry, rw, rh), new_binary) {
        Ok((owned, w, h)) => (ok(), owned.release(env), w, h).encode(env),
        Err(e) => {
            eprintln!("[starlight_native] grab_frame_region error: {e}");
            (error(), e.to_atom(env)).encode(env)
        }
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
fn grab_regions<'a>(env: Env<'a>, window_title: String, rects: Vec<(u32, u32, u32, u32)>) -> Term<'a> {
    match capture::grab_regions(&window_title, &rects, new_binary) {
        Ok(images) => (ok(), images.into_iter().map(|b| b.release(env)).collect::<Vec<Binary>>()).encode(env),
        Err(e) => {
            eprintln!("[starlight_native] grab_regions error: {e}");
            (error(), e.to_atom(env)).encode(env)
        }
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
fn save_png(bgr: Binary, width: u32, height: u32, path: String) -> rustler::Atom {
    match capture::save_png(bgr.as_slice(), width, height, &path) {
        Ok(()) => ok(),
        Err(e) => {
            eprintln!("[starlight_native] save_png error: {e}");
            error()
        }
    }
}

#[rustler::nif]
fn forget_window() -> rustler::Atom {
    capture::forget_window();
    ok()
}

#[rustler::nif(schedule = "DirtyIo")]
fn get_window_rect<'a>(env: Env<'a>, class_name: String) -> Term<'a> {
    match capture::get_window_rect(&class_name) {
        Ok((wx, wy, w, h)) => (ok(), wx, wy, w, h).encode(env),
        Err(e) => {
            if !matches!(e, crate::error::NativeError::WindowNotFound) {
                eprintln!("[starlight_native] get_window_rect error: {e}");
            }
            (error(), e.to_atom(env)).encode(env)
        }
    }
}

#[rustler::nif(schedule = "DirtyIo")]
fn window_details<'a>(env: Env<'a>, class_name: String) -> Term<'a> {
    match capture::window_details(&class_name) {
        Ok(lines) => (ok(), lines).encode(env),
        Err(e) => (error(), e.to_atom(env)).encode(env),
    }
}

#[rustler::nif(schedule = "DirtyIo")]
fn resize_window<'a>(env: Env<'a>, class_name: String, width: u32, height: u32) -> Term<'a> {
    match capture::resize_window(&class_name, width, height) {
        Ok(()) => ok().encode(env),
        Err(e) => {
            eprintln!("[starlight_native] resize_window error: {e}");
            (error(), e.to_atom(env)).encode(env)
        }
    }
}

#[rustler::nif(schedule = "DirtyIo")]
fn is_window_focused<'a>(env: Env<'a>, class_name: String) -> Term<'a> {
    match capture::is_window_focused(&class_name) {
        Ok(focused) => (ok(), focused).encode(env),
        Err(e) => {
            eprintln!("[starlight_native] is_window_focused error: {e}");
            (error(), e.to_atom(env)).encode(env)
        }
    }
}

#[rustler::nif]
fn input_backend() -> String {
    input::backend().to_owned()
}

#[rustler::nif(schedule = "DirtyIo")]
fn init_input<'a>(env: Env<'a>, window_title: String, token_path: String) -> Term<'a> {
    match input::init_input(&window_title, &token_path) {
        Ok(()) => ok().encode(env),
        Err(e) => {
            eprintln!("[starlight_native] init_input error: {e}");
            (error(), e.to_atom(env)).encode(env)
        }
    }
}

#[rustler::nif]
fn move_absolute<'a>(env: Env<'a>, x: f64, y: f64) -> Term<'a> {
    match input::move_absolute(x as f32, y as f32) {
        Ok(()) => ok().encode(env),
        Err(e) => (error(), e.to_atom(env)).encode(env),
    }
}

#[rustler::nif]
fn move_relative<'a>(env: Env<'a>, dx: f64, dy: f64) -> Term<'a> {
    match input::move_relative(dx as f32, dy as f32) {
        Ok(()) => ok().encode(env),
        Err(e) => (error(), e.to_atom(env)).encode(env),
    }
}

#[rustler::nif]
fn button_event<'a>(env: Env<'a>, code: u32, pressed: bool) -> Term<'a> {
    match input::button_event(code, pressed) {
        Ok(()) => ok().encode(env),
        Err(e) => (error(), e.to_atom(env)).encode(env),
    }
}

#[rustler::nif]
fn key_event<'a>(env: Env<'a>, keycode: u32, pressed: bool) -> Term<'a> {
    match input::key_event(keycode, pressed) {
        Ok(()) => ok().encode(env),
        Err(e) => (error(), e.to_atom(env)).encode(env),
    }
}

#[rustler::nif]
fn scroll<'a>(env: Env<'a>, dx: i32, dy: i32) -> Term<'a> {
    match input::scroll(dx, dy) {
        Ok(()) => ok().encode(env),
        Err(e) => (error(), e.to_atom(env)).encode(env),
    }
}

#[rustler::nif]
fn release_all_inputs<'a>(env: Env<'a>, held_keycodes: Vec<u32>) -> Term<'a> {
    match input::release_all(&held_keycodes) {
        Ok(()) => ok().encode(env),
        Err(e) => (error(), e.to_atom(env)).encode(env),
    }
}
#[rustler::nif(schedule = "DirtyIo")]
fn get_cursor_pos<'a>(env: Env<'a>) -> Term<'a> {
    match input::get_cursor_pos() {
        Ok((x, y)) => (ok(), x, y).encode(env),
        Err(e) => {
            eprintln!("[starlight_native] get_cursor_pos error: {e}");
            (error(), e.to_atom(env)).encode(env)
        }
    }
}

rustler::init!("Elixir.StarlightBot.Native");
