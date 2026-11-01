use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::time::Duration;

use serde_json::Value;

const IPC_TIMEOUT: Duration = Duration::from_millis(500);

fn request(stream: &mut UnixStream, reader: &mut BufReader<UnixStream>, name: &str) -> Option<Value> {
    writeln!(stream, "\"{name}\"").ok()?;
    let mut line = String::new();
    reader.read_line(&mut line).ok()?;
    let reply: Value = serde_json::from_str(&line).ok()?;
    reply.get("Ok")?.get(name).cloned()
}

fn pair(value: &Value) -> Option<(f64, f64)> {
    let items = value.as_array()?;
    Some((items.first()?.as_f64()?, items.get(1)?.as_f64()?))
}

pub fn window_origin(query_lower: &str) -> Option<(i32, i32)> {
    let path = std::env::var("NIRI_SOCKET").ok().filter(|p| !p.is_empty())?;
    let mut stream = UnixStream::connect(path).ok()?;
    stream.set_read_timeout(Some(IPC_TIMEOUT)).ok()?;
    stream.set_write_timeout(Some(IPC_TIMEOUT)).ok()?;
    let mut reader = BufReader::new(stream.try_clone().ok()?);

    let windows = request(&mut stream, &mut reader, "Windows")?;
    let window = windows.as_array()?.iter().find(|w| {
        ["title", "app_id"].iter().any(|key| {
            w.get(key)
                .and_then(Value::as_str)
                .is_some_and(|s| s.to_lowercase().contains(query_lower))
        })
    })?;
    let layout = window.get("layout")?;
    let (tile_x, tile_y) = pair(layout.get("tile_pos_in_workspace_view")?)?;
    let (offset_x, offset_y) = pair(layout.get("window_offset_in_tile")?)?;

    let workspace_id = window.get("workspace_id")?.as_u64()?;
    let workspaces = request(&mut stream, &mut reader, "Workspaces")?;
    let output_name = workspaces
        .as_array()?
        .iter()
        .find(|ws| ws.get("id").and_then(Value::as_u64) == Some(workspace_id))?
        .get("output")?
        .as_str()?
        .to_owned();

    let outputs = request(&mut stream, &mut reader, "Outputs")?;
    let logical = outputs.get(&output_name)?.get("logical")?;
    let output_x = logical.get("x")?.as_f64()?;
    let output_y = logical.get("y")?.as_f64()?;

    Some(((output_x + tile_x + offset_x).round() as i32, (output_y + tile_y + offset_y).round() as i32))
}
